// F95Indexer HTTP client. Calls only the two endpoints F95Checker uses:
//
//   GET /fast?ids=<csv>      → {id: last_change_ts, ...}   (≤10 ids)
//   GET /full/{id}?ts=<ts>   → thread hash dict
//
// Per WillyJL's grant, f69 uses the API exactly the same way F95Checker
// does (same chunk size, same two endpoints, same cache-busting `ts`
// parameter). The User-Agent is f69-specific so server logs can
// distinguish our traffic.

const std = @import("std");
const http = @import("util_http");
const errs = @import("errors.zig");
const build_options = @import("build_options");

const log = std.log.scoped(.f95_indexer);

/// Sent on every indexer request. Contact URL + version so WillyJL can
/// reach the maintainer if f69 starts misbehaving.
pub const USER_AGENT = "f69/" ++ build_options.version ++ " (+https://github.com/Moordp/F69)";

pub const DEFAULT_BASE_URL = "https://api.f95checker.dev";

/// Hard cap enforced by the indexer router. Sending more triggers
/// `BadRequest`.
pub const MAX_IDS_PER_FAST: usize = 10;

/// One row of a `/fast` response.
pub const FastResult = struct {
    id: u64,
    /// Unix seconds the indexer last observed a meaningful change.
    /// Comparing this to the persisted `Game.last_indexer_change`
    /// tells us whether to call `/full`.
    last_change: i64,
};

/// One link inside an indexer `downloads` group. The indexer returns
/// each link as a `[host, url]` 2-tuple inside the JSON, with `host`
/// being a free-form string ("MEGA" / "MEDIAFIRE" / "WORKUPLOAD" / a
/// game-specific label like "Walkthrough"). The mapping layer maps
/// these to f69's `DownloadHost` enum.
pub const DownloadEntry = struct {
    host: []const u8,
    url: []const u8,
};

/// One group of download links, keyed by a label like a version
/// string or "Walkthrough". Indexer structure:
/// `[[label, [[host, url], ...]], ...]`.
pub const DownloadGroup = struct {
    label: []const u8,
    links: []const DownloadEntry,
};

/// Parsed `/full/{id}` body. Strings + slices are arena-owned; call
/// `deinit()` to release everything in one shot.
pub const ThreadData = struct {
    arena: std.heap.ArenaAllocator,

    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    developer: ?[]const u8 = null,
    description: ?[]const u8 = null,
    changelog: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    previews_urls: []const []const u8 = &.{},
    /// F95Checker's `Tag` enum integer IDs. Mapping layer translates
    /// to human-readable labels via the embedded `tag_table.zig`.
    tag_ids: []const u32 = &.{},
    /// Tag tokens that didn't match the known Tag table (e.g.
    /// thread-side custom prefixes). Pass-through to f69's `tags`.
    unknown_tags: []const []const u8 = &.{},
    /// `last_updated` in the indexer is a stringified unix seconds (it
    /// runs `parser.datestamp(now)` and stores `str(int)`). We parse
    /// back to i64.
    last_updated: ?i64 = null,
    score: ?f32 = null,
    votes: ?u32 = null,
    /// F95Checker's `Type` enum integer (RenPy=14, RPGM=13, …). The
    /// mapping layer converts to f69's `Engine`.
    type_int: ?u32 = null,
    /// F95Checker's `Status` enum integer (Normal=1, Completed=2,
    /// OnHold=3, Abandoned=4, Unchecked=5, Custom=6). Mapped to
    /// f69's `DevStatus`.
    status_int: ?u32 = null,
    /// Grouped download links (per-version / walkthrough / etc.).
    downloads: []const DownloadGroup = &.{},

    pub fn deinit(self: *ThreadData) void {
        self.arena.deinit();
    }
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8) Client {
        return .{ .alloc = alloc, .io = io, .base_url = base_url };
    }

    /// `GET /fast?ids=<csv>`. ids.len must be ≤ MAX_IDS_PER_FAST.
    /// Caller frees the returned slice.
    pub fn fastCheck(self: *const Client, ids: []const u64) errs.Error![]FastResult {
        if (ids.len == 0) return self.alloc.alloc(FastResult, 0) catch return errs.Error.OutOfMemory;
        if (ids.len > MAX_IDS_PER_FAST) return errs.Error.TooManyIds;

        // Build "1,2,3,...".
        var ids_buf: std.ArrayList(u8) = .empty;
        defer ids_buf.deinit(self.alloc);
        for (ids, 0..) |id, i| {
            if (i > 0) ids_buf.append(self.alloc, ',') catch return errs.Error.OutOfMemory;
            var num_buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{id}) catch return errs.Error.OutOfMemory;
            ids_buf.appendSlice(self.alloc, num_str) catch return errs.Error.OutOfMemory;
        }

        const url = std.fmt.allocPrint(self.alloc, "{s}/fast?ids={s}", .{
            self.base_url,
            ids_buf.items,
        }) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(url);

        log.info("GET {s}", .{url});
        const resp = http.fetch(self.alloc, self.io, url, .{ .user_agent = USER_AGENT }) catch {
            return errs.Error.Unreachable;
        };
        defer self.alloc.free(resp.body);

        if (resp.status == 400) return errs.Error.BadRequest;
        if (resp.status < 200 or resp.status >= 300) {
            log.warn("indexer /fast non-2xx: {d}", .{resp.status});
            return errs.Error.SourceError;
        }

        return parseFastBody(self.alloc, resp.body);
    }

    /// `GET /full/{id}?ts=<ts>`. `ts` should be the `last_change`
    /// returned by a recent `/fast`; passing 0 is fine for first-time
    /// fetches.
    pub fn fullCheck(self: *const Client, id: u64, ts: i64) errs.Error!ThreadData {
        const url = std.fmt.allocPrint(self.alloc, "{s}/full/{d}?ts={d}", .{
            self.base_url,
            id,
            ts,
        }) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(url);

        log.info("GET {s}", .{url});
        const resp = http.fetch(self.alloc, self.io, url, .{ .user_agent = USER_AGENT }) catch {
            return errs.Error.Unreachable;
        };
        defer self.alloc.free(resp.body);

        switch (resp.status) {
            200 => return parseFullBody(self.alloc, resp.body),
            400 => return errs.Error.BadRequest,
            404 => return errs.Error.ThreadMissing,
            406 => return errs.Error.BadTimestamp,
            500 => return errs.Error.SourceError,
            else => {
                log.warn("indexer /full unexpected status: {d}", .{resp.status});
                return errs.Error.SourceError;
            },
        }
    }
};

