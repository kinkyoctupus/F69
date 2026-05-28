// Flat-copy mod apply + uninstall.
//
// Strategy:
//   1. Extract the mod archive to a `/tmp` staging dir.
//   2. Walk the staged tree. For each file `rel`:
//      - exists in install_dir → record `modified_file`
//      - doesn't exist         → record `added_file`
//      - copy staged file over the install slot
//   3. Flush the tracker.
//
// Uninstall walks the tracker's entries for `mod_id` in reverse:
//   added_file    → delete
//   modified_file → log one-line warning; leave as-is (no backup kept)
//   created_dir   → rmdir if empty
//
// Trade-off: peak disk during install = `archive_extracted_size`
// (staging) + `install_dir_size` (final). Staging gets deleted on
// success. Backups were removed in favor of keeping the install dir
// at exactly its on-disk footprint — quality F95 mods can be 15GB+.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = std.log.scoped(.installer_apply);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const downloads = @import("downloads");
const recipe = @import("recipe");
const util_proc = @import("util_proc");
const Tracker = @import("tracker.zig").Tracker;

pub const ApplyOpts = struct {
    /// Where to stage the archive contents before per-file dispatch.
    /// Defaults to `/tmp/f69-mod-staging-<random>` — distinct per call
    /// so concurrent installs (a future feature) don't race.
    staging_root: []const u8 = "/tmp",
    /// Per-mod backup policy. `.none` (default) keeps today's behavior:
    /// `modified_file` entries are unrestorable and uninstall warns.
    /// `.copy` mirrors the pre-existing content to
    /// `<install>/.f69-backups/<mod_id>/<rel>` before each overwrite,
    /// so uninstall can put the original back. User opt-in per install
    /// (default off because 15GB overlay mods would double on disk).
    backup_mode: dom.BackupMode = .none,
    /// Flush the tracker to disk every N recorded entries (in addition
    /// to the always-final flush). Lets the recovery path roll back
    /// partial installs after a crash. `0` = only flush at end (the
    /// historic behavior — pure tests want this so they don't pay
    /// rewrite cost for tiny fixtures).
    flush_every: u32 = 50,
    /// Optional progress hook called once per file just before the
    /// copy. Lets the UI banner show "142 / 980 files" without the
    /// worker reaching back through frame state. `total` reads 0 until
    /// the staged walker has counted everything, so callers should
    /// treat 0 as "still counting."
    progress_cb: ?*const fn (ctx: ?*anyopaque, done: u32, total: u32) void = null,
    progress_ctx: ?*anyopaque = null,
    /// Cancellation flag. When non-null and set true between files, the
    /// apply loop returns `errs.Error.Canceled` so the queue can roll
    /// back the partial install.
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// Extract `archive_path` into `install_dir`, recording every file
/// touched into `tracker`.
pub fn applyModArchive(
    alloc: std.mem.Allocator,
    io: Io,
    mod_id: []const u8,
    archive_path: []const u8,
    install_dir: []const u8,
    tracker: *Tracker,
    opts: ApplyOpts,
) errs.Error!void {
    // 1. Staging dir.
    var nonce: [16]u8 = undefined;
    io.randomSecure(&nonce) catch io.random(&nonce);
    var staging_buf: [256]u8 = undefined;
    const staging = std.fmt.bufPrint(&staging_buf, "{s}/f69-mod-staging-{x}", .{ opts.staging_root, std.fmt.bytesToHex(nonce, .lower) }) catch return errs.Error.FileWriteFailed;
    defer std.Io.Dir.cwd().deleteTree(io, staging) catch {};

    log.info("apply mod {s}: extract {s} → {s}", .{ mod_id, archive_path, staging });
    downloads.extract(alloc, io, archive_path, staging, .{}) catch return errs.Error.FileWriteFailed;

    // 2. Walk staged tree + dispatch.
    var staged_dir = std.Io.Dir.cwd().openDir(io, staging, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.FileWriteFailed;
    defer staged_dir.close(io);
    var walker = staged_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    var added: u32 = 0;
    var modified: u32 = 0;
    var done: u32 = 0;
    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer deinitDirSet(alloc, &seen_dirs);
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        const rel = entry.path; // relative to `staging`
        var src_buf: [1024]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ staging, rel }) catch continue;
        var dst_buf: [1024]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ install_dir, rel }) catch continue;

        const target_exists = (std.Io.Dir.cwd().access(io, dst, .{}) catch null) != null;

        // Record any not-yet-existing parent dirs FIRST, so uninstall
        // (reverse walk) deletes files before sweeping their dirs.
        try recordCreatedDirs(alloc, io, install_dir, mod_id, rel, tracker, &seen_dirs);

        if (target_exists) {
            try backupOriginal(alloc, io, opts.backup_mode, install_dir, mod_id, rel);
            tracker.record(.{
                .mod_id = mod_id,
                .path = rel,
                .kind = .modified_file,
                .backup_mode = opts.backup_mode,
            }) catch return errs.Error.OutOfMemory;
            modified += 1;
        } else {
            tracker.record(.{
                .mod_id = mod_id,
                .path = rel,
                .kind = .added_file,
            }) catch return errs.Error.OutOfMemory;
            added += 1;
        }

        copyFile(io, src, dst) catch return errs.Error.FileWriteFailed;
        try afterFile(tracker, opts, &done, 0);
    }

    try tracker.flush();
    log.info("apply mod {s}: done — {d} added, {d} modified", .{ mod_id, added, modified });
}

