// RPGM MV/MZ Win→Linux conversion. Ports `fix-linux-games.sh`'s RPGM
// path. Like the Ren'Py module, this assumes the nwjs SDK has been
// pre-extracted to `<cache>/f69/convert/sdks/nwjs-<version>/`.
//
// Round-20 in-scope: Chrome→nwjs version selection, SDK copy, launcher.
// Round-21 follow-ups:
//   - Network fetch of the nwjs tarball from dl.nwjs.io.
//   - Replacement of `lib/libffmpeg.so` with the codec-enabled build
//     from nwjs-ffmpeg-prebuilt (so MV4/MZ games that use mp4 audio
//     don't crash on a missing codec).
//   - `bundle_syslibs` ldd-driven host lib copy.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.convert_rpgm);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const sdk_cache_mod = @import("sdk_cache.zig");
const syslibs = @import("syslibs.zig");

/// Map Chrome major → nwjs version per https://nwjs.io/versions.json.
/// Keep the table here; new RPGM-era games extend it.
///
/// Mapping ported verbatim from the field-tested `fix-linux-games.sh`
/// — every Chrome major from 80 through 131 has a matching nwjs
/// release on dl.nwjs.io. Stick with these exact pairings; reaching
/// for "close enough" versions breaks games (Chromium 95 game on
/// nwjs 0.55 boots fine, on nwjs 0.50 crashes on icudtl version
/// skew — every Chrome major rebuilds icudtl).
pub fn chromeToNwjs(chrome_major: u16) ?[]const u8 {
    return switch (chrome_major) {
        41 => "0.12.3",
        80 => "0.44.6",
        85 => "0.48.4",
        86 => "0.49.2",
        87 => "0.50.3",
        88 => "0.51.2",
        89 => "0.52.2",
        90 => "0.53.1",
        91 => "0.54.1",
        92 => "0.55.0",
        93 => "0.56.1",
        94 => "0.57.1",
        95 => "0.58.0",
        96 => "0.59.1",
        97 => "0.60.0",
        98 => "0.61.1",
        99 => "0.62.2",
        100 => "0.63.1",
        101 => "0.64.1",
        102 => "0.65.1",
        103 => "0.66.1",
        104 => "0.67.1",
        105 => "0.68.1",
        106 => "0.69.1",
        107 => "0.70.1",
        108 => "0.71.1",
        109 => "0.72.0",
        110 => "0.73.0",
        111 => "0.74.0",
        112 => "0.75.0",
        113 => "0.76.1",
        114 => "0.77.0",
        115 => "0.78.1",
        116 => "0.79.1",
        117 => "0.80.0",
        118 => "0.81.0",
        119 => "0.82.0",
        120 => "0.83.0",
        121 => "0.84.0",
        122 => "0.85.0",
        123 => "0.86.0",
        124 => "0.87.0",
        125 => "0.88.0",
        126 => "0.89.0",
        127 => "0.90.0",
        128 => "0.91.0",
        129 => "0.92.0",
        130 => "0.93.0",
        131 => "0.94.0",
        else => null,
    };
}

/// Scan the game's bundled nwjs binary for its embedded Chrome version
/// string. Tries `nw.dll` then `nw_elf.dll`. Returns null when no
/// recognizable `Chrome/<digits>` string is found in the first 8 MiB.
pub fn detectChromeMajor(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
) errs.Error!?u16 {
    const candidates = [_][]const u8{ "nw.dll", "nw_elf.dll" };
    for (candidates) |name| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, name }) catch continue;
        if (findChromeInFile(alloc, io, path) catch null) |v| return v;
    }
    return null;
}

/// Cap on the prefix of a binary we read while hunting for the embedded
/// `Chrome/<N>` version. nw.dll typically embeds this near the start
/// (in resource strings); 8 MiB is plenty without paying for the
/// full ~130 MiB binary.
pub const CHROME_SCAN_BYTES: usize = 8 * 1024 * 1024;

fn findChromeInFile(alloc: std.mem.Allocator, io: Io, path: []const u8) !?u16 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer f.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rd_buf);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);

    while (data.items.len < CHROME_SCAN_BYTES) {
        var chunk: [64 * 1024]u8 = undefined;
        const got = fr.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        data.appendSlice(alloc, chunk[0..got]) catch return errs.Error.OutOfMemory;
    }
    return parseChromeMajor(data.items);
}

/// Pure. Find the first `Chrome/<digits>` substring and return the
/// integer that follows. Skips matches whose digit run doesn't parse
/// as a u16.
pub fn parseChromeMajor(bytes: []const u8) ?u16 {
    const needle = "Chrome/";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, cursor, needle)) |pos| {
        const after = pos + needle.len;
        var end = after;
        while (end < bytes.len and std.ascii.isDigit(bytes[end])) : (end += 1) {}
        if (end > after) {
            if (std.fmt.parseInt(u16, bytes[after..end], 10)) |v| {
                return v;
            } else |_| {}
        }
        cursor = pos + 1;
    }
    return null;
}

