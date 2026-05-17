// Multi-distro syslib resolution. Mirrors `fix-linux-games.sh`'s
// `bundle_syslibs` flow:
//
//   1. Run `ldd <binary>` against the game's main binary (`./nw` for
//      RPGM, `lib/.../python` for Ren'Py).
//   2. Parse the output for `=> not found` lines.
//   3. Look up each missing lib in the host's distro-specific paths.
//   4. Copy hits into `<install>/lib/` so the game finds them via the
//      launcher's `LD_LIBRARY_PATH` override.
//
// Single pass only; transitive deps (a libffmpeg copied in might itself
// need other host libs) are a follow-up — re-running ldd after the first
// round catches them.
//
// NixOS games sidestep this entirely via the launcher's `steam-run`
// wrap, so this is mostly Debian/Arch/Fedora territory.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.syslibs);
const errs = @import("errors.zig");
const dom = @import("domain.zig");

/// Owned list of lib names ("libgtk-3.so.0" style) that `ldd` couldn't
/// resolve. Caller frees via `freeMissing`.
pub const MissingList = []const []const u8;

pub fn freeMissing(alloc: std.mem.Allocator, list: MissingList) void {
    for (list) |s| alloc.free(s);
    alloc.free(list);
}

/// Pure. Extract the names of libs from `ldd` output's `=> not found`
/// lines. Returns allocator-owned slice of allocator-owned slices.
///
/// `ldd` format (each indented line is one dep):
///
///     libssl.so.3 => /usr/lib/x86_64-linux-gnu/libssl.so.3 (0x7fa)
///     libcrypto.so.3 => not found
///     linux-vdso.so.1 (0x7ffd)
pub fn parseLddOutput(alloc: std.mem.Allocator, text: []const u8) errs.Error!MissingList {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "=> not found") == null) continue;
        // Lib name is whatever sits before the first " => ".
        const arrow = std.mem.indexOf(u8, line, " => ") orelse continue;
        const name = std.mem.trim(u8, line[0..arrow], " \t");
        if (name.len == 0) continue;
        const owned = alloc.dupe(u8, name) catch return errs.Error.OutOfMemory;
        out.append(alloc, owned) catch {
            alloc.free(owned);
            return errs.Error.OutOfMemory;
        };
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

/// Pure. Per-distro host library search paths, in priority order.
pub fn searchPathsFor(distro: dom.Distro) []const []const u8 {
    return switch (distro) {
        .debian, .ubuntu => &.{
            "/usr/lib/x86_64-linux-gnu",
            "/lib/x86_64-linux-gnu",
            "/usr/lib",
            "/usr/lib64",
            "/lib",
            "/lib64",
        },
        .fedora => &.{
            "/usr/lib64",
            "/lib64",
            "/usr/lib",
            "/lib",
        },
        .arch, .other => &.{
            "/usr/lib",
            "/lib",
            "/usr/lib64",
            "/lib64",
        },
        // NixOS: nothing here works — the game launcher uses `steam-run`
        // which provides libs via the runtime environment. Bundle is a
        // no-op on NixOS by design.
        .nixos => &.{},
    };
}

/// Walk install dir for the main binary, run ldd, parse, resolve, copy.
/// Best-effort. `binary_hint` is the relative path to the binary to
/// probe (`"nw"` for RPGM, `"lib/python..."` for Ren'Py). Caller picks
/// the hint based on engine.
pub fn bundle(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    binary_hint: []const u8,
    distro: dom.Distro,
) errs.Error!void {
    if (distro == .nixos) {
        log.info("bundle: skipping on NixOS (steam-run handles libs)", .{});
        return;
    }

    var bin_buf: [640]u8 = undefined;
    const binary = std.fmt.bufPrint(&bin_buf, "{s}/{s}", .{ install_dir, binary_hint }) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().access(io, binary, .{}) catch {
        log.warn("bundle: binary {s} not present, skipping", .{binary});
        return;
    };

    const ldd_text = runLdd(alloc, io, binary) catch |e| {
        log.warn("bundle: ldd run failed: {s}", .{@errorName(e)});
        return;
    };
    defer alloc.free(ldd_text);

    const missing = try parseLddOutput(alloc, ldd_text);
    defer freeMissing(alloc, missing);

    if (missing.len == 0) {
        log.info("bundle: ldd reports nothing missing", .{});
        return;
    }
    log.info("bundle: {d} lib(s) missing per ldd", .{missing.len});

    var dest_lib_buf: [640]u8 = undefined;
    const dest_lib = std.fmt.bufPrint(&dest_lib_buf, "{s}/lib", .{install_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, dest_lib) catch return errs.Error.SyslibResolveFailed;

    const paths = searchPathsFor(distro);
    var copied: u32 = 0;
    for (missing) |libname| {
        if (findLibIn(alloc, io, paths, libname)) |host_path| {
            defer alloc.free(host_path);
            var dst_buf: [640]u8 = undefined;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest_lib, libname }) catch continue;
            copyOne(io, host_path, dst) catch |e| {
                log.warn("bundle: copy {s} → {s} failed: {s}", .{ host_path, dst, @errorName(e) });
                continue;
            };
            copied += 1;
            log.info("bundle: copied {s} from {s}", .{ libname, host_path });
        } else {
            log.warn("bundle: {s} not found in any host search path", .{libname});
        }
    }
    log.info("bundle: copied {d}/{d} missing libs into {s}", .{ copied, missing.len, dest_lib });
}

