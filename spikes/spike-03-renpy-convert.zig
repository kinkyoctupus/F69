// spike-03: Ren'Py Win→Linux convert. Throwaway PoC.
// Goal: validate the convert pipeline before sinking phase-5 effort
// into `convert/renpy.zig`.
//
// What this does:
//   1. Detect Ren'Py version from <game>/renpy/vc_version.py (preferred)
//      or <game>/renpy/__init__.py (fallback for older Ren'Py).
//   2. Locate matching SDK at ~/.cache/renpy-sdk/renpy-<v>-sdk/
//      (same convention as user's fix-linux-games.sh). If absent, print
//      the download URL and exit — actual download deferred to phase-5
//      real impl.
//   3. Copy SDK's lib/py3-linux-x86_64 + lib/python* into the target
//      install dir.
//   4. Generate <target>/<gamename>.sh launcher (Steam-Run-wrapped on
//      NixOS, plain exec elsewhere).
//
// Built against Zig 0.16's std.Io.
//
// Usage:
//   zig build spike-renpy-convert -- <game_src> <target_dir>

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        try Io.File.stdout().writeStreamingAll(io,
            \\spike-03-renpy-convert
            \\
            \\usage: spike-renpy-convert <game_src> <target_dir>
            \\
        );
        return;
    }

    const game_src = args[1];
    const target_dir = args[2];

    // 1. Detect Ren'Py version.
    const version = (try detectRenpyVersion(io, gpa, arena, game_src)) orelse {
        try printf(io, "[spike] could not detect Ren'Py version in {s}\n", .{game_src});
        try printf(io,
            \\[spike] expected one of:
            \\  - {s}/renpy/vc_version.py with `version = u'X.Y.Z.BUILD'`
            \\  - {s}/renpy/__init__.py with `version_tuple = (X, Y, Z, ...)`
            \\
        , .{ game_src, game_src });
        return;
    };
    try printf(io, "[spike] detected Ren'Py: {s}\n", .{version});

    const major = majorOf(version);
    try printf(io, "[spike] major: {d}\n", .{major});

    // 2. Locate cached SDK.
    const home = init.minimal.environ.getAlloc(arena, "HOME") catch {
        try printf(io, "[spike] HOME not set\n", .{});
        return;
    };
    const sdk_dir = try std.fmt.allocPrint(arena, "{s}/.cache/renpy-sdk/renpy-{s}-sdk", .{ home, version });

    const sdk_present = blk: {
        Io.Dir.cwd().access(io, sdk_dir, .{}) catch |e| switch (e) {
            error.FileNotFound => break :blk false,
            else => return e,
        };
        break :blk true;
    };

    if (!sdk_present) {
        try printf(io, "[spike] SDK not cached at {s}\n", .{sdk_dir});
        try printf(io, "[spike] download URL: https://www.renpy.org/dl/{s}/renpy-{s}-sdk.tar.bz2\n", .{ version, version });
        try printf(io, "[spike] (real impl will fetch + extract; spike skips network for now)\n", .{});
        return;
    }
    try printf(io, "[spike] SDK: {s}\n", .{sdk_dir});

    // 3. Prepare target dir as a copy of game_src.
    try printf(io, "[spike] preparing target {s} (copy of {s}) ...\n", .{ target_dir, game_src });
    try copyTree(io, gpa, arena, game_src, target_dir);

    // 4. Copy Linux runtime libs from SDK.
    var n_copied: usize = 0;
    inline for ([_][]const u8{ "lib/py3-linux-x86_64", "lib/py2-linux-x86_64", "lib/linux-x86_64" }) |sub| {
        const sdk_sub = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sdk_dir, sub });
        const present = blk: {
            Io.Dir.cwd().access(io, sdk_sub, .{}) catch break :blk false;
            break :blk true;
        };
        if (present) {
            const dest_sub = try std.fmt.allocPrint(arena, "{s}/{s}", .{ target_dir, sub });
            try printf(io, "[spike]   copy {s} → {s}\n", .{ sub, dest_sub });
            try copyTree(io, gpa, arena, sdk_sub, dest_sub);
            n_copied += 1;
        }
    }

    // Copy the python interpreter dirs too (lib/python3.x etc.).
    var sdk_lib = try Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(arena, "{s}/lib", .{sdk_dir}), .{ .access_sub_paths = true, .iterate = true });
    defer sdk_lib.close(io);
    var lib_iter = sdk_lib.iterate();
    while (try lib_iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "python")) continue;
        const sdk_sub = try std.fmt.allocPrint(arena, "{s}/lib/{s}", .{ sdk_dir, entry.name });
        const dest_sub = try std.fmt.allocPrint(arena, "{s}/lib/{s}", .{ target_dir, entry.name });
        try printf(io, "[spike]   copy lib/{s} → {s}\n", .{ entry.name, dest_sub });
        try copyTree(io, gpa, arena, sdk_sub, dest_sub);
        n_copied += 1;
    }
    try printf(io, "[spike] copied {d} lib subdirs from SDK\n", .{n_copied});

    // 5. Pick a launcher name. Use the .py file (Ren'Py convention) or
    //    fall back to a basename derived from the .exe.
    const launcher_name = (try findLauncherName(io, gpa, arena, target_dir)) orelse "launcher";
    try printf(io, "[spike] launcher base: {s}\n", .{launcher_name});

    // 6. Detect distro to know whether to wrap in steam-run.
    const distro = try detectDistro(io, gpa);
    const wrap_steam_run = distro == .nixos;

    // 7. Generate <target>/<launcher_name>.sh.
    const sh_path = try std.fmt.allocPrint(arena, "{s}/{s}.sh", .{ target_dir, launcher_name });
    try writeLauncher(io, gpa, sh_path, launcher_name, wrap_steam_run);
    try chmodExec(io, sh_path);
    try printf(io, "[spike] wrote launcher: {s} (steam-run: {})\n", .{ sh_path, wrap_steam_run });

    try printf(io,
        "\n[spike] DONE. Run with: cd {s} && ./{s}.sh\n",
        .{ target_dir, launcher_name },
    );
}