/// Resolve the nwjs version to install for this game. Recipe pin wins;
/// otherwise scan the bundled nw.dll for its Chrome major then map
/// through `chromeToNwjs`. Returns null when neither yields a hit.
pub fn nwjsVersionFor(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    recipe_pin: ?[]const u8,
) errs.Error!?[]const u8 {
    if (recipe_pin) |v| return v;
    const chrome = try detectChromeMajor(alloc, io, install_dir);
    if (chrome) |c| return chromeToNwjs(c);
    return null;
}

// ============================================================
//  install: copy nwjs runtime into the install dir
// ============================================================

/// Copy the nwjs runtime files from `nwjs_sdk_dir` into `install_dir`.
/// Walks the SDK tree, copies everything except the noise list. We
/// reuse the same symlink-preserving / streaming / mode-preserving
/// copyTree shape as Ren'Py.
pub fn installNwjs(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    nwjs_sdk_dir: []const u8,
) errs.Error!void {
    var sdk_dir = std.Io.Dir.cwd().openDir(io, nwjs_sdk_dir, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
    defer sdk_dir.close(io);

    std.Io.Dir.cwd().createDirPath(io, install_dir) catch return errs.Error.InstallNotFound;

    var walker = sdk_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    var copied: u32 = 0;
    while (walker.next(io) catch null) |entry| {
        if (isSdkNoise(entry.path)) continue;

        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ install_dir, entry.path }) catch return errs.Error.OutOfMemory;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ nwjs_sdk_dir, entry.path }) catch return errs.Error.OutOfMemory;

        switch (entry.kind) {
            .directory => std.Io.Dir.cwd().createDirPath(io, dest_path) catch return errs.Error.LauncherWriteFailed,
            .file => {
                copyFile(io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed;
                copied += 1;
            },
            .sym_link => copySymlink(alloc, io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed,
            else => {},
        }
    }

    if (copied == 0) {
        log.warn("nwjs SDK at {s} produced 0 file copies — layout suspect", .{nwjs_sdk_dir});
        return errs.Error.SdkLayoutInvalid;
    }
    log.info("installNwjs: copied {d} file(s) from {s} → {s}", .{ copied, nwjs_sdk_dir, install_dir });
}

/// Files we don't want to drag into the game install. credits.html is
/// the nwjs license bundle — not load-bearing. The .nwb/.so/.exe-only
/// SDK-development bits aren't shipped to begin with.
fn isSdkNoise(path: []const u8) bool {
    return std.mem.eql(u8, path, "credits.html");
}

fn copyFile(io: Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        // readSliceShort aliases its source if the destination is the
        // reader's own backing buffer — keep them distinct.
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
    }
    try out_writer.interface.flush();

    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}

fn copySymlink(alloc: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    const buf = try alloc.alloc(u8, 4096);
    defer alloc.free(buf);
    const n = try std.Io.Dir.cwd().readLink(io, src, buf);
    const target = buf[0..n];

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    std.Io.Dir.cwd().deleteFile(io, dest) catch {};
    try std.Io.Dir.cwd().symLink(io, target, dest, .{});
}

// ============================================================
//  launcher
// ============================================================

/// Pick the launcher base name. RPGM convention is `Game.exe`; some
/// games rename. Strategy:
///   1. First `Game.exe` (case-sensitive) wins.
///   2. Otherwise the first non-noise `*.exe` (skip crash handlers).
///   3. Fall back to "Game" if nothing matched.
pub fn findLauncherName(alloc: std.mem.Allocator, io: Io, install_dir: []const u8) errs.Error!?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.InstallNotFound;
    defer dir.close(io);

    var it = dir.iterate();
    var fallback: ?[]u8 = null;
    errdefer if (fallback) |x| alloc.free(x);

    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".exe")) continue;
        if (std.mem.startsWith(u8, entry.name, "notification_helper")) continue;
        if (std.mem.startsWith(u8, entry.name, "crashpad_handler")) continue;
        if (std.mem.eql(u8, entry.name, "nw.exe")) continue; // nwjs runtime, not the game

        const base = entry.name[0 .. entry.name.len - 4];
        if (std.mem.eql(u8, base, "Game")) {
            if (fallback) |x| alloc.free(x);
            return alloc.dupe(u8, base) catch errs.Error.OutOfMemory;
        }
        if (fallback == null) {
            fallback = alloc.dupe(u8, base) catch return errs.Error.OutOfMemory;
        }
    }
    if (fallback) |x| return x;
    return alloc.dupe(u8, "Game") catch errs.Error.OutOfMemory;
}

