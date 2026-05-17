// XDG path helpers + project-specific path conventions.

const std = @import("std");

pub const Error = error{ NoHomeDir, OutOfMemory };

/// `$XDG_CONFIG_HOME` or `$HOME/.config`. Caller frees.
pub fn configHome(alloc: std.mem.Allocator) Error![]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |x| return x else |_| {}
    const h = std.process.getEnvVarOwned(alloc, "HOME") catch return Error.NoHomeDir;
    defer alloc.free(h);
    return std.fmt.allocPrint(alloc, "{s}/.config", .{h}) catch Error.OutOfMemory;
}

/// `$XDG_CACHE_HOME` or `$HOME/.cache`. Caller frees.
pub fn cacheHome(alloc: std.mem.Allocator) Error![]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_CACHE_HOME")) |x| return x else |_| {}
    const h = std.process.getEnvVarOwned(alloc, "HOME") catch return Error.NoHomeDir;
    defer alloc.free(h);
    return std.fmt.allocPrint(alloc, "{s}/.cache", .{h}) catch Error.OutOfMemory;
}

/// `$HOME`. Caller frees.
pub fn home(alloc: std.mem.Allocator) Error![]u8 {
    return std.process.getEnvVarOwned(alloc, "HOME") catch Error.NoHomeDir;
}

/// `<library_root>/<game_id>/<version>/`. Caller frees.
pub fn installDir(alloc: std.mem.Allocator, library_root: []const u8, game_id: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ library_root, game_id, version });
}

/// `<config_home>/f69/sandbox/<game_id>/`. Per-game (NOT per-install) so
/// saves carry across versions. Caller frees.
pub fn sandboxHome(alloc: std.mem.Allocator, config_home: []const u8, game_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/f69/sandbox/{s}", .{ config_home, game_id });
}
