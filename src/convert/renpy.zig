// Ren'Py Win→Linux conversion. Production port of
// `spikes/spike-03-renpy-convert.zig` (NixOS-validated 2026-05-08).
//
// Fixes applied vs the spike (per spike-03 findings):
//   - Symlink preservation in tree copy (recreates via `Dir.symLink`).
//   - Streaming reads via `File.Reader` → `File.Writer` (no `readFileAlloc`
//     for big files).
//   - Mode preservation on file copies (executable bit on python).
//   - Mode-aware launcher write (chmod +x via `setPermissions`).
//
// Network SDK fetch is deferred. The SDK must be pre-extracted at
// `<cache>/f69/convert/sdks/renpy-<v>/`; otherwise `Service.convert`
// returns `SdkNotCached` with the expected path.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.convert_renpy);
const errs = @import("errors.zig");
const dom = @import("domain.zig");

/// Detect the Ren'Py version that built this game. Tries the modern
/// `renpy/vc_version.py` (Ren'Py ≥7.4 ships it) first; falls back to
/// `renpy/__init__.py`'s `version_tuple = (...)`. Returns "X.Y.Z" — or
/// `null` when neither file is parseable.
pub fn detectVersion(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
) errs.Error!?[]u8 {
    // ---- vc_version.py: `version = u'7.6.1.23060707'` ----
    {
        var path_buf: [512]u8 = undefined;
        const vc_path = std.fmt.bufPrint(&path_buf, "{s}/renpy/vc_version.py", .{install_dir}) catch return errs.Error.OutOfMemory;
        const content = std.Io.Dir.cwd().readFileAlloc(io, vc_path, alloc, .limited(64 * 1024)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return errs.Error.VersionDetectFailed,
        };
        if (content) |c| {
            defer alloc.free(c);
            if (parseVcVersion(c)) |raw| {
                return takeMajMinPatch(alloc, raw) catch errs.Error.OutOfMemory;
            }
        }
    }

    // ---- __init__.py: `version_tuple = (7, 5, 3, vc_version)` ----
    {
        var path_buf: [512]u8 = undefined;
        const init_path = std.fmt.bufPrint(&path_buf, "{s}/renpy/__init__.py", .{install_dir}) catch return errs.Error.OutOfMemory;
        const content = std.Io.Dir.cwd().readFileAlloc(io, init_path, alloc, .limited(256 * 1024)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return errs.Error.VersionDetectFailed,
        };
        if (content) |c| {
            defer alloc.free(c);
            return parseVersionTuple(alloc, c) catch errs.Error.OutOfMemory;
        }
    }

    return null;
}

/// Pure. Parses `version = u'X.Y.Z.BUILD'` or `version = 'X.Y.Z.BUILD'`.
/// Returns the inner literal (borrowed from `content`).
pub fn parseVcVersion(content: []const u8) ?[]const u8 {
    const marker_a = "version = u'";
    const marker_b = "version = '";
    const start_a = std.mem.indexOf(u8, content, marker_a);
    const start_b = std.mem.indexOf(u8, content, marker_b);
    const start, const marker_len = blk: {
        if (start_a) |a| break :blk .{ a, marker_a.len };
        if (start_b) |b| break :blk .{ b, marker_b.len };
        return null;
    };
    const value_start = start + marker_len;
    const end = std.mem.indexOfScalarPos(u8, content, value_start, '\'') orelse return null;
    return content[value_start..end];
}

/// Pure. "7.6.1.23060707" → "7.6.1" (allocates). Strings shorter than
/// 3 dot-separated parts are returned as a dup of `raw`.
pub fn takeMajMinPatch(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |p| : (n += 1) {
        if (n >= 3) break;
        parts[n] = p;
    }
    if (n < 3) return alloc.dupe(u8, raw);
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ parts[0], parts[1], parts[2] });
}

