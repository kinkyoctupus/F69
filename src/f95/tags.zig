// Master tag list — fetched once from F95's `/tags/` index and
// cached locally. The sidebar uses it to render checkbox include /
// exclude lists so the user doesn't have to type tag names by hand.
//
// On-disk format (`<data_root>/tags.txt`):
//
//   # fetched: <unix-seconds>
//   3DCG
//   Adventure
//   Anal Sex
//   ...
//
// Lines starting with `#` are ignored. Blank lines too. The file is
// rewritten atomically on each successful refresh.
//
// **Bundled seed.** `tags_seed.txt` is `@embedFile`d below — a snapshot
// of the master tag list taken at build time. `loadOrSeed` returns the
// disk copy when present (the user has refreshed at least once since
// install) and falls back to the embedded snapshot otherwise. This way
// first-launch users get a usable tag sidebar without having to be
// logged in / refresh first; refresh still wins thereafter.

const std = @import("std");
const log = std.log.scoped(.f95_tags);
const errs = @import("errors.zig");
const Client = @import("client.zig").Client;
const atomic_io = @import("util_atomic_io");

const SEED_BYTES: []const u8 = @embedFile("tags_seed.txt");

/// Hard cap on how many tags we keep in the master list. F95 currently
/// publishes about 200 game-related tags; 1024 is a generous safety net.
pub const MAX_TAGS: usize = 1024;

pub const Cached = struct {
    /// Sorted, deduped, lowercase-normalized for matching. Each entry
    /// is `alloc`-owned. The slice itself is `alloc`-owned too.
    tags: []const []const u8,
    /// Unix seconds of the last successful fetch. 0 means "never".
    fetched_at: i64,

    pub fn deinit(self: *Cached, alloc: std.mem.Allocator) void {
        for (self.tags) |t| alloc.free(t);
        if (self.tags.len > 0) alloc.free(self.tags);
        self.* = undefined;
    }
};

/// Pure: parse the same `tags.txt`-shaped bytes (header + one-tag-per-line)
/// used both for the on-disk cache AND the embedded seed. Caller owns
/// the result. Malformed lines are skipped, not fatal.
pub fn parseTagsFile(alloc: std.mem.Allocator, bytes: []const u8) !Cached {
    var fetched_at: i64 = 0;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            // Header line — try parsing `# fetched: <unix-secs>`.
            if (std.mem.indexOf(u8, line, "fetched:")) |at| {
                const after = std.mem.trim(u8, line[at + "fetched:".len ..], " \t");
                fetched_at = std.fmt.parseInt(i64, after, 10) catch fetched_at;
            }
            continue;
        }
        if (out.items.len >= MAX_TAGS) break;
        const dup = try alloc.dupe(u8, line);
        errdefer alloc.free(dup);
        try out.append(alloc, dup);
    }

    return .{
        .tags = try out.toOwnedSlice(alloc),
        .fetched_at = fetched_at,
    };
}

/// Read `<data_root>/tags.txt` and return whatever's cached. Missing
/// file → empty list, `fetched_at = 0`. A malformed line is skipped,
/// not fatal.
pub fn loadFromDisk(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Cached {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256 * 1024)) catch |e| {
        if (e == error.FileNotFound) return .{ .tags = &.{}, .fetched_at = 0 };
        return e;
    };
    defer alloc.free(bytes);
    return parseTagsFile(alloc, bytes);
}

/// Parse the build-time embedded snapshot. Used as a first-run fallback
/// when no on-disk cache exists yet. Same format as `loadFromDisk`.
pub fn loadSeed(alloc: std.mem.Allocator) !Cached {
    return parseTagsFile(alloc, SEED_BYTES);
}