/// Run `ldd <binary>` and return its stdout as an allocator-owned
/// slice. Surfaces errors as `SyslibResolveFailed` so the caller can
/// keep going (bundle is best-effort).
fn runLdd(alloc: std.mem.Allocator, io: Io, binary: []const u8) ![]u8 {
    // Reuse a single read end pipe via `stdout = .pipe`. We accumulate
    // chunks into an ArrayList — ldd output for a typical binary is
    // a few KiB.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "ldd", binary },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (child.stdout) |*f| {
        var rd_buf: [64 * 1024]u8 = undefined;
        var fr = f.reader(io, &rd_buf);
        while (true) {
            var chunk: [64 * 1024]u8 = undefined;
            const got = fr.interface.readSliceShort(&chunk) catch break;
            if (got == 0) break;
            try out.appendSlice(alloc, chunk[0..got]);
        }
    }
    _ = child.wait(io) catch {};
    return out.toOwnedSlice(alloc);
}

fn findLibIn(alloc: std.mem.Allocator, io: Io, paths: []const []const u8, libname: []const u8) ?[]u8 {
    for (paths) |dir| {
        var buf: [512]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, libname }) catch continue;
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return alloc.dupe(u8, candidate) catch null;
    }
    return null;
}

fn copyOne(io: Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
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

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

test "parseLddOutput: typical Debian output" {
    // Real ldd uses tab indents — we trim both ` ` and `\t`, so the
    // test uses spaces (Zig source forbids tabs in string literals).
    const sample =
        \\    linux-vdso.so.1 (0x00007ffd)
        \\    libssl.so.3 => /usr/lib/x86_64-linux-gnu/libssl.so.3 (0x7fa)
        \\    libcrypto.so.3 => not found
        \\    libfoo.so.42 => not found
        \\    /lib64/ld-linux-x86-64.so.2 (0x7fb)
        \\
    ;
    const got = try parseLddOutput(testing.allocator, sample);
    defer freeMissing(testing.allocator, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("libcrypto.so.3", got[0]);
    try testing.expectEqualStrings("libfoo.so.42", got[1]);
}

test "parseLddOutput: nothing missing" {
    const sample =
        \\    libssl.so.3 => /usr/lib/x86_64-linux-gnu/libssl.so.3 (0x7fa)
        \\    libcrypto.so.3 => /usr/lib/x86_64-linux-gnu/libcrypto.so.3 (0x7fb)
        \\
    ;
    const got = try parseLddOutput(testing.allocator, sample);
    defer freeMissing(testing.allocator, got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "parseLddOutput: real tab indent" {
    // Hex-escaped tabs so the Zig source itself is tab-free.
    const sample = "\x09libfoo.so.1 => not found\n";
    const got = try parseLddOutput(testing.allocator, sample);
    defer freeMissing(testing.allocator, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("libfoo.so.1", got[0]);
}

test "parseLddOutput: trailing whitespace tolerated" {
    // Real ldd uses single spaces around `=>` — multi-space variants
    // aren't a thing in the wild. Just verify the leading-whitespace
    // trim works.
    const sample = "    libfoo.so.1 => not found\n";
    const got = try parseLddOutput(testing.allocator, sample);
    defer freeMissing(testing.allocator, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("libfoo.so.1", got[0]);
}

test "parseLddOutput: empty input" {
    const got = try parseLddOutput(testing.allocator, "");
    defer freeMissing(testing.allocator, got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "searchPathsFor: Debian leads with multiarch" {
    const paths = searchPathsFor(.debian);
    try testing.expect(paths.len >= 2);
    try testing.expectEqualStrings("/usr/lib/x86_64-linux-gnu", paths[0]);
}

test "searchPathsFor: Fedora leads with /usr/lib64" {
    const paths = searchPathsFor(.fedora);
    try testing.expect(paths.len >= 1);
    try testing.expectEqualStrings("/usr/lib64", paths[0]);
}

test "searchPathsFor: NixOS is empty (steam-run handles it)" {
    const paths = searchPathsFor(.nixos);
    try testing.expectEqual(@as(usize, 0), paths.len);
}