/// Decode `{"<id>": <ts>, ...}` into a list of (id, ts) pairs.
fn parseFastBody(alloc: std.mem.Allocator, body: []const u8) errs.Error![]FastResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        log.warn("indexer /fast body not JSON: {s}", .{body[0..@min(body.len, 200)]});
        return errs.Error.ParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return errs.Error.ParseError;
    const obj = parsed.value.object;

    var out: std.ArrayList(FastResult) = .empty;
    errdefer out.deinit(alloc);
    out.ensureTotalCapacity(alloc, obj.count()) catch return errs.Error.OutOfMemory;

    var it = obj.iterator();
    while (it.next()) |entry| {
        const id = std.fmt.parseInt(u64, entry.key_ptr.*, 10) catch continue;
        const ts: i64 = switch (entry.value_ptr.*) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => continue,
        };
        out.append(alloc, .{ .id = id, .last_change = ts }) catch return errs.Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
}

/// Decode the `/full/{id}` Redis-hash response. Every value is stored
/// as a string in Redis; some values (tags, previews_urls) are
/// JSON-encoded lists inside the outer JSON. last_updated is a
/// stringified unix seconds.
fn parseFullBody(alloc: std.mem.Allocator, body: []const u8) errs.Error!ThreadData {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch {
        return errs.Error.ParseError;
    };
    // No defer parsed.deinit() — it's arena-backed.

    if (parsed.value != .object) return errs.Error.ParseError;
    const obj = parsed.value.object;

    var out = ThreadData{ .arena = arena };

    out.name = strField(aa, obj, "name") catch null;
    out.version = strField(aa, obj, "version") catch null;
    out.developer = strField(aa, obj, "developer") catch null;
    out.description = strField(aa, obj, "description") catch null;
    out.changelog = strField(aa, obj, "changelog") catch null;
    out.image_url = strField(aa, obj, "image_url") catch null;

    out.previews_urls = decodeJsonStringList(aa, obj, "previews_urls") catch &.{};
    out.tag_ids = decodeJsonIntList(aa, obj, "tags") catch &.{};
    out.unknown_tags = decodeJsonStringList(aa, obj, "unknown_tags") catch &.{};
    out.downloads = decodeDownloadsJson(aa, obj, "downloads") catch &.{};

    if (strField(aa, obj, "last_updated") catch null) |s| {
        out.last_updated = std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
    }
    if (strField(aa, obj, "score") catch null) |s| {
        out.score = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t\r\n")) catch null;
    }
    if (strField(aa, obj, "votes") catch null) |s| {
        out.votes = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
    }
    if (strField(aa, obj, "type") catch null) |s| {
        out.type_int = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
    }
    if (strField(aa, obj, "status") catch null) |s| {
        out.status_int = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
    }

    return out;
}

