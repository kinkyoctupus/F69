// Recipe `Detect` evaluator. Pure, side-effect-free (modulo stat
// syscalls): given an install root + Host probe + a Detect tree,
// return whether the detector matches.

const std = @import("std");
const dom = @import("domain.zig");
const host_mod = @import("host.zig");

pub const Ctx = struct {
    io: std.Io,
    /// Absolute path to the install root (e.g.
    /// `<library_root>/<thread>/<version>/base`).
    install_root: []const u8,
    host: *const host_mod.Host,
};

/// Evaluate a detector. Errors surface as "no match" — the recipe
/// shouldn't fire if we can't even examine the install.
pub fn matches(ctx: *const Ctx, d: *const dom.Detect) bool {
    return switch (d.*) {
        .file_exists => |p| fileExists(ctx, p),
        .file_exists_any => |list| blk: {
            for (list) |p| if (fileExists(ctx, p)) break :blk true;
            break :blk false;
        },
        .host_lacks_soname => |s| ctx.host.lacksSoname(ctx.io, s),
        .host_lacks_sonames_all => |list| blk: {
            for (list) |s| if (ctx.host.hasSoname(ctx.io, s)) break :blk false;
            break :blk true;
        },
        .engine_fingerprint => |eng| engineFingerprint(ctx, eng),
        .all => |list| blk: {
            for (list) |*child| if (!matches(ctx, child)) break :blk false;
            break :blk true;
        },
        .any => |list| blk: {
            for (list) |*child| if (matches(ctx, child)) break :blk true;
            break :blk false;
        },
    };
}

/// Check whether `<install_root>/<relpath>` exists, OR any
/// `<install_root>/<subdir>/<relpath>` for direct subdirectories of
/// install_root. Most prebuilt game archives extract a single named
/// folder under the version dir (e.g.
/// `<install>/GoodGirlGoneBad/renpy/bootstrap.py`), so a strict
/// root-only check misses them. We bound the search at depth 1 to
/// stay cheap.
fn fileExists(ctx: *const Ctx, relpath: []const u8) bool {
    if (fileExistsAt(ctx.io, ctx.install_root, relpath)) return true;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.install_root, .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    var path_buf: [1024]u8 = undefined;
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const sub_root = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ctx.install_root, entry.name }) catch continue;
        if (fileExistsAt(ctx.io, sub_root, relpath)) return true;
    }
    return false;
}

fn fileExistsAt(io: std.Io, base: []const u8, relpath: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ base, relpath }) catch return false;
    std.Io.Dir.cwd().access(io, full, .{}) catch return false;
    return true;
}

fn engineFingerprint(ctx: *const Ctx, eng: dom.Engine) bool {
    return switch (eng) {
        .renpy => fileExists(ctx, "renpy/bootstrap.py"),
        .rpgm_mv => fileExists(ctx, "www/js/rpg_managers.js"),
        .rpgm_mz => fileExists(ctx, "js/rmmz_managers.js"),
        .unity => fileExists(ctx, "UnityPlayer.so") or
            fileExists(ctx, "UnityPlayer.dll"),
    };
}

const host_mod_for_test = @import("host.zig");

test "engineFingerprint finds Ren'Py nested one subdir deep" {
    const ta = std.testing.allocator;
    var tio = std.Io.Threaded.init(ta, .{});
    defer tio.deinit();
    const io = tio.io();

    var buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, "/tmp/f69-compat-detect-nested", .{});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    // Game lives in a subdir named after the game.
    const inner_renpy = try std.fmt.allocPrint(ta, "{s}/GoodGirlGoneBad/renpy", .{root});
    defer ta.free(inner_renpy);
    try std.Io.Dir.cwd().createDirPath(io, inner_renpy);
    const inner_bootstrap = try std.fmt.allocPrint(ta, "{s}/GoodGirlGoneBad/renpy/bootstrap.py", .{root});
    defer ta.free(inner_bootstrap);
    var f = try std.Io.Dir.cwd().createFile(io, inner_bootstrap, .{ .truncate = true });
    f.close(io);

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, ""),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();

    const ctx = Ctx{ .io = io, .install_root = root, .host = &host_obj };
    try std.testing.expect(engineFingerprint(&ctx, .renpy));
}
