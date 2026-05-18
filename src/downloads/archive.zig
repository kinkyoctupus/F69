// Archive extraction.
//   .zip / .tar.gz       → Zig stdlib (pure Zig, no FFI)
//   .7z / .tar.bz2 /
//   .tar.xz / .rar       → libarchive via util_archive (statically
//                           linked through pkgs.libarchive-static)
//
// No more shellouts — `p7zip`, `unrar`, `bzip2`, `xz` CLI tools are
// not required at runtime. libarchive's static .a bundles the
// bz2 + xz + zlib decompression backends.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.archive);
const errs = @import("errors.zig");
const archive_lib = @import("util_archive");
const util_proc = @import("util_proc");

pub const Format = enum { zip, sevenz, tar_gz, tar_bz2, tar_xz, rar, unknown };

pub fn detectFormat(path: []const u8) Format {
    if (std.mem.endsWith(u8, path, ".zip")) return .zip;
    if (std.mem.endsWith(u8, path, ".7z")) return .sevenz;
    if (std.mem.endsWith(u8, path, ".tar.gz") or std.mem.endsWith(u8, path, ".tgz")) return .tar_gz;
    if (std.mem.endsWith(u8, path, ".tar.bz2")) return .tar_bz2;
    if (std.mem.endsWith(u8, path, ".tar.xz")) return .tar_xz;
    if (std.mem.endsWith(u8, path, ".rar")) return .rar;
    return .unknown;
}

pub const ExtractOpts = struct {
    /// Strip N leading path components from each archive entry. Only
    /// honored by the tar paths today; zip flattens via its own
    /// `ExtractOptions`.
    strip: u8 = 0,
};

/// Extract `archive_path` into `dest_dir`, creating `dest_dir` if
/// missing. Format inferred from extension. Stdlib handles .zip and
/// .tar.gz; everything else routes through libarchive.
pub fn extract(
    alloc: std.mem.Allocator,
    io: Io,
    archive_path: []const u8,
    dest_dir: []const u8,
    opts: ExtractOpts,
) errs.Error!void {
    const fmt = detectFormat(archive_path);

    std.Io.Dir.cwd().createDirPath(io, dest_dir) catch return errs.Error.ExtractionFailed;

    switch (fmt) {
        .zip => {
            var dest = std.Io.Dir.cwd().openDir(io, dest_dir, .{}) catch return errs.Error.ExtractionFailed;
            defer dest.close(io);
            extractZip(io, archive_path, dest) catch |e| {
                log.warn("zip extract failed for {s}: {s}", .{ archive_path, @errorName(e) });
                return errs.Error.ExtractionFailed;
            };
        },
        .tar_gz => {
            var dest = std.Io.Dir.cwd().openDir(io, dest_dir, .{}) catch return errs.Error.ExtractionFailed;
            defer dest.close(io);
            extractTarGz(alloc, io, archive_path, dest, opts.strip) catch |e| {
                log.warn("tar.gz extract failed for {s}: {s}", .{ archive_path, @errorName(e) });
                return errs.Error.ExtractionFailed;
            };
        },
        .sevenz, .tar_bz2, .tar_xz, .rar => {
            // libarchive opens the archive itself + writes to disk
            // via its own write-disk pipeline; no Zig std.Io.Dir
            // needed. Pass dest_dir as a slice; the binding does the
            // C-string conversion.
            archive_lib.extractFile(archive_path, dest_dir, .{ .strip = opts.strip }) catch |e| {
                log.warn("{s} extract failed for {s}: {s}", .{ @tagName(fmt), archive_path, @errorName(e) });
                return errs.Error.ExtractionFailed;
            };
        },
        .unknown => {
            log.warn("archive format unknown for {s} (no recognized extension)", .{archive_path});
            return errs.Error.ExtractionFailed;
        },
    }
    log.info("extracted {s} → {s}", .{ archive_path, dest_dir });
}

fn extractZip(io: Io, path: []const u8, dest: std.Io.Dir) !void {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &buf);
    try std.zip.extract(dest, &fr, .{ .allow_backslashes = true });
}

fn extractTarGz(
    alloc: std.mem.Allocator,
    io: Io,
    path: []const u8,
    dest: std.Io.Dir,
    strip: u8,
) !void {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rd_buf);

    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);

    var dec = std.compress.flate.Decompress.init(&fr.interface, .gzip, window);
    try std.tar.extract(io, dest, &dec.reader, .{ .strip_components = strip });
}

