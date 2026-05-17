// Handler vtable. Each download backend (http, aria2, rpdl, mega, …)
// provides a constructor returning a `Handler`. Manager owns a list of
// handlers, **sorted by `priority` ascending** at registration time, and
// dispatches by url match: lowest priority that returns true from
// canHandle wins.
//
// Priorities (lower = checked first):
//
//   10  — host-specific (rpdl, f95_attachment direct)
//   20  — generic mirror handlers (mega, mediafire, gofile, ...)
//   50  — aria2 catch-all for http/https/ftp/magnet
//   60  — std.http catch-all (when prefer_native_http)
//  255  — browser-fallback (always last)
//
// Picking explicit numbers > registration order makes the dispatch chain
// auditable and prevents the registration-order landmine.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");

pub const Handler = struct {
    ptr: *anyopaque,
    /// Lower runs first. See header comment for conventions.
    priority: u8,
    vtable: *const VTable,

    pub const VTable = struct {
        canHandle: *const fn (ptr: *anyopaque, url: []const u8) bool,
        download: *const fn (ptr: *anyopaque, job: *domain.Job) errs.Error!void,
        deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };

    pub inline fn canHandle(self: Handler, url: []const u8) bool {
        return self.vtable.canHandle(self.ptr, url);
    }
    pub inline fn download(self: Handler, job: *domain.Job) errs.Error!void {
        return self.vtable.download(self.ptr, job);
    }
    pub inline fn deinit(self: Handler, alloc: std.mem.Allocator) void {
        return self.vtable.deinit(self.ptr, alloc);
    }
};