/// Recipe-driven install. Walks `install_steps` in order, dispatching
/// each variant against `install_dir`. Empty list → falls through to
/// `applyModArchive` (legacy flat extract).
///
/// `chmod_x` is a no-op on Windows so recipes stay platform-agnostic.
/// `copy/move/delete/chmod_x` paths are joined safely under
/// `install_dir`; `..` and absolute paths are rejected at runtime
/// (validator should catch them earlier, but defense in depth).
pub fn applyModRecipe(
    alloc: std.mem.Allocator,
    io: Io,
    mod_id: []const u8,
    archive_path: []const u8,
    install_dir: []const u8,
    install_steps: []const recipe.InstallStep,
    tracker: *Tracker,
    opts: ApplyOpts,
) errs.Error!void {
    if (install_steps.len == 0) {
        return applyModArchive(alloc, io, mod_id, archive_path, install_dir, tracker, opts);
    }

    // Lazy-allocated main-archive staging. Only used by `extract_inner`
    // (and any future step that wants a side dir for the main payload).
    var nonce: [16]u8 = undefined;
    io.randomSecure(&nonce) catch io.random(&nonce);
    var staging_buf: [256]u8 = undefined;
    const staging = std.fmt.bufPrint(&staging_buf, "{s}/f69-mod-staging-{x}", .{ opts.staging_root, std.fmt.bytesToHex(nonce, .lower) }) catch return errs.Error.FileWriteFailed;
    defer std.Io.Dir.cwd().deleteTree(io, staging) catch {};

    var staged_main = false;

    log.info("apply mod {s}: {d} install step(s)", .{ mod_id, install_steps.len });

    for (install_steps) |step| {
        switch (step) {
            .extract => |x| {
                log.info("apply mod {s}: extract to='{s}' strip={d}", .{ mod_id, x.to, x.strip });
                try extractAndOverlay(alloc, io, mod_id, archive_path, install_dir, x.to, x.strip, tracker, opts);
            },
            .extract_inner => |x| {
                log.info("apply mod {s}: extract_inner archive='{s}' to='{s}' strip={d}", .{ mod_id, x.archive, x.to, x.strip });
                if (!staged_main) {
                    std.Io.Dir.cwd().createDirPath(io, staging) catch return errs.Error.FileWriteFailed;
                    downloads.extract(alloc, io, archive_path, staging, .{ .strip = 0 }) catch return errs.Error.FileWriteFailed;
                    staged_main = true;
                }
                const inner = std.fmt.allocPrint(alloc, "{s}/{s}", .{ staging, x.archive }) catch return errs.Error.OutOfMemory;
                defer alloc.free(inner);
                if ((std.Io.Dir.cwd().access(io, inner, .{}) catch null) == null) {
                    log.warn("extract_inner: {s} not found in staging", .{x.archive});
                    return errs.Error.FileWriteFailed;
                }
                try extractAndOverlay(alloc, io, mod_id, inner, install_dir, x.to, x.strip, tracker, opts);
            },
            .copy => |x| try doCopy(alloc, io, mod_id, install_dir, x.src, x.dest, tracker, opts),
            .move => |x| try doMove(alloc, io, mod_id, install_dir, x.src, x.dest, tracker, opts),
            .delete => |x| try doDelete(alloc, io, install_dir, x.path),
            .chmod_x => |x| {
                if (builtin.target.os.tag == .windows) continue;
                for (x.paths) |p| try doChmodX(alloc, io, install_dir, p);
            },
        }
        // Step boundary: honour cancel between steps even if the step
        // itself was a no-op-by-cancel-internal.
        if (opts.cancel) |c| if (c.load(.monotonic)) return errs.Error.Canceled;
    }

    try tracker.flush();
    log.info("apply mod {s}: recipe complete", .{mod_id});
}

