// Recipe `Detect` evaluator. Pure, side-effect-free (modulo stat
// syscalls): given an install root + Host probe + a Detect tree,
// return whether the detector matches.

const std = @import("std");
const dom = @import("domain.zig");
const host_mod = @import("host.zig");
const util_version = @import("util_version");
const util_renpy = @import("util_renpy");

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
        .host_lacks_any_soname => |list| blk: {
            for (list) |s| if (ctx.host.lacksSoname(ctx.io, s)) break :blk true;
            break :blk false;
        },
        .engine_fingerprint => |eng| engineFingerprint(ctx, eng),
        .engine_version_at_most => |b| versionMatches(ctx, b, .at_most),
        .engine_version_at_least => |b| versionMatches(ctx, b, .at_least),
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

const VersionMatchMode = enum { at_most, at_least };

/// Read the engine's installed version + compare against `bound.version`.
/// Returns false on probe failure ("can't tell" defaults to "not a
/// match" — the recipe doesn't fire if we can't confirm). The
/// per-engine probe is delegated to the shared util module so the
/// parsers stay in one place (also used by `convert/renpy.zig`).
fn versionMatches(ctx: *const Ctx, bound: dom.EngineVersionBound, mode: VersionMatchMode) bool {
    // FBA scratch — probe reads at most 256 KiB and frees before
    // returning, so 4 KiB stack is plenty for the bufPrint paths.
    var stack_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const detected_opt: ?[]const u8 = switch (bound.engine) {
        .renpy => detectRenpyVersion(ctx, fba.allocator()),
        // Other engines: version probing not implemented yet. Returning
        // null here means engine_version_at_* never matches for them —
        // an upcoming patch can flesh out per-engine probes.
        else => null,
    };
    const detected = detected_opt orelse return false;
    const ord = util_version.compare(detected, bound.version);
    return switch (mode) {
        .at_most => ord != .gt,
        .at_least => ord != .lt,
    };
}

/// Try `<install_root>` first, then one level of subdir nesting
/// (prebuilt games extract under a named folder like
/// `<install>/GoodGirlGoneBad/renpy/...`). Reuses
/// `util_renpy.detectVersion` for the actual parse.
fn detectRenpyVersion(ctx: *const Ctx, alloc: std.mem.Allocator) ?[]const u8 {
    if (util_renpy.detectVersion(alloc, ctx.io, ctx.install_root) catch null) |v| return v;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.install_root, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    var sub_buf: [1024]u8 = undefined;
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const sub_root = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ ctx.install_root, entry.name }) catch continue;
        if (util_renpy.detectVersion(alloc, ctx.io, sub_root) catch null) |v| return v;
    }
    return null;
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
        // Other engines: no fingerprint heuristic yet — fall through.
        else => false,
    };
}

const host_mod_for_test = @import("host.zig");
const test_env = @import("util_test_env");

test "host_lacks_any_soname fires when at least one is missing" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-host-lacks");
    defer env.deinit();

    // Synthetic search dir: holds libfoo.so.1, but not libbar.so.99.
    // Host's soname_search points only at this dir so the result is
    // deterministic regardless of what the real system has installed.
    try env.touchFile("libfoo.so.1");

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, env.root),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();

    const ctx = Ctx{ .io = env.io, .install_root = "/tmp/never-exists-f69-test", .host = &host_obj };
    const both_present = [_][]const u8{ "libfoo.so.1", "libfoo.so.1" };
    const one_missing = [_][]const u8{ "libfoo.so.1", "libbar.so.99" };

    try std.testing.expect(!matches(&ctx, &.{ .host_lacks_any_soname = &both_present }));
    try std.testing.expect(matches(&ctx, &.{ .host_lacks_any_soname = &one_missing }));
}

test "engine_version_at_most fires on Ren'Py 7" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-renpy7-version");
    defer env.deinit();

    try env.writeFile("renpy/vc_version.py", "version = u'7.6.1.23060707'\n");

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, ""),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();
    const ctx = Ctx{ .io = env.io, .install_root = env.root, .host = &host_obj };

    try std.testing.expect(matches(&ctx, &.{ .engine_version_at_most = .{ .engine = .renpy, .version = "7.99" } }));
    try std.testing.expect(!matches(&ctx, &.{ .engine_version_at_least = .{ .engine = .renpy, .version = "8.0" } }));
}

test "engineFingerprint finds Ren'Py nested one subdir deep" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-detect-nested");
    defer env.deinit();

    // Game lives in a subdir named after the game.
    try env.touchFile("GoodGirlGoneBad/renpy/bootstrap.py");

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, ""),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();

    const ctx = Ctx{ .io = env.io, .install_root = env.root, .host = &host_obj };
    try std.testing.expect(engineFingerprint(&ctx, .renpy));
}
