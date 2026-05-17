// File-level conflict detection. Catches mods the recipe author didn't
// declare conflicts for: two mods writing the same path with different
// content. Run as a dry-run after solver.solve() succeeds.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");

pub const FileSet = std.StringHashMap([32]u8); // path → sha256

pub fn detect(
    alloc: std.mem.Allocator,
    plan: *const domain.Plan,
    files_per_mod: []const FileSet,
) errs.Error![]domain.Conflict {
    _ = alloc;
    _ = plan;
    _ = files_per_mod;
    return &.{}; // TODO
}