/// Extract `archive_path` into a private staging subdir, then per-file
/// walk + overlay into `install_dir/sub_to`. Mirrors the flat-copy
/// strategy used by `applyModArchive` but parameterized for a target
/// subpath. Tracker records each touched file.
fn extractAndOverlay(
    alloc: std.mem.Allocator,
    io: Io,
    mod_id: []const u8,
    archive_path: []const u8,
    install_dir: []const u8,
    sub_to: []const u8,
    strip: u8,
    tracker: *Tracker,
    opts: ApplyOpts,
) errs.Error!void {
    if (!isSafeRel(sub_to)) return errs.Error.UnsafePath;

    var nonce: [16]u8 = undefined;
    io.randomSecure(&nonce) catch io.random(&nonce);
    var sub_buf: [256]u8 = undefined;
    const sub_staging = std.fmt.bufPrint(&sub_buf, "{s}/f69-mod-substage-{x}", .{ opts.staging_root, std.fmt.bytesToHex(nonce, .lower) }) catch return errs.Error.FileWriteFailed;
    defer std.Io.Dir.cwd().deleteTree(io, sub_staging) catch {};

    std.Io.Dir.cwd().createDirPath(io, sub_staging) catch return errs.Error.FileWriteFailed;
    downloads.extract(alloc, io, archive_path, sub_staging, .{ .strip = strip }) catch return errs.Error.FileWriteFailed;

    const dest_root = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, sub_to }) catch return errs.Error.OutOfMemory;
    defer alloc.free(dest_root);
    std.Io.Dir.cwd().createDirPath(io, dest_root) catch return errs.Error.FileWriteFailed;

    var staged_dir = std.Io.Dir.cwd().openDir(io, sub_staging, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.FileWriteFailed;
    defer staged_dir.close(io);
    var walker = staged_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    var done: u32 = 0;
    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer deinitDirSet(alloc, &seen_dirs);
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const rel = entry.path;
        var src_buf: [1024]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ sub_staging, rel }) catch continue;
        var dst_buf: [1024]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest_root, rel }) catch continue;

        // Tracker path is relative to install_dir for uninstall.
        var rel_buf: [1024]u8 = undefined;
        const tracker_rel = if (sub_to.len == 0 or std.mem.eql(u8, sub_to, "."))
            rel
        else
            std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ sub_to, rel }) catch rel;

        try recordCreatedDirs(alloc, io, install_dir, mod_id, tracker_rel, tracker, &seen_dirs);

        const exists = (std.Io.Dir.cwd().access(io, dst, .{}) catch null) != null;
        if (exists) try backupOriginal(alloc, io, opts.backup_mode, install_dir, mod_id, tracker_rel);
        tracker.record(.{
            .mod_id = mod_id,
            .path = tracker_rel,
            .kind = if (exists) .modified_file else .added_file,
            .backup_mode = if (exists) opts.backup_mode else .none,
        }) catch return errs.Error.OutOfMemory;

        copyFile(io, src, dst) catch return errs.Error.FileWriteFailed;
        try afterFile(tracker, opts, &done, 0);
    }
}

fn doCopy(
    alloc: std.mem.Allocator,
    io: Io,
    mod_id: []const u8,
    install_dir: []const u8,
    src_rel: []const u8,
    dst_rel: []const u8,
    tracker: *Tracker,
    opts: ApplyOpts,
) errs.Error!void {
    if (!isSafeRel(src_rel) or !isSafeRel(dst_rel)) return errs.Error.UnsafePath;

    const src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, src_rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(src);
    const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, dst_rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(dst);

    // Directory source → recursive merge so the Ren'Py "drop-in mod"
    // pattern works: extract the wrapper to staging, then `copy
    // staging/game → game` overlays the mod's game/ onto the install
    // root's game/, overwriting file-by-file. Plain single-file copy
    // (the original behaviour) stays the fallback for non-dir src.
    if (isDirectory(io, src)) {
        std.Io.Dir.cwd().createDirPath(io, dst) catch return errs.Error.FileWriteFailed;
        try copyTree(alloc, io, mod_id, src, dst, dst_rel, tracker, install_dir, opts);
        return;
    }

    if (std.fs.path.dirname(dst)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return errs.Error.FileWriteFailed;

    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer deinitDirSet(alloc, &seen_dirs);
    try recordCreatedDirs(alloc, io, install_dir, mod_id, dst_rel, tracker, &seen_dirs);

    const exists = (std.Io.Dir.cwd().access(io, dst, .{}) catch null) != null;
    if (exists) try backupOriginal(alloc, io, opts.backup_mode, install_dir, mod_id, dst_rel);
    copyFile(io, src, dst) catch return errs.Error.FileWriteFailed;

    tracker.record(.{
        .mod_id = mod_id,
        .path = dst_rel,
        .kind = if (exists) .modified_file else .added_file,
        .backup_mode = if (exists) opts.backup_mode else .none,
    }) catch return errs.Error.OutOfMemory;
}

fn isDirectory(io: Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// Recursively copy every file under `src_abs` to the matching
/// location under `dst_abs`, recording each leaf in the tracker.
/// `dst_rel_root` is the install-root-relative prefix for tracker
/// entries (so uninstall can reverse them).
fn copyTree(
    alloc: std.mem.Allocator,
    io: Io,
    mod_id: []const u8,
    src_abs: []const u8,
    dst_abs: []const u8,
    dst_rel_root: []const u8,
    tracker: *Tracker,
    install_dir: []const u8,
    opts: ApplyOpts,
) errs.Error!void {
    var dir = std.Io.Dir.cwd().openDir(io, src_abs, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.FileWriteFailed;
    defer dir.close(io);
    var walker = dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    var done: u32 = 0;
    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer deinitDirSet(alloc, &seen_dirs);
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const rel = entry.path;
        var src_buf: [1024]u8 = undefined;
        const sp = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_abs, rel }) catch continue;
        var dst_buf: [1024]u8 = undefined;
        const dp = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst_abs, rel }) catch continue;

        var rel_buf: [1024]u8 = undefined;
        const tracker_rel = if (dst_rel_root.len == 0 or std.mem.eql(u8, dst_rel_root, "."))
            rel
        else
            std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ dst_rel_root, rel }) catch rel;

        try recordCreatedDirs(alloc, io, install_dir, mod_id, tracker_rel, tracker, &seen_dirs);

        const exists = (std.Io.Dir.cwd().access(io, dp, .{}) catch null) != null;
        if (exists) try backupOriginal(alloc, io, opts.backup_mode, install_dir, mod_id, tracker_rel);
        tracker.record(.{
            .mod_id = mod_id,
            .path = tracker_rel,
            .kind = if (exists) .modified_file else .added_file,
            .backup_mode = if (exists) opts.backup_mode else .none,
        }) catch return errs.Error.OutOfMemory;

        copyFile(io, sp, dp) catch return errs.Error.FileWriteFailed;
        try afterFile(tracker, opts, &done, 0);
    }
}