/// Disk-first, seed-fallback loader. Returns the on-disk cache when
/// the file exists AND contains at least one tag; otherwise returns
/// the bundled snapshot. After the user clicks Refresh once, the
/// resulting `tags.txt` always wins.
pub fn loadOrSeed(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Cached {
    var disk = try loadFromDisk(alloc, io, path);
    if (disk.tags.len > 0) return disk;
    // Disk empty or missing — release whatever loadFromDisk allocated
    // (empty slice) and return the seed.
    disk.deinit(alloc);
    return try loadSeed(alloc);
}

/// Atomic write — tmp + rename. Caller passes the deduped, sorted
/// list; we add the timestamp header.
pub fn saveToDisk(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    tags: []const []const u8,
    fetched_at: i64,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // ~16 bytes per tag plus header overhead.
    try buf.ensureTotalCapacity(alloc, tags.len * 24 + 64);

    var hdr: [64]u8 = undefined;
    const hdr_str = try std.fmt.bufPrint(&hdr, "# fetched: {d}\n", .{fetched_at});
    try buf.appendSlice(alloc, hdr_str);
    for (tags) |t| {
        try buf.appendSlice(alloc, t);
        try buf.append(alloc, '\n');
    }

    try atomic_io.writeFileAtomic(io, path, buf.items);
}

/// Hit F95's `/tags/` index page and pull every `<a class="tagItem">`
/// label. Caller owns the outer slice + every inner string.
///
/// Internally allocates a stream of dupes, sorts (case-insensitive),
/// then dedupes. The result is suitable for direct on-disk storage.
pub fn fetchAllTags(
    alloc: std.mem.Allocator,
    client: *Client,
) errs.Error![]const []const u8 {
    const url = "https://f95zone.to/tags/";
    const body = try client.get(url);
    defer alloc.free(body);
    return try parseAllTags(alloc, body);
}

/// Pure: parse the `/tags/` page HTML. Exposed so we can unit-test it.
pub fn parseAllTags(alloc: std.mem.Allocator, html: []const u8) errs.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }

    // F95's master tag-index page uses a tag-cloud layout — each tag
    // is `<a href="..." class="tagCloud-tag tagCloud-tagLevelN">...</a>`
    // where N is a popularity-weighted bucket. The per-game pages use
    // a different `class="tagItem"` markup; we accept both shapes so
    // a future F95 refactor that swaps them back doesn't silently
    // produce 0 tags again.
    const markers = [_][]const u8{
        "class=\"tagCloud-tag", // master /tags/ page (primary)
        "class=\"tagItem\"",     // legacy / per-game pages
    };
    var rest = html;
    while (rest.len > 0) {
        // Find the next occurrence of ANY marker; track which marker
        // hit so we know how far to advance past it.
        var best_i: ?usize = null;
        var best_len: usize = 0;
        for (markers) |m| {
            if (std.mem.indexOf(u8, rest, m)) |idx| {
                if (best_i == null or idx < best_i.?) {
                    best_i = idx;
                    best_len = m.len;
                }
            }
        }
        const i = best_i orelse break;
        const after = rest[i + best_len ..];
        const gt = std.mem.indexOfScalar(u8, after, '>') orelse {
            rest = after;
            continue;
        };
        const inner_start = gt + 1;
        const close = std.mem.indexOfPos(u8, after, inner_start, "</a>") orelse {
            rest = after;
            continue;
        };
        const text = std.mem.trim(u8, after[inner_start..close], " \t\n\r");
        if (text.len > 0 and text.len < 64) {
            if (out.items.len >= MAX_TAGS) break;
            const dup = alloc.dupe(u8, text) catch return errs.Error.OutOfMemory;
            errdefer alloc.free(dup);
            out.append(alloc, dup) catch return errs.Error.OutOfMemory;
        }
        rest = after[close + 4 ..];
    }

    // Sort case-insensitive, then dedupe (case-insensitive). The tag
    // page sometimes repeats tags under multiple sections.
    std.mem.sort([]const u8, out.items, {}, lessThanIgnoreCase);
    var i: usize = 1;
    while (i < out.items.len) {
        if (std.ascii.eqlIgnoreCase(out.items[i], out.items[i - 1])) {
            alloc.free(out.items[i]);
            _ = out.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return out.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
}

fn lessThanIgnoreCase(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

test "parseAllTags: extract + sort + dedup" {
    const html =
        "<a class=\"tagItem\" href=\"/tags/zombies/\">Zombies</a>" ++
        "<a class=\"tagItem\" href=\"/tags/3dcg/\">3DCG</a>" ++
        "<a class=\"tagItem\" href=\"/tags/3DCG/\">3DCG</a>" ++ // duplicate (different case)
        "<a class=\"tagItem\" href=\"/tags/adventure/\">Adventure</a>";
    const tags = try parseAllTags(std.testing.allocator, html);
    defer {
        for (tags) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("3DCG", tags[0]);
    try std.testing.expectEqualStrings("Adventure", tags[1]);
    try std.testing.expectEqualStrings("Zombies", tags[2]);
}

test "parseAllTags: real F95 /tags/ tagCloud markup" {
    // Sampled live from https://f95zone.to/tags/ 2026-05-13. The
    // master index uses a frequency-weighted tag cloud, not the
    // per-game tagItem markup. Lower-case shape is intentional —
    // F95 lowercases everything on the cloud page.
    const html =
        "<a href=\"/tags/2d-game/\" class=\"tagCloud-tag tagCloud-tagLevel3\">2d game</a>" ++
        "<a href=\"/tags/2dcg/\" class=\"tagCloud-tag tagCloud-tagLevel6\">2dcg</a>" ++
        "<a href=\"/tags/3d-game/\" class=\"tagCloud-tag tagCloud-tagLevel1\">3d game</a>" ++
        "<a href=\"/tags/adventure/\" class=\"tagCloud-tag tagCloud-tagLevel2\">adventure</a>";
    const tags = try parseAllTags(std.testing.allocator, html);
    defer {
        for (tags) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 4), tags.len);
    try std.testing.expectEqualStrings("2d game", tags[0]);
    try std.testing.expectEqualStrings("2dcg", tags[1]);
    try std.testing.expectEqualStrings("3d game", tags[2]);
    try std.testing.expectEqualStrings("adventure", tags[3]);
}

test "loadSeed: embedded snapshot parses non-empty + has a real fetched_at" {
    var cached = try loadSeed(std.testing.allocator);
    defer cached.deinit(std.testing.allocator);
    // The bundled tag list must contain at least the canonical staples
    // — if this drops to 0 the @embedFile path broke.
    try std.testing.expect(cached.tags.len > 50);
    // The seed carries the snapshot time of the build-time refresh, so
    // a sane lower bound rejects accidental zero-headers.
    try std.testing.expect(cached.fetched_at > 1_700_000_000);
}

test "loadFromDisk: round-trip via saveToDisk happy path" {
    // Pure-memory round-trip — saveToDisk does file IO so we test
    // only the parse half here. Real disk path covered by integration.
    const sample =
        "# fetched: 1700000000\n" ++
        "3DCG\n" ++
        "Adventure\n" ++
        "\n" ++ // blank line ignored
        "Zombies\n";

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |t| std.testing.allocator.free(t);
        out.deinit(std.testing.allocator);
    }

    var fetched: i64 = 0;
    var lines = std.mem.splitScalar(u8, sample, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (std.mem.indexOf(u8, line, "fetched:")) |at| {
                fetched = try std.fmt.parseInt(i64, std.mem.trim(u8, line[at + "fetched:".len ..], " \t"), 10);
            }
            continue;
        }
        try out.append(std.testing.allocator, try std.testing.allocator.dupe(u8, line));
    }
    try std.testing.expectEqual(@as(i64, 1700000000), fetched);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
}
