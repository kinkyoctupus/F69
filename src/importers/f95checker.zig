// F95Checker importer — SQLite-backed reader for the upstream tool.
//
// Schema reference (post-2026):
//   games.id INTEGER PRIMARY KEY      → F95Zone thread id
//   games.name TEXT
//   games.version TEXT
//   games.developer TEXT
//   games.executables TEXT            → JSON array of relative paths
//                                       (relative to settings.default_exe_dir["2"])
//   games.tags TEXT                   → JSON array of strings
//   games.description TEXT
//   games.changelog TEXT
//   games.notes TEXT
//   games.score REAL                  → F95Zone average (0..5)
//   games.votes INTEGER
//   games.rating INTEGER              → user rating, 0..5 stars
//   games.last_launched INTEGER       → unix seconds
//   games.image_url TEXT              → cover
//   games.finished TEXT               → empty / "completed"
//
// Default games base dir lives at:
//   settings.default_exe_dir → JSON `{"2": "/path/on/linux"}`
//
// Caller picks the actual base dir at import time (the configured one
// may be stale), so we don't try to resolve absolute paths here; only
// the relative `install_executable_rel` is returned.

const std = @import("std");
const dbu = @import("util_db");
const imp = @import("importers.zig");

const log = std.log.scoped(.importer_f95checker);

/// Default db path. Settings UI lets the user override but most users
/// will have the upstream default.
pub const DEFAULT_DB_BASENAME = "db.sqlite3";

/// Read every game row from the F95Checker SQLite db at `db_path`.
/// Returns a `Bundle` owning every string via an arena. Caller frees
/// with `bundle.deinit()`.
pub fn loadFromDb(alloc: std.mem.Allocator, db_path: []const u8) imp.Error!imp.Bundle {
    var conn = dbu.Conn.open(db_path, alloc, .{ .readonly = true, .create = false }) catch return imp.Error.OpenFailed;
    defer conn.close();

    const arena = alloc.create(std.heap.ArenaAllocator) catch return imp.Error.OutOfMemory;
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    var out: std.ArrayList(imp.ImportedGame) = .empty;
    errdefer out.deinit(aalloc);

    var rows = conn.inner.rows(
        \\SELECT id, name, version, developer, executables, tags,
        \\       description, changelog, notes, image_url, score,
        \\       votes, rating, last_launched, finished
        \\FROM games
        \\ORDER BY name COLLATE NOCASE
    , .{}) catch return imp.Error.ParseFailed;
    defer rows.deinit();

    while (rows.next()) |r| {
        const id_i: i64 = r.int(0);
        if (id_i <= 0) continue;
        const thread_id: u64 = @intCast(id_i);

        const name = (dupeNullable(aalloc, r.nullableText(1)) catch return imp.Error.OutOfMemory) orelse {
            // Skipping nameless rows keeps malformed source data from
            // polluting the import; F95Checker shouldn't emit them but
            // tests have seen broken installs.
            continue;
        };

        const version = blk: {
            const s = (dupeNullable(aalloc, r.nullableText(2)) catch return imp.Error.OutOfMemory) orelse break :blk null;
            // F95Checker stamps "Unchecked" for never-refreshed entries;
            // surface that as "no version" rather than a literal label
            // the user would see in their library.
            if (std.mem.eql(u8, s, "Unchecked") or s.len == 0) break :blk null;
            break :blk s;
        };
        const developer = (dupeNullable(aalloc, r.nullableText(3)) catch return imp.Error.OutOfMemory) orelse null;
        const executables_json = (dupeNullable(aalloc, r.nullableText(4)) catch return imp.Error.OutOfMemory) orelse "[]";
        const tags_json = (dupeNullable(aalloc, r.nullableText(5)) catch return imp.Error.OutOfMemory) orelse "[]";
        const description = (dupeNullable(aalloc, r.nullableText(6)) catch return imp.Error.OutOfMemory) orelse null;
        const changelog = (dupeNullable(aalloc, r.nullableText(7)) catch return imp.Error.OutOfMemory) orelse null;
        const notes = (dupeNullable(aalloc, r.nullableText(8)) catch return imp.Error.OutOfMemory) orelse null;
        const image_url = (dupeNullable(aalloc, r.nullableText(9)) catch return imp.Error.OutOfMemory) orelse null;

        const score_f: f64 = r.float(10);
        const rating_score: ?f32 = if (score_f > 0) @as(f32, @floatCast(score_f)) else null;

        const votes_i: i64 = r.int(11);
        const vote_count: ?u32 = if (votes_i > 0) @as(u32, @intCast(votes_i)) else null;

        const rating_i: i64 = r.int(12);
        const user_rating: ?f32 = if (rating_i > 0) @as(f32, @floatFromInt(rating_i)) else null;

        const launched_i: i64 = r.int(13);
        const last_played_at: ?i64 = if (launched_i > 0) launched_i else null;

        const finished_str = (dupeNullable(aalloc, r.nullableText(14)) catch return imp.Error.OutOfMemory) orelse "";

        const tags = parseJsonStringArray(aalloc, tags_json) catch &.{};
        const exes = parseJsonStringArray(aalloc, executables_json) catch &.{};
        const install_rel: ?[]const u8 = if (exes.len > 0) exes[0] else null;

        // F95Checker uses an empty `finished` for "not started" and any
        // truthy string for completed-ish. Pass the raw text through;
        // the f69 upsert side maps to its own enum.
        const completion: ?[]const u8 = if (finished_str.len > 0) finished_str else null;

        out.append(aalloc, .{
            .thread_id = thread_id,
            .name = name,
            .developer = developer,
            .version = version,
            .description = description,
            .changelog = changelog,
            .notes = notes,
            .cover_url = image_url,
            .tags = tags,
            .user_rating = user_rating,
            .rating = rating_score,
            .vote_count = vote_count,
            .last_played_at = last_played_at,
            .install_executable_rel = install_rel,
            .completion_status = completion,
        }) catch return imp.Error.OutOfMemory;
    }

    const games = out.toOwnedSlice(aalloc) catch return imp.Error.OutOfMemory;
    return .{ .arena = arena, .games = games };
}