fn doMove(
    alloc: std.mem.Allocator,
    io: Io,
    mod_id: []const u8,
    install_dir: []const u8,
    src_rel: []const u8,
    dst_rel: []const u8,
    tracker: *Tracker,
    opts: ApplyOpts,
) errs.Error!void {
    if (!isSafeRel(src_rel) or !isSafeRel(dst_rel)) return errs.Error.UnsafePath;

    const src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, src_rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(src);
    const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, dst_rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(dst);

    // Directory move: rename(2) refuses to clobber a non-empty
    // existing directory, so for the common "merge mod's `game/`
    // over the install's `game/`" case we copy-tree-then-delete
    // instead. Single-file moves keep the cheap rename path.
    if (isDirectory(io, src)) {
        std.Io.Dir.cwd().createDirPath(io, dst) catch return errs.Error.FileWriteFailed;
        try copyTree(alloc, io, mod_id, src, dst, dst_rel, tracker, install_dir, opts);
        std.Io.Dir.cwd().deleteTree(io, src) catch |e| {
            log.warn("doMove: deleteTree on source {s} failed: {s}", .{ src, @errorName(e) });
        };
        return;
    }

    if (std.fs.path.dirname(dst)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return errs.Error.FileWriteFailed;

    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer deinitDirSet(alloc, &seen_dirs);
    try recordCreatedDirs(alloc, io, install_dir, mod_id, dst_rel, tracker, &seen_dirs);

    const exists = (std.Io.Dir.cwd().access(io, dst, .{}) catch null) != null;
    if (exists) try backupOriginal(alloc, io, opts.backup_mode, install_dir, mod_id, dst_rel);
    std.Io.Dir.cwd().rename(src, std.Io.Dir.cwd(), dst, io) catch return errs.Error.FileWriteFailed;

    tracker.record(.{
        .mod_id = mod_id,
        .path = dst_rel,
        .kind = if (exists) .modified_file else .added_file,
        .backup_mode = if (exists) opts.backup_mode else .none,
    }) catch return errs.Error.OutOfMemory;
}

fn doDelete(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    rel: []const u8,
) errs.Error!void {
    if (!isSafeRel(rel)) return errs.Error.UnsafePath;
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(path);
    // Try file first, fall back to directory tree.
    if (std.Io.Dir.cwd().deleteFile(io, path)) |_| return else |e| switch (e) {
        error.FileNotFound => return,
        error.IsDir => {},
        else => return errs.Error.FileWriteFailed,
    }
    std.Io.Dir.cwd().deleteTree(io, path) catch return errs.Error.FileWriteFailed;
}

fn doChmodX(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    rel: []const u8,
) errs.Error!void {
    if (!isSafeRel(rel)) return errs.Error.UnsafePath;
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(path);
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return; // missing → silent
    defer f.close(io);
    // `executable_file` is the cross-platform "executable file" preset.
    // On POSIX it sets 0o755-ish; on Windows it's a no-op alias. The
    // caller already skipped the call on Windows, so this is moot on
    // that path either way.
    f.setPermissions(io, std.Io.File.Permissions.executable_file) catch {};
}

/// Reject `..` segments and absolute paths in caller-supplied relative
/// paths. The recipe validator catches these at parse time; this is
/// the runtime backstop.
fn isSafeRel(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Reverse the install: walk `log.entries` for `mod_id` in reverse,
/// undoing each entry per its kind. Persists nothing — caller is
/// responsible for rewriting the tracker file with the remaining
/// entries.
pub fn uninstallMod(
    io: Io,
    install_dir: []const u8,
    mod_id: []const u8,
    install_log: *const dom.InstallLog,
) errs.Error!void {
    var deleted: u32 = 0;
    var restored: u32 = 0;
    var warned: u32 = 0;
    var i: usize = install_log.entries.len;
    while (i > 0) {
        i -= 1;
        const e = install_log.entries[i];
        if (!std.mem.eql(u8, e.mod_id, mod_id)) continue;

        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, e.path }) catch continue;

        switch (e.kind) {
            .added_file => {
                std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
                    log.warn("uninstall {s}: delete {s} failed: {s}", .{ mod_id, path, @errorName(err) });
                    continue;
                };
                deleted += 1;
            },
            .modified_file => {
                switch (e.backup_mode) {
                    .copy => {
                        // Restore from `<install>/.f69-backups/<mod>/<rel>`,
                        // then delete the backup so the same path can be
                        // backed up again on a future install.
                        var bkp_buf: [1024]u8 = undefined;
                        const bkp = std.fmt.bufPrint(&bkp_buf, "{s}/{s}/{s}/{s}", .{ install_dir, BACKUP_ROOT_NAME, mod_id, e.path }) catch {
                            log.warn("uninstall {s}: backup path too long for {s}", .{ mod_id, e.path });
                            warned += 1;
                            continue;
                        };
                        copyFile(io, bkp, path) catch |err| {
                            log.warn("uninstall {s}: restore {s} failed: {s}", .{ mod_id, e.path, @errorName(err) });
                            warned += 1;
                            continue;
                        };
                        std.Io.Dir.cwd().deleteFile(io, bkp) catch {};
                        restored += 1;
                    },
                    .none => {
                        log.warn("uninstall {s}: {s} was modified — leaving as-is (no backup kept)", .{ mod_id, e.path });
                        warned += 1;
                    },
                }
            },
            .created_dir => {
                std.Io.Dir.cwd().deleteDir(io, path) catch {};
            },
            .mounted_overlay => {}, // unmounting is the overlay backend's job
        }
    }

    // Sweep the now-empty per-mod backup directory. Recursive rmdir is
    // a no-op if mounts/files remain (e.g. partial restore left a few
    // entries behind), so we leave evidence on disk in that case.
    var bkp_root_buf: [768]u8 = undefined;
    if (std.fmt.bufPrint(&bkp_root_buf, "{s}/{s}/{s}", .{ install_dir, BACKUP_ROOT_NAME, mod_id })) |bkp_root| {
        std.Io.Dir.cwd().deleteTree(io, bkp_root) catch {};
    } else |_| {}

    log.info("uninstall {s}: {d} deleted, {d} restored, {d} unrestorable", .{ mod_id, deleted, restored, warned });
}