// ============================================================
//  detection
// ============================================================

const Distro = enum { nixos, arch, debian, ubuntu, fedora, other };

fn detectDistro(io: Io, gpa: std.mem.Allocator) !Distro {
    const content = Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", gpa, .unlimited) catch return .other;
    defer gpa.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "ID=")) {
            const v = std.mem.trim(u8, line[3..], "\"' \t");
            if (std.mem.eql(u8, v, "nixos")) return .nixos;
            if (std.mem.eql(u8, v, "arch")) return .arch;
            if (std.mem.eql(u8, v, "debian")) return .debian;
            if (std.mem.eql(u8, v, "ubuntu")) return .ubuntu;
            if (std.mem.eql(u8, v, "fedora")) return .fedora;
            return .other;
        }
    }
    return .other;
}

/// Returns "X.Y.Z" or null. Tries vc_version.py first (Ren'Py 7.4+ has it),
/// then falls back to __init__.py's version_tuple.
fn detectRenpyVersion(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    game_src: []const u8,
) !?[]const u8 {
    // vc_version.py: `version = u'7.6.1.23060707'` → take "7.6.1"
    const vc_path = try std.fmt.allocPrint(arena, "{s}/renpy/vc_version.py", .{game_src});
    if (Io.Dir.cwd().readFileAlloc(io, vc_path, gpa, .unlimited)) |content| {
        defer gpa.free(content);
        if (parseVcVersion(content)) |raw| {
            // raw is e.g. "7.6.1.23060707"; take first 3 dot-sep parts.
            return try takeMajMinPatch(arena, raw);
        }
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    // __init__.py: `version_tuple = (7, 5, 3, vc_version)` → "7.5.3"
    const init_path = try std.fmt.allocPrint(arena, "{s}/renpy/__init__.py", .{game_src});
    if (Io.Dir.cwd().readFileAlloc(io, init_path, gpa, .unlimited)) |content| {
        defer gpa.free(content);
        if (parseVersionTuple(arena, content)) |v| return v;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    return null;
}

fn parseVcVersion(content: []const u8) ?[]const u8 {
    // Look for `version = u'...'` or `version = '...'`.
    const marker_a = "version = u'";
    const marker_b = "version = '";
    const start = std.mem.indexOf(u8, content, marker_a) orelse
        std.mem.indexOf(u8, content, marker_b) orelse return null;
    const value_start = if (std.mem.indexOf(u8, content, marker_a)) |_| start + marker_a.len else start + marker_b.len;
    const end = std.mem.indexOfScalarPos(u8, content, value_start, '\'') orelse return null;
    return content[value_start..end];
}

/// "7.6.1.23060707" → "7.6.1"
fn takeMajMinPatch(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |p| {
        if (n >= 3) break;
        parts[n] = p;
        n += 1;
    }
    if (n < 3) return raw; // already short
    return try std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ parts[0], parts[1], parts[2] });
}

