// SDK cache abstraction. Engines look up their pre-fetched archives
// under `<cache>/f69/convert/sdks/<engine>-<version>/`. On miss the
// cache fetches from the engine's public mirror (renpy.org / dl.nwjs.io
// / nwjs-ffmpeg-prebuilt) and extracts in place.
//
// Layout:
//   <cache>/f69/convert/sdks/renpy-7.5.3/   ← extracted renpy-7.5.3-sdk.tar.gz
//   <cache>/f69/convert/sdks/nwjs-0.83.0/   ← extracted nwjs-v0.83.0-linux-x64.tar.gz
//
// `renpy-` / `nwjs-` prefixes keep the directory walkable in a single
// flat namespace — easier to inspect than per-engine subdirs.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.sdk_cache);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const util_http = @import("util_http");

/// Cap on a single SDK download. Ren'Py SDKs run ~95 MiB compressed
/// (~250 MiB uncompressed); nwjs ~50 MiB compressed. 1 GiB is the
/// safety net against pulling a wrong URL that returns something huge.
pub const MAX_SDK_BYTES: usize = 1024 * 1024 * 1024;

pub const Cache = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Allocator-owned `<cache>/f69/convert/sdks` path.
    sdks_dir: []u8,

    /// Initialize with the cache *root* (`<cache>/f69`); we append
    /// `/convert/sdks` ourselves. Creates the dir.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, cache_root: []const u8) errs.Error!Cache {
        const sdks_dir = std.fmt.allocPrint(alloc, "{s}/convert/sdks", .{cache_root}) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(sdks_dir);
        std.Io.Dir.cwd().createDirPath(io, sdks_dir) catch {};
        return .{ .alloc = alloc, .io = io, .sdks_dir = sdks_dir };
    }

    pub fn deinit(self: *Cache) void {
        self.alloc.free(self.sdks_dir);
        self.* = undefined;
    }

    /// Resolve a `<engine>-<version>` SDK directory. Returns the
    /// allocator-owned absolute path if the dir exists, `SdkNotCached`
    /// otherwise. Caller frees on success.
    ///
    /// `engine_tag` is the URL-friendly tag we use as the SDK dir prefix:
    /// "renpy" / "nwjs" / etc. Distinct from `dom.Engine` since one
    /// engine (RPGM) uses nwjs as its SDK.
    pub fn locate(self: *Cache, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}-{s}", .{ self.sdks_dir, engine_tag, version }) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return errs.Error.SdkNotCached;
        return path;
    }

    /// Build the path an SDK *would* land at when fetched. Allocator-
    /// owned. Used by error messages + as the target for `fetch`.
    pub fn expectedPath(self: *Cache, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/{s}-{s}", .{ self.sdks_dir, engine_tag, version }) catch errs.Error.OutOfMemory;
    }

    /// Download + extract the `<engine_tag>-<version>` SDK from its
    /// public mirror. URL resolved via `sdkUrl()`. Decompresses gzip
    /// in-process (no shell-out), extracts the tar stream into
    /// `<sdks_dir>/<engine_tag>-<version>/`.
    ///
    /// Caller frees the returned absolute path on success.
    ///
    /// Idempotent: if the SDK is already cached, returns its path
    /// without re-fetching.
    pub fn fetch(self: *Cache, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
        if (self.locate(engine_tag, version)) |existing| {
            return existing;
        } else |e| switch (e) {
            errs.Error.SdkNotCached => {},
            else => return e,
        }

        const url = try sdkUrl(self.alloc, engine_tag, version);
        defer self.alloc.free(url);

        const dest_dir = try self.expectedPath(engine_tag, version);
        errdefer self.alloc.free(dest_dir);

        log.info("fetching {s}-{s} from {s}", .{ engine_tag, version, url });

        // 1. Download the .tar.gz body into memory. Large but bounded
        // by MAX_SDK_BYTES; nwjs/renpy SDKs fit comfortably.
        const extra_headers = [_]util_http.Header{
            .{ .name = "accept", .value = "application/gzip, application/octet-stream, */*" },
        };

        const resp = util_http.fetch(self.alloc, self.io, url, .{
            .extra_headers = &extra_headers,
            .max_response_bytes = MAX_SDK_BYTES,
        }) catch |e| {
            log.warn("SDK fetch network error: {s}", .{@errorName(e)});
            self.alloc.free(dest_dir);
            return errs.Error.NetworkError;
        };
        defer self.alloc.free(resp.body);

        if (resp.status != 200) {
            log.warn("SDK fetch status {d} for {s}", .{ resp.status, url });
            self.alloc.free(dest_dir);
            return switch (resp.status) {
                404 => errs.Error.NotFound,
                else => errs.Error.NetworkError,
            };
        }

        const compressed = resp.body;
        log.info("SDK download done: {d} bytes compressed", .{compressed.len});

        // 2. Decompress (gzip) + extract tar into dest_dir.
        std.Io.Dir.cwd().createDirPath(self.io, dest_dir) catch {
            self.alloc.free(dest_dir);
            return errs.Error.SdkLayoutInvalid;
        };
        var dest = std.Io.Dir.cwd().openDir(self.io, dest_dir, .{}) catch {
            self.alloc.free(dest_dir);
            return errs.Error.SdkLayoutInvalid;
        };
        defer dest.close(self.io);

        const arch_fmt = sdkArchiveFormat(engine_tag);
        const extract_result = switch (arch_fmt) {
            .tar_gz => extractTarGz(self.alloc, self.io, compressed, dest, sdkStripComponents(engine_tag)),
            .zip => extractZipBuffered(self.alloc, self.io, compressed, dest_dir),
        };
        extract_result catch |e| {
            log.warn("SDK extract failed: {s}", .{@errorName(e)});
            std.Io.Dir.cwd().deleteTree(self.io, dest_dir) catch {};
            self.alloc.free(dest_dir);
            return errs.Error.SdkLayoutInvalid;
        };

        log.info("SDK installed at {s}", .{dest_dir});
        return dest_dir;
    }
};

