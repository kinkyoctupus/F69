// ResolverService — facade over solver + file-level conflict check.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const solver = @import("solver.zig");
const files = @import("files.zig");

pub const Service = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{ .alloc = alloc };
    }

    pub fn plan(self: *Service, in: solver.Input) errs.Error!domain.Plan {
        return solver.solve(self.alloc, in);
    }

    pub fn detectFileConflicts(
        self: *Service,
        plan_in: *const domain.Plan,
        files_per_mod: []const files.FileSet,
    ) errs.Error![]domain.Conflict {
        return files.detect(self.alloc, plan_in, files_per_mod);
    }
};