// ============================================================
//  helpers
// ============================================================

/// Per-install backup root. Each mod's pre-existing-file backups live
/// under `<install>/.f69-backups/<mod_id>/<rel>`. Hidden dotfile so the
/// install dir stays tidy from the user's POV.
const BACKUP_ROOT_NAME = ".f69-backups";

/// Walk the parent chain of `rel` and record any directory segment
/// that doesn't yet exist on disk as a `.created_dir` tracker entry.
/// `seen_dirs` dedupes across files in the same apply run so
/// `game/scripts/` isn't recorded once per file. Vanilla dirs (already
/// present before the mod ran) are marked seen but NOT recorded, so
/// uninstall doesn't try to remove them.
///
/// `seen_dirs` owns its keys via `alloc`; caller frees on scope exit
/// (see `deinitDirSet`).
fn recordCreatedDirs(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    mod_id: []const u8,
    rel: []const u8,
    tracker: *Tracker,
    seen_dirs: *std.StringHashMap(void),
) errs.Error!void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| {
        const dir_rel = rel[0..slash];
        i = slash + 1;
        if (seen_dirs.contains(dir_rel)) continue;

        // Check existence on disk so we don't tag a pre-existing
        // vanilla dir as something uninstall should sweep.
        var abs_buf: [1024]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ install_dir, dir_rel }) catch continue;
        const exists = (std.Io.Dir.cwd().access(io, abs, .{}) catch null) != null;

        const owned = alloc.dupe(u8, dir_rel) catch return errs.Error.OutOfMemory;
        seen_dirs.put(owned, {}) catch {
            alloc.free(owned);
            return errs.Error.OutOfMemory;
        };

        if (exists) continue;
        tracker.record(.{
            .mod_id = mod_id,
            .path = dir_rel,
            .kind = .created_dir,
        }) catch return errs.Error.OutOfMemory;
    }
}

/// Free every key inserted by `recordCreatedDirs`. Tracker's own
/// internal copy is independent, so freeing here doesn't invalidate
/// recorded entries.
fn deinitDirSet(alloc: std.mem.Allocator, seen_dirs: *std.StringHashMap(void)) void {
    var it = seen_dirs.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    seen_dirs.deinit();
}

