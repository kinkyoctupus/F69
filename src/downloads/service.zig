// DownloadService — façade over Manager. UI / installer talk to this.

const std = @import("std");
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const Manager = @import("manager.zig").Manager;

pub const Service = struct {
    manager: *Manager,

    pub fn init(manager: *Manager) Service {
        return .{ .manager = manager };
    }

    pub fn enqueue(self: *Service, job: dom.Job) errs.Error!u64 {
        return self.manager.enqueue(job);
    }

    pub fn cancel(self: *Service, id: u64) void {
        self.manager.cancel(id);
    }
};