/// Pure. Build the canonical download URL for an `(engine_tag, version)`
/// pair. Allocator-owned slice.
///
/// Patterns:
///   renpy       → https://www.renpy.org/dl/<v>/renpy-<v>-sdk.tar.gz
///   nwjs        → https://dl.nwjs.io/v<v>/nwjs-v<v>-linux-x64.tar.gz
///   nwjs-ffmpeg → https://github.com/nwjs-ffmpeg-prebuilt/
///                 nwjs-ffmpeg-prebuilt/releases/download/<v>/<v>-linux-x64.zip
///
/// New engine tags get added here; returns `UnknownEngine` otherwise.
pub fn sdkUrl(alloc: std.mem.Allocator, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
    if (std.mem.eql(u8, engine_tag, "renpy")) {
        return std.fmt.allocPrint(alloc, "https://www.renpy.org/dl/{s}/renpy-{s}-sdk.tar.gz", .{ version, version }) catch errs.Error.OutOfMemory;
    }
    if (std.mem.eql(u8, engine_tag, "nwjs")) {
        return std.fmt.allocPrint(alloc, "https://dl.nwjs.io/v{s}/nwjs-v{s}-linux-x64.tar.gz", .{ version, version }) catch errs.Error.OutOfMemory;
    }
    if (std.mem.eql(u8, engine_tag, "nwjs-ffmpeg")) {
        return std.fmt.allocPrint(alloc, "https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/{s}/{s}-linux-x64.zip", .{ version, version }) catch errs.Error.OutOfMemory;
    }
    return errs.Error.UnknownEngine;
}

/// Pure. The official tarballs nest everything under a top-level
/// `renpy-<v>-sdk/` or `nwjs-v<v>-linux-x64/` directory. We strip
/// that level so files land directly in our `<tag>-<version>/` dir.
/// nwjs-ffmpeg ships a flat zip — no strip.
pub fn sdkStripComponents(engine_tag: []const u8) u32 {
    if (std.mem.eql(u8, engine_tag, "renpy")) return 1;
    if (std.mem.eql(u8, engine_tag, "nwjs")) return 1;
    return 0;
}

/// Pure. Archive format used for the canonical URL of each engine tag.
pub fn sdkArchiveFormat(engine_tag: []const u8) ArchiveFormat {
    if (std.mem.eql(u8, engine_tag, "renpy")) return .tar_gz;
    if (std.mem.eql(u8, engine_tag, "nwjs")) return .tar_gz;
    if (std.mem.eql(u8, engine_tag, "nwjs-ffmpeg")) return .zip;
    return .tar_gz;
}

pub const ArchiveFormat = enum { tar_gz, zip };

