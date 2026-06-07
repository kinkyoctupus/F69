// Theme persistence — loads/saves the active theme to `<data_root>/theme.zon`
// so user color choices survive restart. The path is set once at startup
// (main) and reused by the Settings → Appearance save. Pure parse/format
// lives in `tokens`; this is the thin disk glue.

const std = @import("std");
const tokens = @import("ui_tokens");
const atomic_io = @import("util_atomic_io");
const TestEnv = @import("util_test_env").TestEnv;

var path_buf: [1024]u8 = undefined;
var path: []const u8 = "";

/// Record the on-disk theme path (called once at startup).
pub fn setPath(p: []const u8) void {
    const n = @min(p.len, path_buf.len);
    @memcpy(path_buf[0..n], p[0..n]);
    path = path_buf[0..n];
}

/// Load the saved theme onto the console preset (preset + overrides). No-op if
/// unset/missing/unreadable — the default console theme stays.
pub fn load(io: std.Io, alloc: std.mem.Allocator) void {
    if (path.len == 0) return;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024)) catch return;
    defer alloc.free(bytes);
    tokens.active = tokens.parseTheme(tokens.presets.console, bytes);
}

/// Persist the active theme atomically. Best-effort (errors ignored).
pub fn save(io: std.Io) void {
    if (path.len == 0) return;
    var buf: [2048]u8 = undefined;
    const text = tokens.formatTheme(tokens.active, &buf);
    atomic_io.writeFileAtomic(io, path, text) catch {};
}

test "theme_store round-trips the active theme through disk" {
    defer tokens.active = tokens.presets.console; // don't leak state to other tests
    var env = try TestEnv.init(std.testing.allocator, "theme-store");
    defer env.deinit();
    const p = try env.path("theme.zon");
    defer std.testing.allocator.free(p);

    setPath(p);
    tokens.active = tokens.presets.obsidian;
    save(env.io);
    tokens.active = tokens.presets.console; // clobber, then reload from disk
    load(env.io, std.testing.allocator);
    try std.testing.expectEqual(tokens.presets.obsidian, tokens.active);
}
