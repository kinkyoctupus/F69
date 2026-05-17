// xLibrary importer — JSON-backed reader.
//
// Source: `~/.config/xlibrary/games-data.json` (Electron app config).
// Shape (post-2026 schema):
//   {
//     "games": [
//       {
//         "id":  "uuid",                  ← internal xLibrary id (ignored)
//         "name": "...",
//         "version": "EP25",
//         "developer": "...",
//         "tags": ["3dcg", ...],
//         "cover": "https://...",
//         "screenshots": ["...", ...],
//         "engine": "RenPy",
//         "completionStatus": "Not Started",
//         "description": "...",
//         "externalLinks": [
//           { "providerId": "f95zone", "externalId": "10549", "url": "..." },
//           { "providerId": "manual",  ... }
//         ],
//         "launchSettings": {
//           "configurations": [
//             { "executablePath": "Babysitter-0.2.2b.-linux/Babysitter.sh", ... }
//           ]
//         }
//       },
//       ...
//     ]
//   }
//
// F95Zone thread id is pulled from `externalLinks[*].providerId == "f95zone"`.
// `executablePath` is relative to a user-configured games root that
// xLibrary doesn't surface in this JSON — the import UI prompts for it.

const std = @import("std");
const imp = @import("importers.zig");

const log = std.log.scoped(.importer_xlibrary);

pub const DEFAULT_JSON_BASENAME = "games-data.json";

/// Read every game from xLibrary's games-data.json at `json_path`.
/// Returns a `Bundle` whose strings live in an arena; caller frees
/// with `bundle.deinit()`.
pub fn loadFromJson(alloc: std.mem.Allocator, io: std.Io, json_path: []const u8) imp.Error!imp.Bundle {
    // 32 MiB cap; current files are < 4 MiB, headroom for ~10k games.
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, json_path, alloc, .limited(32 * 1024 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => return imp.Error.OutOfMemory,
        else => return imp.Error.OpenFailed,
    };
    defer alloc.free(bytes);

    return parseFromBytes(alloc, bytes);
}

/// Parser entry point split out so tests can feed fixture bytes
/// directly without touching the filesystem.
pub fn parseFromBytes(alloc: std.mem.Allocator, bytes: []const u8) imp.Error!imp.Bundle {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return imp.Error.OutOfMemory;
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    // Use dynamic JSON so we don't have to model every field
    // xLibrary writes (and it adds new ones between releases).
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return imp.Error.ParseFailed;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return imp.Error.ParseFailed;
    const games_v = root.object.get("games") orelse return imp.Error.ParseFailed;
    if (games_v != .array) return imp.Error.ParseFailed;

    var out: std.ArrayList(imp.ImportedGame) = .empty;

    for (games_v.array.items) |gv| {
        if (gv != .object) continue;
        const obj = gv.object;

        const thread_id = extractF95ThreadId(obj) orelse {
            // No F95Zone link → skip. f69 keys on the thread id, so
            // a game we can't resolve to a thread can't enter the
            // library cleanly.
            continue;
        };

        const name = (dupeIfString(aalloc, obj.get("name")) catch return imp.Error.OutOfMemory) orelse continue;

        var g: imp.ImportedGame = .{
            .thread_id = thread_id,
            .name = name,
        };

        g.developer = (dupeIfString(aalloc, obj.get("developer")) catch return imp.Error.OutOfMemory);
        const ver = (dupeIfString(aalloc, obj.get("version")) catch return imp.Error.OutOfMemory);
        g.version = if (ver) |v| (if (v.len > 0) v else null) else null;
        g.description = (dupeIfString(aalloc, obj.get("description")) catch return imp.Error.OutOfMemory);
        g.cover_url = (dupeIfString(aalloc, obj.get("cover")) catch return imp.Error.OutOfMemory);
        g.completion_status = (dupeIfString(aalloc, obj.get("completionStatus")) catch return imp.Error.OutOfMemory);

        // Tags: array of strings.
        if (obj.get("tags")) |tv| {
            if (tv == .array) {
                var arr: std.ArrayList([]const u8) = .empty;
                for (tv.array.items) |t| {
                    if (t == .string) {
                        const s = aalloc.dupe(u8, t.string) catch return imp.Error.OutOfMemory;
                        arr.append(aalloc, s) catch return imp.Error.OutOfMemory;
                    }
                }
                g.tags = arr.toOwnedSlice(aalloc) catch return imp.Error.OutOfMemory;
            }
        }

        // F95Zone rating lives inside externalLinks[].metadata.f95.rating.
        g.rating = extractF95Rating(obj);

        // First launchSettings.configurations[].executablePath.
        if (obj.get("launchSettings")) |lv| {
            if (lv == .object) {
                if (lv.object.get("configurations")) |cv| {
                    if (cv == .array and cv.array.items.len > 0) {
                        const cfg0 = cv.array.items[0];
                        if (cfg0 == .object) {
                            g.install_executable_rel = (dupeIfString(aalloc, cfg0.object.get("executablePath")) catch return imp.Error.OutOfMemory);
                        }
                    }
                }
            }
        }

        out.append(aalloc, g) catch return imp.Error.OutOfMemory;
    }

    const games = out.toOwnedSlice(aalloc) catch return imp.Error.OutOfMemory;
    return .{ .arena = arena, .games = games };
}