/// Per-file post-record bookkeeping shared by every bulk-file path
/// (`applyModArchive`, `extractAndOverlay`, `copyTree`). Bumps the
/// caller's done counter, periodically flushes the tracker so a crash
/// leaves recoverable state, reports progress through the optional
/// callback, and honours cooperative cancellation.
fn afterFile(tracker: *Tracker, opts: ApplyOpts, done: *u32, total: u32) errs.Error!void {
    done.* += 1;
    if (opts.flush_every > 0 and done.* % opts.flush_every == 0) try tracker.flush();
    if (opts.progress_cb) |cb| cb(opts.progress_ctx, done.*, total);
    if (opts.cancel) |c| {
        if (c.load(.monotonic)) return errs.Error.Canceled;
    }
}

/// Copy `<install_dir>/<rel>` to `<install_dir>/.f69-backups/<mod_id>/<rel>`.
/// Skipped when `mode == .none`. Skipped silently when the source file
/// doesn't exist (caller's exists-check already gated `modified_file`
/// vs `added_file`, but races + delete-then-overwrite recipes mean we
/// should tolerate a missing source). Errors propagate so callers can
/// decide whether to abort the whole install or continue.
fn backupOriginal(
    alloc: std.mem.Allocator,
    io: Io,
    mode: dom.BackupMode,
    install_dir: []const u8,
    mod_id: []const u8,
    rel: []const u8,
) errs.Error!void {
    if (mode == .none) return;

    const src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(src);
    if ((std.Io.Dir.cwd().access(io, src, .{}) catch null) == null) return;

    const dst = std.fmt.allocPrint(alloc, "{s}/{s}/{s}/{s}", .{ install_dir, BACKUP_ROOT_NAME, mod_id, rel }) catch return errs.Error.OutOfMemory;
    defer alloc.free(dst);

    copyFile(io, src, dst) catch return errs.Error.FileWriteFailed;
}

fn copyFile(io: Io, src: []const u8, dst: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    if (std.fs.path.dirname(dst)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
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
//  tests — driven by synthetic tar.gz / dir fixtures
// ============================================================

const testing = std.testing;

fn touchFile(io: Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn readFile(io: Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(64 * 1024));
}

/// Build a tar.gz fixture via shell-out. Returns the path. Skips the
/// test if `tar` isn't available or the sandbox blocks spawn.
fn buildTarGzFixture(io: Io, scratch: []const u8, files: []const struct { path: []const u8, body: []const u8 }) !?[]const u8 {
    var src_buf: [128]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_buf, "{s}/src", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, src_dir);

    for (files) |f| {
        var p_buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&p_buf, "{s}/{s}", .{ src_dir, f.path });
        try touchFile(io, p, f.body);
    }

    var tar_buf: [256]u8 = undefined;
    const tar_path = try std.fmt.bufPrint(&tar_buf, "{s}/mod.tar.gz", .{scratch});
    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "tar czf {s} -C {s} .", .{ tar_path, src_dir });
    const result = util_proc.run(testing.allocator, io, &.{ "sh", "-c", cmd }, .{
        .stderr = .ignore,
    }) catch return null;
    defer testing.allocator.free(result.stdout);
    if (result.exit_code != 0) return null;
    return try testing.allocator.dupe(u8, tar_path);
}

test "apply: empty install dir → all files added" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-apply-add";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "game/cheats.rpyc", .body = "cheats" },
        .{ .path = "README.md", .body = "hi" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var install_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&install_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    try applyModArchive(testing.allocator, io, "cheat-mod", tar_path, install_dir, &tracker, .{});

    // Both files should now be in install_dir.
    var p_buf: [256]u8 = undefined;
    const cheats = try std.fmt.bufPrint(&p_buf, "{s}/game/cheats.rpyc", .{install_dir});
    const cheats_body = try readFile(io, cheats);
    defer testing.allocator.free(cheats_body);
    try testing.expectEqualStrings("cheats", cheats_body);

    // Tracker should have 2 added_file entries plus 1 created_dir for
    // `game/` (so uninstall can sweep the empty dir after deleting files).
    var read_log = try Tracker.load(testing.allocator, io, log_path);
    defer read_log.deinit(testing.allocator);
    var added: usize = 0;
    var dirs: usize = 0;
    for (read_log.entries) |e| {
        try testing.expectEqualStrings("cheat-mod", e.mod_id);
        switch (e.kind) {
            .added_file => added += 1,
            .created_dir => dirs += 1,
            else => return error.UnexpectedKind,
        }
    }
    try testing.expectEqual(@as(usize, 2), added);
    try testing.expectEqual(@as(usize, 1), dirs);
}

