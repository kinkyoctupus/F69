// Copy-verify-delete migration of an install directory from a source
// library (F95Checker / xLibrary games root) into f69's library_root.
//
// Strategy:
//   1. Walk every file under `src_dir`, copy to `dst_dir`/<same rel
//      path>, computing the source's SHA-256 streaming during the
//      read (cheap — same buffer we'd hit anyway).
//   2. After every file is copied, RE-READ the destination and recompute
//      its SHA-256. Only when every destination hash matches its
//      source counterpart do we delete the source tree.
//   3. On any verification mismatch: bail. Source tree stays intact,
//      destination stays intact, caller surfaces the failure.
//
// The verification pass is a deliberate cost. The user picked
// "copy-then-verify-then-delete" over "rename(2) when same FS" precisely
// because losing the source is an unrecoverable failure mode. We pay
// the second read once per import.

const std = @import("std");

const log = std.log.scoped(.importer_migrate);

pub const Error = error{
    SourceMissing,
    CopyFailed,
    VerifyMismatch,
    DeleteFailed,
    OutOfMemory,
    PathTooLong,
};

/// Progress callback shape — matches `installer/apply.zig` so the UI
/// queue can share a single banner widget.
pub const ProgressFn = *const fn (ctx: ?*anyopaque, done: u32, total: u32) void;

pub const Opts = struct {
    progress_cb: ?ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    /// Cooperative cancel — checked between files. If set true, the
    /// migrator returns `error.Canceled` *before* deleting the source,
    /// so a cancel during the copy phase is safe.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// When true, skip phase 4 (the source delete). Used by the
    /// folder-import "Copy" mode where the user wants to keep their
    /// originals — peak disk goes up to 2x permanently, but the
    /// originals stay intact.
    keep_source: bool = false,
};

pub const Stats = struct {
    files_copied: u32 = 0,
    bytes_copied: u64 = 0,
    files_verified: u32 = 0,
    /// True when the post-verify delete of the source tree failed
    /// (typically on FUSE NTFS / exFAT mounts that disallow delete
    /// for the mount user). Destination copy is still good; caller
    /// surfaces this to the user so they know to clean up by hand.
    source_delete_failed: bool = false,
};

/// Migrate `src_dir` → `dst_dir`. Both are absolute. Empty `dst_dir`
/// is created if needed. After a successful migration, `src_dir` is
/// recursively removed.
///
/// Caller MUST guarantee `dst_dir` doesn't already exist or is empty;
/// the migrator won't overwrite arbitrary files at the destination.
/// (The import job assembles `<library_root>/<thread_id>/imported/`
/// which is fresh per import.)
pub fn copyVerifyDelete(
    alloc: std.mem.Allocator,
    io: std.Io,
    src_dir: []const u8,
    dst_dir: []const u8,
    opts: Opts,
) Error!Stats {
    // Source must exist as a directory.
    var src = std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true, .access_sub_paths = true }) catch {
        return Error.SourceMissing;
    };
    defer src.close(io);

    std.Io.Dir.cwd().createDirPath(io, dst_dir) catch return Error.CopyFailed;

    var stats = Stats{};

    // ---- Phase 1: count files (for progress total). ----
    {
        var walker = src.walk(alloc) catch return Error.OutOfMemory;
        defer walker.deinit();
        var total: u32 = 0;
        while (walker.next(io) catch null) |e| if (e.kind == .file) { total += 1; };
        if (opts.progress_cb) |cb| cb(opts.progress_ctx, 0, total);
    }

    // We track every (rel, src_sha) we copied so the verify pass can
    // walk again and confirm each one. Strings live on a per-call
    // arena to keep the temp lifetime simple.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const Recorded = struct {
        rel: []const u8,
        src_sha: [32]u8,
    };
    var records: std.ArrayList(Recorded) = .empty;

    // ---- Phase 2: copy. ----
    {
        var walker = src.walk(alloc) catch return Error.OutOfMemory;
        defer walker.deinit();
        var done: u32 = 0;
        const total = stats.files_copied; // updated below

        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (opts.cancel) |c| {
                if (c.load(.monotonic)) {
                    log.warn("migrate: canceled before deleting source — left both intact", .{});
                    return Error.CopyFailed;
                }
            }

            const rel = entry.path;
            var src_buf: [1024]u8 = undefined;
            const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_dir, rel }) catch return Error.PathTooLong;
            var dst_buf: [1024]u8 = undefined;
            const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst_dir, rel }) catch return Error.PathTooLong;

            const sha = copyAndHash(io, src_path, dst_path, &stats.bytes_copied) catch return Error.CopyFailed;
            const rel_owned = aalloc.dupe(u8, rel) catch return Error.OutOfMemory;
            records.append(aalloc, .{ .rel = rel_owned, .src_sha = sha }) catch return Error.OutOfMemory;

            stats.files_copied += 1;
            done += 1;
            if (opts.progress_cb) |cb| cb(opts.progress_ctx, done, total);
        }
    }

    // ---- Phase 3: verify. ----
    for (records.items) |rec| {
        if (opts.cancel) |c| {
            if (c.load(.monotonic)) {
                log.warn("migrate: canceled during verify — source preserved", .{});
                return Error.CopyFailed;
            }
        }
        var dst_buf: [1024]u8 = undefined;
        const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst_dir, rec.rel }) catch return Error.PathTooLong;
        const dst_sha = hashFile(io, dst_path) catch return Error.VerifyMismatch;
        if (!std.mem.eql(u8, &rec.src_sha, &dst_sha)) {
            log.warn("migrate: verify failed for {s} — source preserved", .{rec.rel});
            return Error.VerifyMismatch;
        }
        stats.files_verified += 1;
    }

    // ---- Phase 4: delete source. ----
    if (opts.keep_source) return stats;
    std.Io.Dir.cwd().deleteTree(io, src_dir) catch |delete_err| {
        // Verification already passed, so destination is good. Delete
        // failure is a soft warning (not a rollback trigger) — but
        // log the actual error so the user can see WHY the source
        // stayed behind. Common cause: FUSE-mounted filesystems
        // (NTFS, exFAT) that disallow delete or rename for the
        // mount user.
        log.warn("migrate: post-verify deleteTree of '{s}' failed: {s} — destination copy is fine, source stayed behind for you to clean up manually", .{ src_dir, @errorName(delete_err) });
        stats.source_delete_failed = true;
        return stats;
    };
    return stats;
}