// ============================================================
//  tests — fixture archives in /tmp scratch dirs
// ============================================================

const testing = std.testing;

test "detectFormat: extensions" {
    try testing.expectEqual(Format.zip, detectFormat("game.zip"));
    try testing.expectEqual(Format.sevenz, detectFormat("game.7z"));
    try testing.expectEqual(Format.tar_gz, detectFormat("game.tar.gz"));
    try testing.expectEqual(Format.tar_gz, detectFormat("game.tgz"));
    try testing.expectEqual(Format.tar_bz2, detectFormat("game.tar.bz2"));
    try testing.expectEqual(Format.tar_xz, detectFormat("game.tar.xz"));
    try testing.expectEqual(Format.rar, detectFormat("game.rar"));
    try testing.expectEqual(Format.unknown, detectFormat("game"));
}

test "extract: missing file returns ExtractionFailed" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const dest = "/tmp/f69-test-archive-missing";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    // Bogus .7z path — libarchive fails to open it; we wrap the IO
    // error into ExtractionFailed at the dispatcher level.
    try testing.expectError(
        errs.Error.ExtractionFailed,
        extract(testing.allocator, io, "/nonexistent.7z", dest, .{}),
    );
}

test "extract: real .tar.gz round-trip" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-archive-targz";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    // Build a tiny tar.gz fixture by shelling out — pure-Zig tar.Writer
    // would be cleaner but adds ~50 lines just for the test.
    var src_dir_buf: [128]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_dir_buf, "{s}/src", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, src_dir);

    var hello_path_buf: [256]u8 = undefined;
    const hello_path = try std.fmt.bufPrint(&hello_path_buf, "{s}/hello.txt", .{src_dir});
    {
        var f = try std.Io.Dir.cwd().createFile(io, hello_path, .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("hi from archive test\n");
        try w.interface.flush();
    }

    var tar_path_buf: [256]u8 = undefined;
    const tar_path = try std.fmt.bufPrint(&tar_path_buf, "{s}/test.tar.gz", .{scratch});

    var tar_cmd_buf: [512]u8 = undefined;
    const tar_cmd = try std.fmt.bufPrint(&tar_cmd_buf, "tar czf {s} -C {s} hello.txt", .{ tar_path, src_dir });
    const result = util_proc.run(testing.allocator, io, &.{ "sh", "-c", tar_cmd }, .{
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(result.stdout);
    if (result.exit_code != 0) return error.SkipZigTest;

    var out_dir_buf: [128]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&out_dir_buf, "{s}/out", .{scratch});

    try extract(testing.allocator, io, tar_path, out_dir, .{});

    // Verify the extracted file matches.
    var out_file_buf: [256]u8 = undefined;
    const out_file = try std.fmt.bufPrint(&out_file_buf, "{s}/hello.txt", .{out_dir});
    const got = try std.Io.Dir.cwd().readFileAlloc(io, out_file, testing.allocator, .limited(1024));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hi from archive test\n", got);
}

test "extract: real .zip round-trip" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-archive-zip";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    var src_dir_buf: [128]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_dir_buf, "{s}/src", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, src_dir);

    var hello_path_buf: [256]u8 = undefined;
    const hello_path = try std.fmt.bufPrint(&hello_path_buf, "{s}/hello.txt", .{src_dir});
    {
        var f = try std.Io.Dir.cwd().createFile(io, hello_path, .{ .truncate = true });
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("hi from zip test\n");
        try w.interface.flush();
    }

    var zip_path_buf: [256]u8 = undefined;
    const zip_path = try std.fmt.bufPrint(&zip_path_buf, "{s}/test.zip", .{scratch});

    var zip_cmd_buf: [512]u8 = undefined;
    const zip_cmd = try std.fmt.bufPrint(&zip_cmd_buf, "cd {s} && zip -q {s} hello.txt", .{ src_dir, zip_path });
    const result = util_proc.run(testing.allocator, io, &.{ "sh", "-c", zip_cmd }, .{
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(result.stdout);
    if (result.exit_code != 0) return error.SkipZigTest;

    var out_dir_buf: [128]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&out_dir_buf, "{s}/out", .{scratch});

    try extract(testing.allocator, io, zip_path, out_dir, .{});

    var out_file_buf: [256]u8 = undefined;
    const out_file = try std.fmt.bufPrint(&out_file_buf, "{s}/hello.txt", .{out_dir});
    const got = try std.Io.Dir.cwd().readFileAlloc(io, out_file, testing.allocator, .limited(1024));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hi from zip test\n", got);
}