/// Pure. Parses `version_tuple = (7, 5, 3, vc_version)` style.
/// Returns allocator-owned "X.Y.Z" or null.
pub fn parseVersionTuple(alloc: std.mem.Allocator, content: []const u8) !?[]u8 {
    const marker = "version_tuple = (";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const open = start + marker.len;
    const close = std.mem.indexOfScalarPos(u8, content, open, ')') orelse return null;
    const inside = content[open..close];

    var nums: [3]u32 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, inside, ',');
    while (it.next()) |raw_part| {
        if (n >= 3) break;
        const t = std.mem.trim(u8, raw_part, " \t");
        const v = std.fmt.parseInt(u32, t, 10) catch continue;
        nums[n] = v;
        n += 1;
    }
    if (n == 0) return null;
    return try std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ nums[0], nums[1], nums[2] });
}

// ============================================================
//  install: copy SDK Linux libs into the install dir
// ============================================================

/// Copy `lib/py3-linux-x86_64` (or py2, or linux-x86_64) + every
/// `lib/python*` dir from `sdk_dir` into `install_dir`. The launcher
/// picks whichever variants exist at runtime.
///
/// Symlinks are preserved (Ren'Py SDKs ship `lib/python` as a symlink
/// to the real `lib/python3.9` etc — losing it breaks the runtime).
/// File modes are preserved (the python interpreter is +x).
pub fn installLinuxLibs(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    sdk_dir: []const u8,
) errs.Error!void {
    var sdk_lib_buf: [512]u8 = undefined;
    const sdk_lib = std.fmt.bufPrint(&sdk_lib_buf, "{s}/lib", .{sdk_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().access(io, sdk_lib, .{}) catch {
        log.warn("SDK has no `lib/` directory: {s}", .{sdk_dir});
        return errs.Error.SdkLayoutInvalid;
    };

    // Make sure the install dir's `lib/` exists.
    var install_lib_buf: [512]u8 = undefined;
    const install_lib = std.fmt.bufPrint(&install_lib_buf, "{s}/lib", .{install_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, install_lib) catch return errs.Error.LauncherWriteFailed;

    var sdk_lib_dir = std.Io.Dir.cwd().openDir(io, sdk_lib, .{ .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
    defer sdk_lib_dir.close(io);

    var it = sdk_lib_dir.iterate();
    var copied: u32 = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const keep = std.mem.startsWith(u8, entry.name, "py3-linux-x86_64") or
            std.mem.startsWith(u8, entry.name, "py2-linux-x86_64") or
            std.mem.startsWith(u8, entry.name, "linux-x86_64") or
            std.mem.startsWith(u8, entry.name, "python");
        if (!keep) continue;

        var src_buf: [640]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ sdk_lib, entry.name }) catch return errs.Error.OutOfMemory;
        var dest_buf: [640]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ install_lib, entry.name }) catch return errs.Error.OutOfMemory;
        try copyTree(alloc, io, src, dest);
        copied += 1;
    }

    if (copied == 0) {
        log.warn("SDK `lib/` had no matching Linux runtime dirs", .{});
        return errs.Error.SdkLayoutInvalid;
    }
    log.info("installLinuxLibs: copied {d} dir(s) from {s} → {s}", .{ copied, sdk_lib, install_lib });
}

/// Recursive copy preserving symlinks + file modes. Streams file
/// content (no `readFileAlloc`-style memory spikes).
fn copyTree(
    alloc: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
) errs.Error!void {
    std.Io.Dir.cwd().createDirPath(io, dest) catch return errs.Error.LauncherWriteFailed;

    var src_dir = std.Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
    defer src_dir.close(io);

    var walker = src_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest, entry.path }) catch return errs.Error.OutOfMemory;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.path }) catch return errs.Error.OutOfMemory;

        switch (entry.kind) {
            .directory => std.Io.Dir.cwd().createDirPath(io, dest_path) catch return errs.Error.LauncherWriteFailed,
            .file => copyFile(io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed,
            .sym_link => copySymlink(alloc, io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed,
            else => {}, // sockets, fifos, devices — skip
        }
    }
}

/// Copy `src` → `dest` streaming; preserves source mode bits (notably
/// the executable bit on `lib/.../python`).
fn copyFile(io: Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    // Stream copy — 64 KiB chunks. `chunk` distinct from `rd_buf` so
    // readSliceShort's @memcpy doesn't alias its own backing buffer.
    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
    }
    try out_writer.interface.flush();

    // Preserve mode bits (executable, etc.).
    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}

