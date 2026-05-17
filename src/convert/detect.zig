// Engine + Chrome-version detection. Heuristics ported from
// `fix-linux-games.sh`.

const std = @import("std");
const dom = @import("domain.zig");

/// Probe `install_dir` for engine markers. First match wins (Ren'Py
/// has highest specificity; RPGM MV vs MZ is disambiguated by `www/`).
pub fn detectEngine(io: std.Io, install_dir: []const u8) dom.Engine {
    // Ren'Py: `renpy/` and `game/` both present.
    if (exists(io, install_dir, "renpy") and exists(io, install_dir, "game"))
        return .renpy;

    // RPGM: `package.json` is required for both MV and MZ.
    if (exists(io, install_dir, "package.json")) {
        // MV: assets live under `www/`. MZ: assets at install root.
        if (exists(io, install_dir, "www")) return .rpgm_mv;
        if (exists(io, install_dir, "index.html")) return .rpgm_mz;
    }

    // Unity: any `<name>_Data/` plus a UnityPlayer shared lib.
    if (hasUnityMarkers(io, install_dir)) return .unity;

    return .unknown;
}

fn exists(io: std.Io, dir: []const u8, sub: []const u8) bool {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, sub }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn hasUnityMarkers(io: std.Io, install_dir: []const u8) bool {
    // Cheap UnityPlayer check first — only walk dir entries if it's
    // there.
    if (!exists(io, install_dir, "UnityPlayer.so") and
        !exists(io, install_dir, "UnityPlayer.dll")) return false;

    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.endsWith(u8, entry.name, "_Data")) return true;
    }
    return false;
}

// ============================================================
//  tests — fixture-driven via /tmp scratch dirs
// ============================================================

const testing = std.testing;

fn tmpDir(io: std.Io, name: []const u8) ![]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/f69-convert-detect-{s}", .{name});
    // Cleanup any previous run.
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try testing.allocator.dupe(u8, path);
}

fn touch(io: std.Io, dir: []const u8, sub: []const u8) !void {
    var p: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, sub });
    if (std.fs.path.dirname(full)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var f = try std.Io.Dir.cwd().createFile(io, full, .{ .truncate = true });
    f.close(io);
}

fn mkdir(io: std.Io, dir: []const u8, sub: []const u8) !void {
    var p: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, sub });
    try std.Io.Dir.cwd().createDirPath(io, full);
}

test "detectEngine: Ren'Py" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = try tmpDir(io, "renpy");
    defer testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try mkdir(io, root, "renpy");
    try mkdir(io, root, "game");
    try testing.expectEqual(dom.Engine.renpy, detectEngine(io, root));
}

test "detectEngine: RPGM MV (package.json + www/)" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = try tmpDir(io, "rpgm-mv");
    defer testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try touch(io, root, "package.json");
    try mkdir(io, root, "www");
    try testing.expectEqual(dom.Engine.rpgm_mv, detectEngine(io, root));
}

test "detectEngine: RPGM MZ (package.json + index.html, no www/)" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = try tmpDir(io, "rpgm-mz");
    defer testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try touch(io, root, "package.json");
    try touch(io, root, "index.html");
    try testing.expectEqual(dom.Engine.rpgm_mz, detectEngine(io, root));
}

test "detectEngine: Unity (*_Data/ + UnityPlayer.so)" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = try tmpDir(io, "unity");
    defer testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try mkdir(io, root, "MyGame_Data");
    try touch(io, root, "UnityPlayer.so");
    try testing.expectEqual(dom.Engine.unity, detectEngine(io, root));
}

test "detectEngine: empty install dir → .unknown" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = try tmpDir(io, "empty");
    defer testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try testing.expectEqual(dom.Engine.unknown, detectEngine(io, root));
}

test "detectEngine: package.json without www/ or index.html → .unknown" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = try tmpDir(io, "package-json-only");
    defer testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try touch(io, root, "package.json");
    try testing.expectEqual(dom.Engine.unknown, detectEngine(io, root));
}