test "apply: existing file → recorded as modified, no backup created" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-apply-modified";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "options.rpy", .body = "MOD" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var install_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&install_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);
    var op_buf: [256]u8 = undefined;
    const orig_options = try std.fmt.bufPrint(&op_buf, "{s}/options.rpy", .{install_dir});
    try touchFile(io, orig_options, "BASE");

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    try applyModArchive(testing.allocator, io, "patch", tar_path, install_dir, &tracker, .{});

    // File was overwritten with mod content.
    const after = try readFile(io, orig_options);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("MOD", after);

    var read_log = try Tracker.load(testing.allocator, io, log_path);
    defer read_log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), read_log.entries.len);
    try testing.expectEqual(dom.InstallLog.Kind.modified_file, read_log.entries[0].kind);

    // No backup dir created.
    var bp_buf: [256]u8 = undefined;
    const bp_dir = try std.fmt.bufPrint(&bp_buf, "{s}/.f69-backups", .{install_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, bp_dir, .{}));
}

test "uninstall: added file gets deleted" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-uninstall-added";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    var p_buf: [256]u8 = undefined;
    const f1 = try std.fmt.bufPrint(&p_buf, "{s}/cheats.rpyc", .{scratch});
    try touchFile(io, f1, "x");

    // Build a tracker log by hand.
    var owned_mod = try testing.allocator.dupe(u8, "patch");
    const owned_path = try testing.allocator.dupe(u8, "cheats.rpyc");
    var entries_buf = [_]dom.InstallLog.Entry{.{
        .mod_id = owned_mod,
        .path = owned_path,
        .kind = .added_file,
    }};
    const entries_slice = try testing.allocator.dupe(dom.InstallLog.Entry, &entries_buf);
    var install_log = dom.InstallLog{ .entries = entries_slice };
    defer install_log.deinit(testing.allocator);
    _ = &owned_mod;

    try uninstallMod(io, scratch, "patch", &install_log);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, f1, .{}));
}

test "applyModRecipe: extract step honors strip" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-recipe-strip";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    // tar.gz has files under a top-level dir `pkg/`; strip=1 should
    // drop it.
    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "pkg/game/cheat.rpy", .body = "cheat" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var inst_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&inst_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    const steps = [_]recipe.InstallStep{
        .{ .extract = .{ .to = ".", .strip = 1 } },
    };
    try applyModRecipe(testing.allocator, io, "mod", tar_path, install_dir, &steps, &tracker, .{});

    // After strip=1, files should land directly under install_dir/game/.
    var p_buf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&p_buf, "{s}/game/cheat.rpy", .{install_dir});
    const body = try readFile(io, target);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("cheat", body);
}

test "applyModRecipe: delete step removes file" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-recipe-delete";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "keep.rpy", .body = "K" },
        .{ .path = "drop.rpy", .body = "D" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var inst_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&inst_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    const steps = [_]recipe.InstallStep{
        .{ .extract = .{ .to = ".", .strip = 0 } },
        .{ .delete = .{ .path = "drop.rpy" } },
    };
    try applyModRecipe(testing.allocator, io, "mod", tar_path, install_dir, &steps, &tracker, .{});

    var p_buf: [256]u8 = undefined;
    const dropped = try std.fmt.bufPrint(&p_buf, "{s}/drop.rpy", .{install_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dropped, .{}));

    const kept = try std.fmt.bufPrint(&p_buf, "{s}/keep.rpy", .{install_dir});
    _ = try std.Io.Dir.cwd().access(io, kept, .{});
}

test "applyModRecipe: move renames file" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-recipe-move";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "old.rpy", .body = "M" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var inst_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&inst_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    const steps = [_]recipe.InstallStep{
        .{ .extract = .{ .to = ".", .strip = 0 } },
        .{ .move = .{ .src = "old.rpy", .dest = "game/new.rpy" } },
    };
    try applyModRecipe(testing.allocator, io, "mod", tar_path, install_dir, &steps, &tracker, .{});

    var p_buf: [256]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&p_buf, "{s}/old.rpy", .{install_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, old_path, .{}));

    const new_path = try std.fmt.bufPrint(&p_buf, "{s}/game/new.rpy", .{install_dir});
    const body = try readFile(io, new_path);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("M", body);
}

test "applyModRecipe: rejects path escape at runtime" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-recipe-escape";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    var inst_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&inst_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    const steps = [_]recipe.InstallStep{
        .{ .delete = .{ .path = "../../etc/passwd" } },
    };
    const r = applyModRecipe(testing.allocator, io, "mod", "ignored", install_dir, &steps, &tracker, .{});
    try testing.expectError(errs.Error.UnsafePath, r);
}

test "uninstall: modified file is left as-is (no backup kept)" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-uninstall-mod-asis";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    var p_buf: [256]u8 = undefined;
    const live = try std.fmt.bufPrint(&p_buf, "{s}/options.rpy", .{scratch});
    try touchFile(io, live, "MOD WRITTEN");

    const entries_buf = [_]dom.InstallLog.Entry{.{
        .mod_id = try testing.allocator.dupe(u8, "patch"),
        .path = try testing.allocator.dupe(u8, "options.rpy"),
        .kind = .modified_file,
    }};
    const entries_slice = try testing.allocator.dupe(dom.InstallLog.Entry, &entries_buf);
    var install_log = dom.InstallLog{ .entries = entries_slice };
    defer install_log.deinit(testing.allocator);

    try uninstallMod(io, scratch, "patch", &install_log);

    // File stays as-is — we have no backup to restore from.
    const still_there = try readFile(io, live);
    defer testing.allocator.free(still_there);
    try testing.expectEqualStrings("MOD WRITTEN", still_there);
}