/// Find the F95Zone external-link entry and parse its `externalId`
/// as a u64 thread id. Returns null on the first parsing miss.
fn extractF95ThreadId(obj: std.json.ObjectMap) ?u64 {
    const links_v = obj.get("externalLinks") orelse return null;
    if (links_v != .array) return null;
    for (links_v.array.items) |lv| {
        if (lv != .object) continue;
        const provider = lv.object.get("providerId") orelse continue;
        if (provider != .string) continue;
        if (!std.mem.eql(u8, provider.string, "f95zone")) continue;
        const external_id = lv.object.get("externalId") orelse continue;
        if (external_id != .string) continue;
        return std.fmt.parseUnsigned(u64, external_id.string, 10) catch null;
    }
    return null;
}

fn extractF95Rating(obj: std.json.ObjectMap) ?f32 {
    const links_v = obj.get("externalLinks") orelse return null;
    if (links_v != .array) return null;
    for (links_v.array.items) |lv| {
        if (lv != .object) continue;
        const provider = lv.object.get("providerId") orelse continue;
        if (provider != .string) continue;
        if (!std.mem.eql(u8, provider.string, "f95zone")) continue;
        const meta = lv.object.get("metadata") orelse return null;
        if (meta != .object) return null;
        const f95 = meta.object.get("f95") orelse return null;
        if (f95 != .object) return null;
        const rating = f95.object.get("rating") orelse return null;
        return switch (rating) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }
    return null;
}

fn dupeIfString(alloc: std.mem.Allocator, opt: ?std.json.Value) !?[]const u8 {
    const v = opt orelse return null;
    if (v != .string) return null;
    if (v.string.len == 0) return null;
    return try alloc.dupe(u8, v.string);
}

// ============================================================
//  tests — synthetic fixtures
// ============================================================

const testing = std.testing;

test "parseFromBytes: empty games array → empty bundle" {
    var bundle = try parseFromBytes(testing.allocator, "{\"games\":[]}");
    defer bundle.deinit();
    try testing.expectEqual(@as(usize, 0), bundle.games.len);
}

test "parseFromBytes: full xlibrary entry round-trip" {
    const json =
        \\{
        \\  "games": [
        \\    {
        \\      "id": "uuid-here",
        \\      "name": "Babysitter",
        \\      "version": "Final v0.2.2b",
        \\      "developer": "T4bbo",
        \\      "tags": ["3dcg", "romance"],
        \\      "description": "the description",
        \\      "cover": "https://cdn/cover.png",
        \\      "completionStatus": "Completed",
        \\      "externalLinks": [
        \\        {
        \\          "providerId": "f95zone",
        \\          "externalId": "2428",
        \\          "url": "https://f95zone.to/threads/thread.2428/",
        \\          "metadata": { "f95": { "rating": 4.5 } }
        \\        }
        \\      ],
        \\      "launchSettings": {
        \\        "configurations": [
        \\          { "executablePath": "Babysitter-0.2.2b.-linux/Babysitter.sh", "type": "exe" }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var bundle = try parseFromBytes(testing.allocator, json);
    defer bundle.deinit();
    try testing.expectEqual(@as(usize, 1), bundle.games.len);
    const g = bundle.games[0];
    try testing.expectEqual(@as(u64, 2428), g.thread_id);
    try testing.expectEqualStrings("Babysitter", g.name);
    try testing.expectEqualStrings("Final v0.2.2b", g.version.?);
    try testing.expectEqualStrings("T4bbo", g.developer.?);
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux/Babysitter.sh", g.install_executable_rel.?);
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux", g.installDirRel().?);
    try testing.expectEqual(@as(usize, 2), g.tags.len);
    try testing.expectEqualStrings("3dcg", g.tags[0]);
    try testing.expectEqual(@as(?f32, 4.5), g.rating);
    try testing.expectEqualStrings("Completed", g.completion_status.?);
}

test "parseFromBytes: skips games with no f95zone link" {
    const json =
        \\{
        \\  "games": [
        \\    {
        \\      "id": "uuid-1",
        \\      "name": "OnlyManual",
        \\      "externalLinks": [
        \\        { "providerId": "manual", "externalId": "" }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    var bundle = try parseFromBytes(testing.allocator, json);
    defer bundle.deinit();
    try testing.expectEqual(@as(usize, 0), bundle.games.len);
}