/// Write the Linux launcher script. The same template covers MV and
/// MZ — nwjs `./nw .` reads `package.json`'s `main` and figures the
/// rest out itself.
pub fn writeLauncher(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    name: []const u8,
    wrap_steam_run: bool,
) errs.Error!void {
    const content = renderLauncher(alloc, wrap_steam_run) catch return errs.Error.OutOfMemory;
    defer alloc.free(content);

    var path_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sh", .{ install_dir, name }) catch return errs.Error.OutOfMemory;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = content }) catch return errs.Error.LauncherWriteFailed;

    var f = std.Io.Dir.cwd().openFile(io, sh_path, .{ .mode = .read_write }) catch return errs.Error.LauncherWriteFailed;
    defer f.close(io);
    f.setPermissions(io, .executable_file) catch return errs.Error.LauncherWriteFailed;
}

/// Pure. Returns the launcher script body. GDK_BACKEND=x11 is forced
/// when Wayland is in use because older nwjs (pre-0.50) lacks Wayland
/// support; for newer nwjs the override is harmless (chromium honors
/// the env var as a hint, then negotiates).
pub fn renderLauncher(alloc: std.mem.Allocator, wrap_steam_run: bool) ![]u8 {
    const exec_prefix = if (wrap_steam_run) "exec steam-run " else "exec ";
    return std.fmt.allocPrint(alloc,
        \\#!/usr/bin/env bash
        \\# auto-generated RPGM (nwjs) Linux launcher (f69)
        \\cd "$(dirname "$(readlink -f "$0")")"
        \\
        \\export LD_LIBRARY_PATH="$(pwd):${{LD_LIBRARY_PATH:-}}"
        \\
        \\# Force X11 on Wayland — older nwjs has no Wayland support; newer
        \\# (≥ 0.50) safely accepts the hint.
        \\if [ -n "${{WAYLAND_DISPLAY:-}}" ]; then
        \\  export GDK_BACKEND="x11"
        \\fi
        \\
        \\if [ ! -x "./nw" ]; then echo "nw binary missing — convert step incomplete" >&2; exit 1; fi
        \\
        \\{s}"./nw" . "$@"
        \\
    , .{exec_prefix});
}

// ============================================================
//  idempotency
// ============================================================

/// Already-converted check: launcher exists AND `./nw` is present +
/// executable.
pub fn alreadyConverted(io: Io, install_dir: []const u8, launcher_base: []const u8) bool {
    var sh_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&sh_buf, "{s}/{s}.sh", .{ install_dir, launcher_base }) catch return false;
    std.Io.Dir.cwd().access(io, sh_path, .{}) catch return false;

    var nw_buf: [512]u8 = undefined;
    const nw_path = std.fmt.bufPrint(&nw_buf, "{s}/nw", .{install_dir}) catch return false;
    std.Io.Dir.cwd().access(io, nw_path, .{ .execute = true }) catch return false;
    return true;
}

// ============================================================
//  orchestrator — called from convert/service.zig
// ============================================================

pub fn convert(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    cache: *sdk_cache_mod.Cache,
    distro: dom.Distro,
    recipe_pin_nwjs: ?[]const u8,
    ffmpeg_codecs: bool,
    bundle_syslibs: bool,
    force: bool,
) errs.Error!void {

    std.Io.Dir.cwd().access(io, install_dir, .{}) catch return errs.Error.InstallNotFound;

    const version = try nwjsVersionFor(alloc, io, install_dir, recipe_pin_nwjs) orelse {
        log.warn("convert: no nwjs version pinned + couldn't detect from nw.dll", .{});
        return errs.Error.VersionDetectFailed;
    };
    log.info("convert: nwjs {s} ({s})", .{ version, install_dir });

    const launcher = try findLauncherName(alloc, io, install_dir) orelse {
        log.warn("convert: no <name>.exe to base the launcher on", .{});
        return errs.Error.LauncherNotFound;
    };
    defer alloc.free(launcher);

    if (!force and alreadyConverted(io, install_dir, launcher)) {
        log.info("convert: install already converted ({s}.sh + ./nw exist); use force=true to rebuild", .{launcher});
        return;
    }

    const sdk_path = cache.locate("nwjs", version) catch |e| switch (e) {
        errs.Error.SdkNotCached => blk: {
            log.info("nwjs {s} SDK not cached; fetching", .{version});
            break :blk try cache.fetch("nwjs", version);
        },
        else => return e,
    };
    defer alloc.free(sdk_path);

    try installNwjs(alloc, io, install_dir, sdk_path);

    // Optional codec-enabled libffmpeg.so swap. Many F95 RPGM MZ games
    // ship .m4a / .mp4 assets that the stripped libffmpeg can't decode
    // — without this they crash on first audio cue. Recipe opts out
    // via `ffmpeg_codecs: false`.
    if (ffmpeg_codecs) {
        installFfmpegCodecs(alloc, io, cache, install_dir, version) catch |e| {
            log.warn("ffmpeg codec swap failed: {s} (game may crash on .mp4 / .m4a audio)", .{@errorName(e)});
        };
    }

    if (bundle_syslibs) {
        syslibs.bundle(alloc, io, install_dir, "nw", distro) catch |e| {
            log.warn("syslib bundle failed: {s} (game may crash on missing libs)", .{@errorName(e)});
        };
    }

    try writeLauncher(alloc, io, install_dir, launcher, distro == .nixos);
    log.info("convert: wrote {s}.sh (steam-run wrap: {})", .{ launcher, distro == .nixos });
}

