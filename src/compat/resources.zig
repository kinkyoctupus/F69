// Resource resolver — maps a recipe's resource id to its absolute
// path under `<data_root>/compat-resources/<id>/`.
//
// Resources are materialized at app build time (the flake's
// per-engine FHS-libs derivations — `renpy7-fhs-libs`,
// `renpy8-fhs-libs`, `rpgm-mv-fhs-libs`, `unity-fhs-libs` — land
// under the install output's `data/compat-resources/` directory;
// build.zig copies them there). The runtime just verifies presence
// + hands back an absolute path.

const std = @import("std");
const errs = @import("errors.zig");

pub const Resolver = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Absolute path of `<data_root>/compat-resources`.
    root: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, root: []const u8) Resolver {
        return .{ .alloc = alloc, .io = io, .root = root };
    }

    /// Resolve `<id>` to `<root>/<id>`. Returns OwnsPath; caller frees.
    /// Errors when the directory doesn't exist on disk.
    pub fn resolve(self: *const Resolver, id: []const u8) errs.Error![]u8 {
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.root, id }) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return errs.Error.ResourceNotMaterialized;
        return path;
    }

    /// Resolve `<id>/<relpath>`. Use when the action's `from_resource`
    /// includes a relpath component. Caller frees.
    pub fn resolveSub(self: *const Resolver, id: []const u8, relpath: []const u8) errs.Error![]u8 {
        const path = if (relpath.len == 0)
            std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.root, id }) catch return errs.Error.OutOfMemory
        else
            std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ self.root, id, relpath }) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return errs.Error.ResourceNotMaterialized;
        return path;
    }
};
