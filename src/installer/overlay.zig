// Overlay backend — closed set, exactly two impls. Tagged union, not
// vtable. Compiler can devirtualize the switch arms; exhaustive checking
// catches missed branches when we add a third impl (we won't).
//
//   overlayfs: kernel OverlayFS mount (Linux, requires unprivileged
//              userns — Debian/Ubuntu commonly block this; we degrade
//              cleanly to flat).
//   flat:      copy base, then each mod's files in load order. Tracker
//              logs every overwritten file's pre-image so uninstall can
//              roll back. **Default — works everywhere.**
//
// Architect review (2026-05-08): build flat first. OverlayFS is a later
// optimization for systems where userns is permitted.

const std = @import("std");
const errs = @import("errors.zig");

pub const OverlayBackend = union(enum) {
    overlayfs: OverlayFs,
    flat: FlatCopy,

    pub fn layer(
        self: *OverlayBackend,
        base_dir: []const u8,
        mod_dirs: []const []const u8,
        merged_dir: []const u8,
    ) errs.Error!void {
        return switch (self.*) {
            inline else => |*x| x.layer(base_dir, mod_dirs, merged_dir),
        };
    }

    pub fn unlayer(self: *OverlayBackend, merged_dir: []const u8) errs.Error!void {
        return switch (self.*) {
            inline else => |*x| x.unlayer(merged_dir),
        };
    }

    pub fn deinit(self: *OverlayBackend, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*x| x.deinit(alloc),
        }
    }
};

/// Detect best available backend at runtime. Always falls back to flat
/// rather than failing — every system can flat-copy.
pub fn pickBackend(alloc: std.mem.Allocator) OverlayBackend {
    if (OverlayFs.detect()) |fs| {
        _ = alloc;
        return .{ .overlayfs = fs };
    }
    return .{ .flat = FlatCopy.init() };
}

// ----- impls -----

pub const OverlayFs = struct {
    pub fn detect() ?OverlayFs {
        // TODO: try `unshare -Ur true`, parse /proc/sys/kernel/unprivileged_userns_clone.
        // Return null on Debian/Ubuntu w/ AppArmor blocking, etc.
        return null;
    }

    pub fn layer(self: *OverlayFs, base: []const u8, mods: []const []const u8, merged: []const u8) errs.Error!void {
        _ = self;
        _ = base;
        _ = mods;
        _ = merged;
        return errs.Error.OverlayMountFailed; // TODO
    }

    pub fn unlayer(self: *OverlayFs, merged: []const u8) errs.Error!void {
        _ = self;
        _ = merged;
        return errs.Error.OverlayMountFailed; // TODO
    }

    pub fn deinit(self: *OverlayFs, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const FlatCopy = struct {
    pub fn init() FlatCopy {
        return .{};
    }

    pub fn layer(self: *FlatCopy, base: []const u8, mods: []const []const u8, merged: []const u8) errs.Error!void {
        _ = self;
        _ = base;
        _ = mods;
        _ = merged;
        // TODO:
        //   1. mkdir -p merged
        //   2. cp -r base/* merged/
        //   3. for each mod in load order: cp -r mod/* merged/  (overwrite,
        //      Tracker logs pre-image)
    }

    pub fn unlayer(self: *FlatCopy, merged: []const u8) errs.Error!void {
        _ = self;
        _ = merged;
        // For flat, "unlayer" is a no-op; uninstall handled by Tracker
        // walking the install log.
    }

    pub fn deinit(self: *FlatCopy, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};