/// Fetch the codec-enabled libffmpeg.so from nwjs-ffmpeg-prebuilt and
/// overwrite the SDK's stripped copy at `<install>/lib/libffmpeg.so`.
/// The prebuilt release versions track nwjs versions 1:1.
pub fn installFfmpegCodecs(
    alloc: std.mem.Allocator,
    io: Io,
    cache: *sdk_cache_mod.Cache,
    install_dir: []const u8,
    nwjs_version: []const u8,
) errs.Error!void {
    const sdk_path = try cache.fetch("nwjs-ffmpeg", nwjs_version);
    defer alloc.free(sdk_path);

    var src_buf: [640]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{s}/libffmpeg.so", .{sdk_path}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().access(io, src, .{}) catch {
        log.warn("ffmpeg prebuilt at {s} has no libffmpeg.so — release layout changed?", .{sdk_path});
        return errs.Error.SdkLayoutInvalid;
    };

    var dst_buf: [640]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/lib/libffmpeg.so", .{install_dir}) catch return errs.Error.OutOfMemory;

    copyFile(io, src, dst) catch return errs.Error.LauncherWriteFailed;
    log.info("ffmpeg codec swap: {s} → {s}", .{ src, dst });
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

test "chromeToNwjs: known entries" {
    try testing.expectEqualStrings("0.83.0", chromeToNwjs(120).?);
    try testing.expectEqualStrings("0.12.3", chromeToNwjs(41).?);
    try testing.expectEqualStrings("0.93.0", chromeToNwjs(130).?);
}

test "chromeToNwjs: unknown major → null" {
    try testing.expect(chromeToNwjs(7) == null);
    try testing.expect(chromeToNwjs(200) == null);
}

test "parseChromeMajor: basic" {
    try testing.expectEqual(@as(u16, 120), parseChromeMajor("blob ... Chrome/120.0.6099.123 zlib").?);
}

test "parseChromeMajor: takes first match" {
    // First "Chrome/N" wins even if a stale value appears later.
    try testing.expectEqual(@as(u16, 80), parseChromeMajor("Chrome/80\nlater Chrome/120").?);
}

test "parseChromeMajor: missing → null" {
    try testing.expect(parseChromeMajor("nothing here") == null);
}

test "parseChromeMajor: 'Chrome/' followed by non-digits → null" {
    try testing.expect(parseChromeMajor("Chrome/foo and Chrome/bar") == null);
}

test "parseChromeMajor: skips bad match, finds good one" {
    // First match's digit run doesn't parse as u16 (too long); skip to next.
    try testing.expectEqual(@as(u16, 100), parseChromeMajor("Chrome/99999999999 then Chrome/100.0").?);
}

test "renderLauncher: NixOS steam-run wrap" {
    const out = try renderLauncher(testing.allocator, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "exec steam-run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"./nw\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GDK_BACKEND") != null);
}

test "renderLauncher: plain exec on non-NixOS" {
    const out = try renderLauncher(testing.allocator, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "steam-run") == null);
    try testing.expect(std.mem.indexOf(u8, out, "exec \"./nw\"") != null);
}

test "renderLauncher: cd to script dir + LD_LIBRARY_PATH" {
    const out = try renderLauncher(testing.allocator, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, out, "LD_LIBRARY_PATH=\"$(pwd)") != null);
}

test "isSdkNoise: credits.html" {
    try testing.expect(isSdkNoise("credits.html"));
    try testing.expect(!isSdkNoise("nw"));
    try testing.expect(!isSdkNoise("lib/libffmpeg.so"));
}

test "nwjsVersionFor: recipe pin wins" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const v = try nwjsVersionFor(testing.allocator, io, "/nonexistent", "0.83.0");
    try testing.expect(v != null);
    try testing.expectEqualStrings("0.83.0", v.?);
}

test "nwjsVersionFor: no pin + no nw.dll → null" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    // /tmp is unlikely to have nw.dll.
    const v = try nwjsVersionFor(testing.allocator, io, "/tmp", null);
    try testing.expect(v == null);
}
