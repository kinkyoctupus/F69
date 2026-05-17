// Installer execution log + tracker types.

const std = @import("std");

/// Per-mod backup policy. Recorded on the install entry so uninstall
/// knows whether to restore the original or warn. Default is `none` so
/// 15GB overlay mods don't silently double on disk; users opt into
/// `copy` per-install when they want a clean uninstall.
pub const BackupMode = enum {
    /// No backup. `modified_file` entries are unrestorable; uninstall
    /// warns and leaves the on-disk content as-is.
    none,
    /// Pre-existing content is mirrored to `<install>/.f69-backups/<mod>/<rel>`
    /// before the mod overwrites. Uninstall restores from there.
    copy,
};

pub const InstallLog = struct {
    /// Entries in the order the install applied them. Uninstall walks
    /// in reverse.
    entries: []const Entry,

    pub const Kind = enum {
        added_file, // path didn't exist before — uninstall deletes
        modified_file, // path existed; mod overwrote it — uninstall warns or restores
        created_dir, // empty dir created by install — uninstall rmdir-on-empty
        mounted_overlay,
    };

    pub const Entry = struct {
        /// Mod id whose install put this entry on disk. Empty for base-
        /// game install steps.
        mod_id: []const u8 = "",
        path: []const u8,
        kind: Kind,
        /// SHA-256 of the file we wrote (for `added_file` / `modified_file`).
        /// Helps detect drift between install + uninstall.
        sha256: ?[32]u8 = null,
        /// Whether this entry's pre-existing content was backed up. Only
        /// meaningful for `modified_file` — uninstall reads it to decide
        /// restore vs. warn. Defaulting to `.none` keeps legacy log
        /// entries (no field on disk) loading as today's behaviour.
        backup_mode: BackupMode = .none,
    };

    pub fn deinit(self: *InstallLog, alloc: std.mem.Allocator) void {
        for (self.entries) |e| {
            if (e.mod_id.len > 0) alloc.free(e.mod_id);
            alloc.free(e.path);
        }
        if (self.entries.len > 0) alloc.free(self.entries);
        self.* = .{ .entries = &.{} };
    }
};

pub const OverlayMode = enum {
    overlayfs, // Linux kernel OverlayFS (preferred)
    flat_copy, // copy base, then mod files in load order — fallback
};
