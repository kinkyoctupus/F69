// Backup store. Snapshot a file before a recipe action mutates it;
// restore it on undo or rollback.
//
// Layout, per install:
//   <store_root>/<install_id>/
//     <sha-prefix>/<full-sha>          ← snapshot contents
//
// Content-addressed by SHA-256 of the original bytes so two recipes
// touching the same path share one snapshot. The owning FixRecord
// carries the per-file BackupRecord (sha + relpath + metadata) so
// restore knows where to write back.
//
// MVP supports regular files and symlinks. Directories are not yet
// snapshotted — no current Action mutates a dir wholesale.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");

const log = std.log.scoped(.compat_backup);

const SNAPSHOT_READ_LIMIT: usize = 256 * 1024 * 1024; // 256 MiB
const HEX: []const u8 = "0123456789abcdef";

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// `<data_root>/compat-backups`. Per-install subdir is created on
    /// first write.
    root: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8) Store {
        return .{ .alloc = alloc, .io = io, .root = root };
    }

    /// Snapshot `install_root/relpath` into the store. Returns a
    /// BackupRecord ready to embed in a FixRecord. Caller owns the
    /// strings inside (allocated on `self.alloc`).
    pub fn snapshot(
        self: *Store,
        install_id: []const u8,
        install_root: []const u8,
        touched: dom.TouchedPath,
    ) errs.Error!dom.BackupRecord {
        const full = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ install_root, touched.relpath }) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(full);

        // Detect symlink by attempting readLink. If it succeeds, the
        // path is a symlink; otherwise treat as regular file.
        var sym_buf: [4096]u8 = undefined;
        const sym_len_opt: ?usize = std.Io.Dir.cwd().readLink(self.io, full, &sym_buf) catch null;

        if (sym_len_opt) |sym_len| {
            const target = sym_buf[0..sym_len];
            const target_owned = self.alloc.dupe(u8, target) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(target_owned);
            const relpath_owned = self.alloc.dupe(u8, touched.relpath) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(relpath_owned);
            const sha = sha256OfBytes(target);
            const sha_hex = hexFromDigest(self.alloc, sha) catch return errs.Error.OutOfMemory;
            return .{
                .sha256 = sha_hex,
                .relpath = relpath_owned,
                .size = 0,
                .mode = 0o777,
                .was_symlink = true,
                .symlink_target = target_owned,
            };
        }

        // Regular file path. Read into memory; the snapshot is then
        // written content-addressed under the store.
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            full,
            self.alloc,
            .limited(SNAPSHOT_READ_LIMIT),
        ) catch |e| {
            return switch (e) {
                error.OutOfMemory => errs.Error.OutOfMemory,
                error.FileNotFound => errs.Error.FileNotFound,
                error.AccessDenied, error.PermissionDenied => errs.Error.PermissionDenied,
                else => errs.Error.IoError,
            };
        };
        defer self.alloc.free(bytes);

        const sha = sha256OfBytes(bytes);
        const sha_hex = hexFromDigest(self.alloc, sha) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(sha_hex);

        try self.writeSnapshot(install_id, sha_hex, bytes);

        const relpath_owned = self.alloc.dupe(u8, touched.relpath) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(relpath_owned);

        return .{
            .sha256 = sha_hex,
            .relpath = relpath_owned,
            .size = bytes.len,
            .mode = 0o644,
            .was_symlink = false,
            .symlink_target = null,
        };
    }

    /// Restore a backup back into the install tree. Idempotent —
    /// re-running with the same record overwrites the destination
    /// with the snapshotted content.
    pub fn restore(
        self: *Store,
        install_id: []const u8,
        install_root: []const u8,
        rec: dom.BackupRecord,
    ) errs.Error!void {
        const dest = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ install_root, rec.relpath }) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(dest);

        if (std.fs.path.dirname(dest)) |parent| {
            std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
        }

        // Clear existing entry — works for both symlink and regular file.
        std.Io.Dir.cwd().deleteFile(self.io, dest) catch {};

        if (rec.was_symlink) {
            const target = rec.symlink_target orelse return errs.Error.BackupMismatch;
            std.Io.Dir.cwd().symLink(self.io, target, dest, .{}) catch |e| {
                log.warn("symlink restore failed for {s}: {s}", .{ dest, @errorName(e) });
                return errs.Error.IoError;
            };
            return;
        }

        const snap_path = try self.snapshotPath(install_id, rec.sha256);
        defer self.alloc.free(snap_path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            snap_path,
            self.alloc,
            .limited(SNAPSHOT_READ_LIMIT),
        ) catch return errs.Error.IoError;
        defer self.alloc.free(bytes);

        // Verify integrity before writing.
        const verify_digest = sha256OfBytes(bytes);
        const verify_hex = hexFromDigest(self.alloc, verify_digest) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(verify_hex);
        if (!std.mem.eql(u8, verify_hex, rec.sha256)) return errs.Error.BackupMismatch;

        try writeBytes(self.io, dest, bytes);
    }

    /// Re-hash a backup snapshot and verify it matches the record.
    /// Use before relying on a backup that's been sitting on disk.
    pub fn verify(self: *Store, install_id: []const u8, rec: dom.BackupRecord) errs.Error!void {
        if (rec.was_symlink) return; // symlink records carry their target inline
        const snap_path = try self.snapshotPath(install_id, rec.sha256);
        defer self.alloc.free(snap_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            snap_path,
            self.alloc,
            .limited(SNAPSHOT_READ_LIMIT),
        ) catch return errs.Error.IoError;
        defer self.alloc.free(bytes);
        const digest = sha256OfBytes(bytes);
        const hex = hexFromDigest(self.alloc, digest) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(hex);
        if (!std.mem.eql(u8, hex, rec.sha256)) return errs.Error.BackupMismatch;
    }

    /// Free strings owned by a BackupRecord that this store allocated.
    pub fn freeRecord(self: *Store, rec: dom.BackupRecord) void {
        self.alloc.free(rec.sha256);
        self.alloc.free(rec.relpath);
        if (rec.symlink_target) |t| self.alloc.free(t);
    }

    fn writeSnapshot(self: *Store, install_id: []const u8, sha_hex: []const u8, bytes: []const u8) errs.Error!void {
        if (sha_hex.len < 2) return errs.Error.IoError;
        const dir = std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ self.root, install_id, sha_hex[0..2] }) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(dir);
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch return errs.Error.IoError;
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir, sha_hex }) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(path);
        // Skip write if the snapshot already exists — content
        // addressed, so identical content already lives there.
        std.Io.Dir.cwd().access(self.io, path, .{}) catch {
            try writeBytes(self.io, path, bytes);
        };
    }

    fn snapshotPath(self: *Store, install_id: []const u8, sha_hex: []const u8) errs.Error![]u8 {
        if (sha_hex.len < 2) return errs.Error.BackupMismatch;
        return std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}/{s}", .{ self.root, install_id, sha_hex[0..2], sha_hex }) catch errs.Error.OutOfMemory;
    }
};

