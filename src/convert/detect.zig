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
//  tests — fixture-driven via TestEnv tmpdirs
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "detectEngine: Ren'Py" {
    var env = try test_env.TestEnv.init(testing.allocator, "detect-renpy");
    defer env.deinit();

    try env.mkdirP("renpy");
    try env.mkdirP("game");
    try testing.expectEqual(dom.Engine.renpy, detectEngine(env.io, env.root));
}

test "detectEngine: RPGM MV (package.json + www/)" {
    var env = try test_env.TestEnv.init(testing.allocator, "detect-rpgm-mv");
    defer env.deinit();

    try env.touchFile("package.json");
    try env.mkdirP("www");
    try testing.expectEqual(dom.Engine.rpgm_mv, detectEngine(env.io, env.root));
}

test "detectEngine: RPGM MZ (package.json + index.html, no www/)" {
    var env = try test_env.TestEnv.init(testing.allocator, "detect-rpgm-mz");
    defer env.deinit();

    try env.touchFile("package.json");
    try env.touchFile("index.html");
    try testing.expectEqual(dom.Engine.rpgm_mz, detectEngine(env.io, env.root));
}

test "detectEngine: Unity (*_Data/ + UnityPlayer.so)" {
    var env = try test_env.TestEnv.init(testing.allocator, "detect-unity");
    defer env.deinit();

    try env.mkdirP("MyGame_Data");
    try env.touchFile("UnityPlayer.so");
    try testing.expectEqual(dom.Engine.unity, detectEngine(env.io, env.root));
}

test "detectEngine: empty install dir → .unknown" {
    var env = try test_env.TestEnv.init(testing.allocator, "detect-empty");
    defer env.deinit();

    try testing.expectEqual(dom.Engine.unknown, detectEngine(env.io, env.root));
}

test "detectEngine: package.json without www/ or index.html → .unknown" {
    var env = try test_env.TestEnv.init(testing.allocator, "detect-pkgjson-only");
    defer env.deinit();

    try env.touchFile("package.json");
    try testing.expectEqual(dom.Engine.unknown, detectEngine(env.io, env.root));
}