/// Read the symlink target and recreate at `dest`. Failure to read is
/// fatal; failure to recreate (e.g. dest dir missing) is fatal too.
fn copySymlink(alloc: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    // 4 KiB is enough for any sane symlink target; Linux `PATH_MAX` is
    // 4096. Use a heap buffer so we don't bake the assumption in.
    const buf = try alloc.alloc(u8, 4096);
    defer alloc.free(buf);
    const n = try std.Io.Dir.cwd().readLink(io, src, buf);
    const target = buf[0..n];

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    // If a stale dest exists from a previous run, drop it so symLink
    // doesn't fail with EEXIST.
    std.Io.Dir.cwd().deleteFile(io, dest) catch {};
    try std.Io.Dir.cwd().symLink(io, target, dest, .{});
}

// ============================================================
//  launcher
// ============================================================

/// Pick the launcher base name from a game's root dir. First non-noise
/// `<name>.py` wins (Ren'Py convention); falls back to `<name>.exe`.
pub fn findLauncherName(alloc: std.mem.Allocator, io: Io, install_dir: []const u8) errs.Error!?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.InstallNotFound;
    defer dir.close(io);

    var it = dir.iterate();
    var fallback_exe: ?[]u8 = null;
    errdefer if (fallback_exe) |x| alloc.free(x);

    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".py") and
            !std.mem.eql(u8, entry.name, "log.py") and
            !std.mem.eql(u8, entry.name, "__init__.py"))
        {
            const base = entry.name[0 .. entry.name.len - 3];
            if (fallback_exe) |x| alloc.free(x);
            return alloc.dupe(u8, base) catch errs.Error.OutOfMemory;
        }
        if (std.mem.endsWith(u8, entry.name, ".exe") and
            !std.mem.startsWith(u8, entry.name, "notification_helper") and
            !std.mem.startsWith(u8, entry.name, "UnityCrashHandler"))
        {
            if (fallback_exe == null) {
                fallback_exe = alloc.dupe(u8, entry.name[0 .. entry.name.len - 4]) catch return errs.Error.OutOfMemory;
            }
        }
    }
    return fallback_exe;
}

/// Write the Linux launcher script + chmod +x. `name` is the base
/// (no extension); the script lands at `<install_dir>/<name>.sh`.
/// `wrap_steam_run = true` on NixOS so the launcher gets glibc.
pub fn writeLauncher(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    name: []const u8,
    wrap_steam_run: bool,
) errs.Error!void {
    const content = renderLauncher(alloc, name, wrap_steam_run) catch return errs.Error.OutOfMemory;
    defer alloc.free(content);

    var path_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sh", .{ install_dir, name }) catch return errs.Error.OutOfMemory;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = content }) catch return errs.Error.LauncherWriteFailed;

    var f = std.Io.Dir.cwd().openFile(io, sh_path, .{ .mode = .read_write }) catch return errs.Error.LauncherWriteFailed;
    defer f.close(io);
    f.setPermissions(io, .executable_file) catch return errs.Error.LauncherWriteFailed;
}

/// Pure. Returns allocator-owned launcher script body.
pub fn renderLauncher(alloc: std.mem.Allocator, name: []const u8, wrap_steam_run: bool) ![]u8 {
    const exec_prefix = if (wrap_steam_run) "exec steam-run " else "exec ";
    return std.fmt.allocPrint(alloc,
        \\#!/usr/bin/env bash
        \\# auto-generated Ren'Py Linux launcher (f69)
        \\cd "$(dirname "$(readlink -f "$0")")"
        \\
        \\ARCH="x86_64"
        \\if   [ -d "lib/py3-linux-${{ARCH}}" ]; then LIB="lib/py3-linux-${{ARCH}}"
        \\elif [ -d "lib/py2-linux-${{ARCH}}" ]; then LIB="lib/py2-linux-${{ARCH}}"
        \\elif [ -d "lib/linux-${{ARCH}}" ];     then LIB="lib/linux-${{ARCH}}"
        \\else echo "no Linux runtime libs found" >&2; exit 1; fi
        \\
        \\export LD_LIBRARY_PATH="${{LIB}}:${{LD_LIBRARY_PATH:-}}"
        \\export RENPY_PLATFORM="linux-${{ARCH}}"
        \\
        \\if   [ -x "${{LIB}}/python" ];  then PYTHON="${{LIB}}/python"
        \\elif [ -x "${{LIB}}/pythonw" ]; then PYTHON="${{LIB}}/pythonw"
        \\elif [ -x "${{LIB}}/python3" ]; then PYTHON="${{LIB}}/python3"
        \\else echo "no python in ${{LIB}}" >&2; exit 1; fi
        \\
        \\{s}"${{PYTHON}}" -EO "{s}.py" "$@"
        \\
    , .{ exec_prefix, name });
}