/// Read `settings.default_exe_dir` and return the JSON value for the
/// Linux platform key ("2"). Useful as the suggested default for the
/// games-base-dir picker. Null if the field is empty or absent.
/// Caller frees the returned string.
pub fn readConfiguredGamesDir(alloc: std.mem.Allocator, db_path: []const u8) !?[]u8 {
    var conn = dbu.Conn.open(db_path, alloc, .{ .readonly = true, .create = false }) catch return imp.Error.OpenFailed;
    defer conn.close();

    var maybe_row = conn.inner.row("SELECT default_exe_dir FROM settings WHERE _ = 0", .{}) catch return imp.Error.ParseFailed;
    if (maybe_row) |*r| {
        defer r.deinit();
        const raw = r.nullableText(0) orelse return null;
        if (raw.len == 0) return null;
        return try extractLinuxPath(alloc, raw);
    }
    return null;
}

/// Pull the `"2"` entry out of `{"2": "/path"}`. Tiny hand-rolled
/// JSON peek so we don't drag a full parser allocation in for a
/// single key lookup.
fn extractLinuxPath(alloc: std.mem.Allocator, json: []const u8) !?[]u8 {
    // Look for the literal `"2"` key.
    const key = "\"2\"";
    const k_at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = k_at + key.len;
    // Skip whitespace + colon + whitespace + opening quote.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == ':')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        // F95Checker doesn't escape slashes; we don't expect backslash
        // escapes either. If we hit one, bail to keep the parser tiny.
        if (json[i] == '\\') return null;
    }
    if (i >= json.len) return null;
    return try alloc.dupe(u8, json[start..i]);
}

fn dupeNullable(alloc: std.mem.Allocator, opt: ?[]const u8) !?[]const u8 {
    const s = opt orelse return null;
    return try alloc.dupe(u8, s);
}

/// Decode F95Checker's JSON-array-of-strings columns (`tags`, `executables`).
/// Returns an arena-allocated slice of arena-allocated strings.
fn parseJsonStringArray(alloc: std.mem.Allocator, json: []const u8) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice([]const []const u8, alloc, json, .{});
    defer parsed.deinit();
    // dupe into arena so deinit() of the parsed value doesn't kill us.
    var out = try alloc.alloc([]const u8, parsed.value.len);
    for (parsed.value, 0..) |s, i| {
        out[i] = try alloc.dupe(u8, s);
    }
    return out;
}

// ============================================================
//  Tests — use in-memory SQLite with a synthesized schema so we
//  don't depend on the user's home directory.
// ============================================================

const testing = std.testing;

test "loadFromDb: empty games table → empty bundle" {
    const tmp = "/tmp/f69-test-f95checker-empty.sqlite3";
    {
        var tio = std.Io.Threaded.init(testing.allocator, .{});
        defer tio.deinit();
        std.Io.Dir.cwd().deleteFile(tio.io(), tmp) catch {};
    }
    defer {
        var tio = std.Io.Threaded.init(testing.allocator, .{});
        defer tio.deinit();
        std.Io.Dir.cwd().deleteFile(tio.io(), tmp) catch {};
    }

    {
        var conn = try dbu.Conn.open(tmp, testing.allocator, .{ .create = true });
        defer conn.close();
        try conn.exec(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, version TEXT, developer TEXT, executables TEXT DEFAULT '[]', tags TEXT DEFAULT '[]', description TEXT, changelog TEXT, notes TEXT, image_url TEXT, score REAL DEFAULT 0, votes INTEGER DEFAULT 0, rating INTEGER DEFAULT 0, last_launched INTEGER DEFAULT 0, finished TEXT DEFAULT '')",
        );
    }

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();
    try testing.expectEqual(@as(usize, 0), bundle.games.len);
}