/// Parses `version_tuple = (7, 5, 3, vc_version)` style. Returns "7.5.3".
fn parseVersionTuple(arena: std.mem.Allocator, content: []const u8) ?[]const u8 {
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
    return std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ nums[0], nums[1], nums[2] }) catch null;
}

fn majorOf(version: []const u8) u32 {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return 0;
    return std.fmt.parseInt(u32, version[0..dot], 10) catch 0;
}

// ============================================================
//  fs ops
// ============================================================

/// Recursively copy `src` → `dest`. Symlinks are followed (real impl
/// should preserve them — see findings doc).
fn copyTree(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    var src_dir = try Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true });
    defer src_dir.close(io);

    try Io.Dir.cwd().createDirPath(io, dest);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const dest_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, entry.path });
        switch (entry.kind) {
            .directory => try Io.Dir.cwd().createDirPath(io, dest_path),
            .file => {
                if (std.fs.path.dirname(dest_path)) |d| try Io.Dir.cwd().createDirPath(io, d);
                const src_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src, entry.path });
                const data = try Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .unlimited);
                defer gpa.free(data);
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = data });
            },
            else => {}, // skip symlinks/sockets/etc. — flagged for real impl
        }
    }
}

/// Pick a launcher base name. Strategy:
///   1. The first <name>.py at the game root wins (Ren'Py convention).
///   2. Otherwise, the first <name>.exe (without notification_helper / UnityCrashHandler).
fn findLauncherName(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, target_dir: []const u8) !?[]const u8 {
    _ = gpa;
    var dir = try Io.Dir.cwd().openDir(io, target_dir, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var fallback_exe: ?[]const u8 = null;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".py") and
            !std.mem.eql(u8, entry.name, "log.py") and
            !std.mem.eql(u8, entry.name, "__init__.py"))
        {
            const base = entry.name[0 .. entry.name.len - 3];
            return try arena.dupe(u8, base);
        }
        if (std.mem.endsWith(u8, entry.name, ".exe") and
            !std.mem.startsWith(u8, entry.name, "notification_helper") and
            !std.mem.startsWith(u8, entry.name, "UnityCrashHandler"))
        {
            fallback_exe = try arena.dupe(u8, entry.name[0 .. entry.name.len - 4]);
        }
    }
    return fallback_exe;
}

fn writeLauncher(io: Io, gpa: std.mem.Allocator, sh_path: []const u8, name: []const u8, wrap_steam_run: bool) !void {
    _ = gpa;
    var buf: [4096]u8 = undefined;
    const exec_prefix = if (wrap_steam_run) "exec steam-run " else "exec ";
    const content = try std.fmt.bufPrint(&buf,
        \\#!/usr/bin/env bash
        \\# auto-generated Ren'Py Linux launcher (f69 spike-03)
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
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = content });
}

fn chmodExec(io: Io, path: []const u8) !void {
    var f = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setPermissions(io, .executable_file);
}

// ============================================================
//  helpers
// ============================================================

fn printf(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
    try Io.File.stdout().writeStreamingAll(io, out);
}