// ============================================================
//  idempotency
// ============================================================

/// Already-converted check — mirrors `fix-linux-games.sh`'s
/// `has_linux_support`. True iff (a) `<name>.sh` exists at install
/// root AND (b) at least one `lib/.linux-x86_64` dir is present.
pub fn alreadyConverted(io: Io, install_dir: []const u8, launcher_base: []const u8) bool {
    var sh_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&sh_buf, "{s}/{s}.sh", .{ install_dir, launcher_base }) catch return false;
    std.Io.Dir.cwd().access(io, sh_path, .{}) catch return false;

    const lib_subs = [_][]const u8{ "lib/py3-linux-x86_64", "lib/py2-linux-x86_64", "lib/linux-x86_64" };
    for (lib_subs) |sub| {
        var lib_buf: [512]u8 = undefined;
        const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/{s}", .{ install_dir, sub }) catch continue;
        if (std.Io.Dir.cwd().access(io, lib_path, .{})) |_| return true else |_| {}
    }
    return false;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

test "parseVcVersion: u-prefixed" {
    const v = parseVcVersion("# top\nversion = u'7.6.1.23060707'\nfoo = 1");
    try testing.expect(v != null);
    try testing.expectEqualStrings("7.6.1.23060707", v.?);
}

test "parseVcVersion: plain quotes" {
    const v = parseVcVersion("version = '8.1.0.1234567'");
    try testing.expect(v != null);
    try testing.expectEqualStrings("8.1.0.1234567", v.?);
}

test "parseVcVersion: missing → null" {
    try testing.expect(parseVcVersion("nope") == null);
}

test "takeMajMinPatch: 4 components → 3" {
    const v = try takeMajMinPatch(testing.allocator, "7.6.1.23060707");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("7.6.1", v);
}

test "takeMajMinPatch: already 3" {
    const v = try takeMajMinPatch(testing.allocator, "7.5.3");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("7.5.3", v);
}

test "takeMajMinPatch: less than 3 → dup of raw" {
    const v = try takeMajMinPatch(testing.allocator, "7.5");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("7.5", v);
}

test "parseVersionTuple: classic" {
    const v = try parseVersionTuple(testing.allocator, "version_tuple = (7, 5, 3, vc_version)");
    try testing.expect(v != null);
    defer testing.allocator.free(v.?);
    try testing.expectEqualStrings("7.5.3", v.?);
}

test "parseVersionTuple: missing → null" {
    const v = try parseVersionTuple(testing.allocator, "no tuple here");
    try testing.expect(v == null);
}

test "parseVersionTuple: extra spaces tolerated" {
    const v = try parseVersionTuple(testing.allocator, "version_tuple = (  8 ,  0 , 1 , vc)");
    try testing.expect(v != null);
    defer testing.allocator.free(v.?);
    try testing.expectEqualStrings("8.0.1", v.?);
}

test "renderLauncher: NixOS steam-run wrap" {
    const out = try renderLauncher(testing.allocator, "MyGame", true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "exec steam-run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"MyGame.py\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "RENPY_PLATFORM=") != null);
}

test "renderLauncher: plain exec on non-NixOS" {
    const out = try renderLauncher(testing.allocator, "Foo", false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "steam-run") == null);
    try testing.expect(std.mem.indexOf(u8, out, "exec \"${PYTHON}\"") != null);
}

test "renderLauncher: bash header + cd to script dir" {
    const out = try renderLauncher(testing.allocator, "X", false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, out, "cd \"$(dirname") != null);
}