test "backup_mode.copy: install mirrors original then uninstall restores" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-backup-roundtrip";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "options.rpy", .body = "MOD" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var install_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&install_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);
    var op_buf: [256]u8 = undefined;
    const live = try std.fmt.bufPrint(&op_buf, "{s}/options.rpy", .{install_dir});
    try touchFile(io, live, "BASE");

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    try applyModArchive(testing.allocator, io, "patch", tar_path, install_dir, &tracker, .{ .backup_mode = .copy });

    // Mod content landed.
    {
        const after = try readFile(io, live);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings("MOD", after);
    }

    // Backup of the original is at <install>/.f69-backups/patch/options.rpy.
    var bp_buf: [256]u8 = undefined;
    const bkp = try std.fmt.bufPrint(&bp_buf, "{s}/.f69-backups/patch/options.rpy", .{install_dir});
    const bkp_body = try readFile(io, bkp);
    defer testing.allocator.free(bkp_body);
    try testing.expectEqualStrings("BASE", bkp_body);

    // Now uninstall via the on-disk log — verifies the persisted
    // backup_mode round-trips through tracker serialization.
    var install_log_loaded = try Tracker.load(testing.allocator, io, log_path);
    defer install_log_loaded.deinit(testing.allocator);
    try testing.expectEqual(dom.BackupMode.copy, install_log_loaded.entries[0].backup_mode);

    try uninstallMod(io, install_dir, "patch", &install_log_loaded);

    const restored = try readFile(io, live);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("BASE", restored);

    // Per-mod backup dir is swept after restore.
    var bp_dir_buf: [256]u8 = undefined;
    const bp_dir = try std.fmt.bufPrint(&bp_dir_buf, "{s}/.f69-backups/patch", .{install_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, bp_dir, .{}));
}

test "uninstall: sweeps mod-created subdirs but keeps vanilla ones" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const scratch = "/tmp/f69-test-uninstall-dirs";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    // Mod ships files in `game/scripts/<mod>/cheats.rpyc` — `game/`
    // exists pre-install (vanilla), the rest are mod-created.
    const tar_opt = try buildTarGzFixture(io, scratch, &.{
        .{ .path = "game/scripts/cheatmenu/cheats.rpyc", .body = "cheats" },
    });
    if (tar_opt == null) return error.SkipZigTest;
    const tar_path = tar_opt.?;
    defer testing.allocator.free(tar_path);

    var install_buf: [128]u8 = undefined;
    const install_dir = try std.fmt.bufPrint(&install_buf, "{s}/install", .{scratch});
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

    // Vanilla `game/` lives here BEFORE the mod runs. Also stash an
    // unrelated vanilla file so the dir is non-empty post-uninstall —
    // deleteDir should refuse to remove `game/` because it still has
    // `script.rpy`.
    var van_buf: [256]u8 = undefined;
    const vanilla_dir = try std.fmt.bufPrint(&van_buf, "{s}/game", .{install_dir});
    try std.Io.Dir.cwd().createDirPath(io, vanilla_dir);
    const vanilla_file = try std.fmt.bufPrint(&van_buf, "{s}/game/script.rpy", .{install_dir});
    try touchFile(io, vanilla_file, "vanilla content");

    var log_buf: [128]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/.f69-mods.json", .{install_dir});
    var tracker = Tracker.init(testing.allocator, io, log_path);
    defer tracker.deinit();

    try applyModArchive(testing.allocator, io, "cheatmod", tar_path, install_dir, &tracker, .{});

    // Sanity: mod file landed.
    var p_buf: [256]u8 = undefined;
    const installed = try std.fmt.bufPrint(&p_buf, "{s}/game/scripts/cheatmenu/cheats.rpyc", .{install_dir});
    const body = try readFile(io, installed);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("cheats", body);

    // Now uninstall.
    var loaded = try Tracker.load(testing.allocator, io, log_path);
    defer loaded.deinit(testing.allocator);
    try uninstallMod(io, install_dir, "cheatmod", &loaded);

    // Mod-created dirs are gone.
    const cheatmenu_dir = try std.fmt.bufPrint(&p_buf, "{s}/game/scripts/cheatmenu", .{install_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, cheatmenu_dir, .{}));
    const scripts_dir = try std.fmt.bufPrint(&p_buf, "{s}/game/scripts", .{install_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, scripts_dir, .{}));

    // Vanilla `game/` is still there because deleteDir refuses to
    // remove a non-empty dir (script.rpy is still inside).
    _ = try std.Io.Dir.cwd().access(io, vanilla_dir, .{});
    const van_body = try readFile(io, vanilla_file);
    defer testing.allocator.free(van_body);
    try testing.expectEqualStrings("vanilla content", van_body);
}