/// std.zip needs a `*File.Reader` because the central directory lives
/// at the end of the archive — we can't stream-decode like tar. Buffer
/// the body to a tmp file in `dest_dir`, extract, then delete the tmp.
fn extractZipBuffered(
    alloc: std.mem.Allocator,
    io: Io,
    body: []const u8,
    dest_dir: []const u8,
) !void {
    _ = alloc;
    var tmp_buf: [1024]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/.fetch.tmp.zip", .{dest_dir});

    // Write body to tmp file.
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer f.close(io);
        var wr_buf: [64 * 1024]u8 = undefined;
        var fw = f.writer(io, &wr_buf);
        try fw.interface.writeAll(body);
        try fw.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Open tmp + extract.
    var in = try std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only });
    defer in.close(io);
    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = in.reader(io, &rd_buf);

    var dest = try std.Io.Dir.cwd().openDir(io, dest_dir, .{});
    defer dest.close(io);
    try std.zip.extract(dest, &fr, .{ .allow_backslashes = true });
}

fn extractTarGz(
    alloc: std.mem.Allocator,
    io: Io,
    gzipped: []const u8,
    dest: std.Io.Dir,
    strip_components: u32,
) !void {
    // Decompress wraps a fixed-slice Reader over the in-memory body.
    var src_reader = Io.Reader.fixed(gzipped);

    // flate.Decompress needs `max_window_len` of buffer (or 0 for
    // direct-mode); we allocate to keep stack flat.
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);

    var dec = std.compress.flate.Decompress.init(&src_reader, .gzip, window);
    // `dec.reader` is the *Io.Reader the tar walker reads from.
    try std.tar.extract(io, dest, &dec.reader, .{ .strip_components = strip_components });
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "Cache.locate: hit" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-hit");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    // Pre-stage an SDK dir.
    try env.mkdirP("convert/sdks/renpy-7.5.3");

    const found = try cache.locate("renpy", "7.5.3");
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "/convert/sdks/renpy-7.5.3"));
}

test "Cache.locate: miss returns SdkNotCached" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-miss");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    try testing.expectError(errs.Error.SdkNotCached, cache.locate("renpy", "9.9.9"));
}

test "Cache.expectedPath: format" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-expected");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    const ep = try cache.expectedPath("nwjs", "0.83.0");
    defer testing.allocator.free(ep);
    try testing.expect(std.mem.endsWith(u8, ep, "/convert/sdks/nwjs-0.83.0"));
}

test "sdkUrl: renpy pattern" {
    const u = try sdkUrl(testing.allocator, "renpy", "7.5.3");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://www.renpy.org/dl/7.5.3/renpy-7.5.3-sdk.tar.gz", u);
}

test "sdkUrl: nwjs pattern" {
    const u = try sdkUrl(testing.allocator, "nwjs", "0.83.0");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://dl.nwjs.io/v0.83.0/nwjs-v0.83.0-linux-x64.tar.gz", u);
}

test "sdkUrl: nwjs-ffmpeg pattern" {
    const u = try sdkUrl(testing.allocator, "nwjs-ffmpeg", "0.83.0");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/0.83.0/0.83.0-linux-x64.zip", u);
}

test "sdkArchiveFormat: per-tag" {
    try testing.expectEqual(ArchiveFormat.tar_gz, sdkArchiveFormat("renpy"));
    try testing.expectEqual(ArchiveFormat.tar_gz, sdkArchiveFormat("nwjs"));
    try testing.expectEqual(ArchiveFormat.zip, sdkArchiveFormat("nwjs-ffmpeg"));
}

test "sdkUrl: unknown engine_tag → UnknownEngine" {
    try testing.expectError(errs.Error.UnknownEngine, sdkUrl(testing.allocator, "weird", "1.0"));
}

test "sdkStripComponents: known tags" {
    try testing.expectEqual(@as(u32, 1), sdkStripComponents("renpy"));
    try testing.expectEqual(@as(u32, 1), sdkStripComponents("nwjs"));
    try testing.expectEqual(@as(u32, 0), sdkStripComponents("unknown"));
}

test "Cache.fetch: idempotent — second call returns cached path without network" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-fetch-idem");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    // Pre-stage the dir so fetch finds it via locate() and skips
    // network entirely.
    try env.mkdirP("convert/sdks/renpy-7.5.3");

    const got = try cache.fetch("renpy", "7.5.3");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.endsWith(u8, got, "/convert/sdks/renpy-7.5.3"));
}