fn writeBytes(io: std.Io, path: []const u8, bytes: []const u8) errs.Error!void {
    var f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return errs.Error.IoError;
    defer f.close(io);
    var fw_buf: [16 * 1024]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    fw.interface.writeAll(bytes) catch return errs.Error.IoError;
    fw.interface.flush() catch return errs.Error.IoError;
}

fn sha256OfBytes(bytes: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}

fn hexFromDigest(alloc: std.mem.Allocator, digest: [32]u8) ![]u8 {
    const out = try alloc.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[2 * i] = HEX[b >> 4];
        out[2 * i + 1] = HEX[b & 0xf];
    }
    return out;
}

// -----------------------------------------------------------------
//  tests — exercise snapshot/restore round-trip in a tmpdir
// -----------------------------------------------------------------

fn tmpRoot(io: std.Io, label: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/f69-compat-backup-{s}", .{label});
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.testing.allocator.dupe(u8, path);
}

test "snapshot then restore round-trips file content" {
    const ta = std.testing.allocator;
    var tio = std.Io.Threaded.init(ta, .{});
    defer tio.deinit();
    const io = tio.io();

    const tmp_path = try tmpRoot(io, "roundtrip");
    defer ta.free(tmp_path);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    const install_root = try std.fmt.allocPrint(ta, "{s}/install", .{tmp_path});
    defer ta.free(install_root);
    const store_root = try std.fmt.allocPrint(ta, "{s}/backups", .{tmp_path});
    defer ta.free(store_root);

    const file_dir = try std.fmt.allocPrint(ta, "{s}/lib", .{install_root});
    defer ta.free(file_dir);
    try std.Io.Dir.cwd().createDirPath(io, file_dir);
    const file_path = try std.fmt.allocPrint(ta, "{s}/foo.so", .{file_dir});
    defer ta.free(file_path);

    const original = "original-bytes";
    try writeBytes(io, file_path, original);

    var store = Store.init(ta, io, store_root);
    const touched = dom.TouchedPath{ .relpath = "lib/foo.so" };
    const rec = try store.snapshot("test-install-id", install_root, touched);
    defer store.freeRecord(rec);

    try writeBytes(io, file_path, "modified-bytes-by-fix");

    try store.restore("test-install-id", install_root, rec);

    const restored = try std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        ta,
        .limited(64 * 1024),
    );
    defer ta.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}

test "verify catches corrupted snapshot" {
    const ta = std.testing.allocator;
    var tio = std.Io.Threaded.init(ta, .{});
    defer tio.deinit();
    const io = tio.io();

    const tmp_path = try tmpRoot(io, "verify");
    defer ta.free(tmp_path);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    const install_root = try std.fmt.allocPrint(ta, "{s}/install", .{tmp_path});
    defer ta.free(install_root);
    const store_root = try std.fmt.allocPrint(ta, "{s}/backups", .{tmp_path});
    defer ta.free(store_root);

    try std.Io.Dir.cwd().createDirPath(io, install_root);
    const file_path = try std.fmt.allocPrint(ta, "{s}/data.bin", .{install_root});
    defer ta.free(file_path);
    try writeBytes(io, file_path, "data");

    var store = Store.init(ta, io, store_root);
    const rec = try store.snapshot("iid", install_root, .{ .relpath = "data.bin" });
    defer store.freeRecord(rec);
    try store.verify("iid", rec);

    const snap_path = try store.snapshotPath("iid", rec.sha256);
    defer ta.free(snap_path);
    try writeBytes(io, snap_path, "corrupted");

    try std.testing.expectError(errs.Error.BackupMismatch, store.verify("iid", rec));
}