/// Read a string field from the outer JSON object. Empty strings count
/// as null so callers don't have to special-case them.
fn strField(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) errs.Error!?[]const u8 {
    const v = obj.get(key) orelse return null;
    const s = switch (v) {
        .string => |str| str,
        else => return null,
    };
    if (s.len == 0) return null;
    return arena.dupe(u8, s) catch return errs.Error.OutOfMemory;
}

/// Inner JSON: the field's value is itself a JSON-encoded string like
/// `"[\"tag1\", \"tag2\"]"`. Parse the inner string, return a slice of
/// arena-owned strings. Missing key → empty slice.
fn decodeJsonStringList(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) errs.Error![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    const inner_text = switch (v) {
        .string => |str| str,
        else => return &.{},
    };
    if (inner_text.len == 0) return &.{};

    const inner_parsed = std.json.parseFromSlice(std.json.Value, arena, inner_text, .{}) catch {
        return &.{};
    };
    if (inner_parsed.value != .array) return &.{};
    const arr = inner_parsed.value.array;

    var out = arena.alloc([]const u8, arr.items.len) catch return errs.Error.OutOfMemory;
    var written: usize = 0;
    for (arr.items) |elem| {
        if (elem != .string) continue;
        out[written] = arena.dupe(u8, elem.string) catch return errs.Error.OutOfMemory;
        written += 1;
    }
    return out[0..written];
}

/// Inner JSON: same shape as `decodeJsonStringList` but elements are
/// integers (e.g. F95Checker `Tag` IDs). Returns arena-owned `[]u32`.
fn decodeJsonIntList(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) errs.Error![]const u32 {
    const v = obj.get(key) orelse return &.{};
    const inner_text = switch (v) {
        .string => |str| str,
        else => return &.{},
    };
    if (inner_text.len == 0) return &.{};

    const inner_parsed = std.json.parseFromSlice(std.json.Value, arena, inner_text, .{}) catch {
        return &.{};
    };
    if (inner_parsed.value != .array) return &.{};
    const arr = inner_parsed.value.array;

    var out = arena.alloc(u32, arr.items.len) catch return errs.Error.OutOfMemory;
    var written: usize = 0;
    for (arr.items) |elem| {
        const id: u32 = switch (elem) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else continue,
            .float => |f| if (f >= 0 and f <= @as(f64, std.math.maxInt(u32))) @intFromFloat(f) else continue,
            else => continue,
        };
        out[written] = id;
        written += 1;
    }
    return out[0..written];
}

/// Decode the indexer `downloads` field. JSON-encoded string holding
/// `[[label, [[host, url], [host, url], ...]], ...]`. Returns
/// arena-owned `[]DownloadGroup`.
fn decodeDownloadsJson(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) errs.Error![]const DownloadGroup {
    const v = obj.get(key) orelse return &.{};
    const inner_text = switch (v) {
        .string => |str| str,
        else => return &.{},
    };
    if (inner_text.len == 0) return &.{};

    const inner_parsed = std.json.parseFromSlice(std.json.Value, arena, inner_text, .{}) catch {
        return &.{};
    };
    if (inner_parsed.value != .array) return &.{};
    const outer = inner_parsed.value.array;

    var groups = arena.alloc(DownloadGroup, outer.items.len) catch return errs.Error.OutOfMemory;
    var group_count: usize = 0;
    for (outer.items) |group_v| {
        if (group_v != .array) continue;
        const pair = group_v.array;
        if (pair.items.len < 2) continue;
        const label_v = pair.items[0];
        const links_v = pair.items[1];
        if (label_v != .string or links_v != .array) continue;

        const label = arena.dupe(u8, label_v.string) catch return errs.Error.OutOfMemory;

        const links_arr = links_v.array;
        var links = arena.alloc(DownloadEntry, links_arr.items.len) catch return errs.Error.OutOfMemory;
        var link_count: usize = 0;
        for (links_arr.items) |link_v| {
            if (link_v != .array) continue;
            const lp = link_v.array;
            if (lp.items.len < 2) continue;
            if (lp.items[0] != .string or lp.items[1] != .string) continue;
            // Keep XPath stubs (`//a[starts-with(...)]`) — they let
            // the mapping layer tell "intentionally empty group
            // (section header)" apart from "indexer never resolved
            // any link". Render-time filtering drops them.
            links[link_count] = .{
                .host = arena.dupe(u8, lp.items[0].string) catch return errs.Error.OutOfMemory,
                .url = arena.dupe(u8, lp.items[1].string) catch return errs.Error.OutOfMemory,
            };
            link_count += 1;
        }
        groups[group_count] = .{
            .label = label,
            .links = links[0..link_count],
        };
        group_count += 1;
    }
    return groups[0..group_count];
}