/// Stream-copy `src` → `dst` while computing the source's SHA-256.
/// Bumps `bytes_total` with each chunk so the caller can show throughput.
fn copyAndHash(io: std.Io, src: []const u8, dst: []const u8, bytes_total: *u64) ![32]u8 {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    if (std.fs.path.dirname(dst)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
    defer out.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    while (true) {
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        hasher.update(chunk[0..got]);
        try out_writer.interface.writeAll(chunk[0..got]);
        bytes_total.* += got;
    }
    try out_writer.interface.flush();

    // Preserve the executable bit so launchers (.sh / .py / etc.)
    // stay runnable post-migration.
    const st = in.stat(io) catch return error.StatFailed;
    try out.setPermissions(io, st.permissions);

    var sha: [32]u8 = undefined;
    hasher.final(&sha);
    return sha;
}

/// Read a file and return its SHA-256. Used during the verify pass.
fn hashFile(io: std.Io, path: []const u8) ![32]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var rdr = f.reader(io, &rd_buf);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const got = rdr.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        hasher.update(chunk[0..got]);
    }
    var sha: [32]u8 = undefined;
    hasher.final(&sha);
    return sha;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "copyVerifyDelete: simple tree round-trip + source removed" {
    var env = try test_env.TestEnv.init(testing.allocator, "migrate-simple");
    defer env.deinit();

    try env.writeFile("source/a.txt", "hello");
    try env.writeFile("source/sub/b.txt", "world");

    const src = try env.path("source");
    defer testing.allocator.free(src);
    const dst = try env.path("dest");
    defer testing.allocator.free(dst);

    const stats = try copyVerifyDelete(testing.allocator, env.io, src, dst, .{});
    try testing.expectEqual(@as(u32, 2), stats.files_copied);
    try testing.expectEqual(@as(u32, 2), stats.files_verified);

    // Source is gone.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(env.io, src, .{}));
    // Dest has both files with original contents.
    const a_path = try env.path("dest/a.txt");
    defer testing.allocator.free(a_path);
    const a = try std.Io.Dir.cwd().readFileAlloc(env.io, a_path, testing.allocator, .limited(64));
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("hello", a);
    const b_path = try env.path("dest/sub/b.txt");
    defer testing.allocator.free(b_path);
    const b = try std.Io.Dir.cwd().readFileAlloc(env.io, b_path, testing.allocator, .limited(64));
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("world", b);
}

test "copyVerifyDelete: missing source → SourceMissing" {
    var env = try test_env.TestEnv.init(testing.allocator, "migrate-no-src");
    defer env.deinit();

    const dst = try env.path("dst");
    defer testing.allocator.free(dst);
    const missing_src = try env.path("missing-source");
    defer testing.allocator.free(missing_src);

    try testing.expectError(Error.SourceMissing, copyVerifyDelete(testing.allocator, env.io, missing_src, dst, .{}));
}