test "loadFromDb: full row round-trips through the bundle" {
    const tmp = "/tmp/f69-test-f95checker-full.sqlite3";
    {
        var tio = std.Io.Threaded.init(testing.allocator, .{});
        defer tio.deinit();
        std.Io.Dir.cwd().deleteFile(tio.io(), tmp) catch {};
    }
    defer {
        var tio = std.Io.Threaded.init(testing.allocator, .{});
        defer tio.deinit();
        std.Io.Dir.cwd().deleteFile(tio.io(), tmp) catch {};
    }

    {
        var conn = try dbu.Conn.open(tmp, testing.allocator, .{ .create = true });
        defer conn.close();
        try conn.exec(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, version TEXT, developer TEXT, executables TEXT DEFAULT '[]', tags TEXT DEFAULT '[]', description TEXT, changelog TEXT, notes TEXT, image_url TEXT, score REAL DEFAULT 0, votes INTEGER DEFAULT 0, rating INTEGER DEFAULT 0, last_launched INTEGER DEFAULT 0, finished TEXT DEFAULT '')",
        );
        conn.inner.exec(
            "INSERT INTO games VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            .{
                @as(i64, 2428),
                "Babysitter",
                "v0.2.2b",
                "T4bbo",
                "[\"Babysitter-0.2.2b.-linux/Babysitter.sh\"]",
                "[\"3dcg\",\"romance\"]",
                "the description",
                "the changelog",
                "the notes",
                "https://attachments.f95zone.to/cover.png",
                @as(f64, 4.5),
                @as(i64, 1234),
                @as(i64, 5),
                @as(i64, 1700000000),
                "completed",
            },
        ) catch unreachable;
    }

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();

    try testing.expectEqual(@as(usize, 1), bundle.games.len);
    const g = bundle.games[0];
    try testing.expectEqual(@as(u64, 2428), g.thread_id);
    try testing.expectEqualStrings("Babysitter", g.name);
    try testing.expectEqualStrings("v0.2.2b", g.version.?);
    try testing.expectEqualStrings("T4bbo", g.developer.?);
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux/Babysitter.sh", g.install_executable_rel.?);
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux", g.installDirRel().?);
    try testing.expectEqual(@as(usize, 2), g.tags.len);
    try testing.expectEqualStrings("3dcg", g.tags[0]);
    try testing.expectEqualStrings("romance", g.tags[1]);
    try testing.expectEqual(@as(?f32, 4.5), g.rating);
    try testing.expectEqual(@as(?u32, 1234), g.vote_count);
    try testing.expectEqual(@as(?f32, 5), g.user_rating);
    try testing.expectEqual(@as(?i64, 1700000000), g.last_played_at);
    try testing.expectEqualStrings("completed", g.completion_status.?);
}

test "loadFromDb: 'Unchecked' version is normalised to null" {
    const tmp = "/tmp/f69-test-f95checker-unchecked.sqlite3";
    {
        var tio = std.Io.Threaded.init(testing.allocator, .{});
        defer tio.deinit();
        std.Io.Dir.cwd().deleteFile(tio.io(), tmp) catch {};
    }
    defer {
        var tio = std.Io.Threaded.init(testing.allocator, .{});
        defer tio.deinit();
        std.Io.Dir.cwd().deleteFile(tio.io(), tmp) catch {};
    }

    {
        var conn = try dbu.Conn.open(tmp, testing.allocator, .{ .create = true });
        defer conn.close();
        try conn.exec(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, version TEXT, developer TEXT, executables TEXT DEFAULT '[]', tags TEXT DEFAULT '[]', description TEXT, changelog TEXT, notes TEXT, image_url TEXT, score REAL DEFAULT 0, votes INTEGER DEFAULT 0, rating INTEGER DEFAULT 0, last_launched INTEGER DEFAULT 0, finished TEXT DEFAULT '')",
        );
        conn.inner.exec(
            "INSERT INTO games (id, name, version) VALUES (?, ?, ?)",
            .{ @as(i64, 100), "Fresh", "Unchecked" },
        ) catch unreachable;
    }

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();
    try testing.expectEqual(@as(?[]const u8, null), bundle.games[0].version);
}

test "extractLinuxPath: pulls value for key \"2\"" {
    const out = try extractLinuxPath(testing.allocator, "{\"2\": \"/path/to/games\"}");
    defer if (out) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("/path/to/games", out.?);
}

test "extractLinuxPath: missing key returns null" {
    const out = try extractLinuxPath(testing.allocator, "{}");
    try testing.expectEqual(@as(?[]u8, null), out);
}
