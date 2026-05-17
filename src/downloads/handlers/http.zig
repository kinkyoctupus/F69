// Plain HTTP/HTTPS handler via std.http.Client. Used when
// AppConfig.prefer_native_http is true, or as a fallback when aria2c
// is unavailable.

const std = @import("std");
const errs = @import("../errors.zig");
const dom = @import("../domain.zig");
const Handler = @import("../handler.zig").Handler;

const Self = @This();

alloc: std.mem.Allocator,

pub fn create(alloc: std.mem.Allocator) !Handler {
    const self = try alloc.create(Self);
    self.* = .{ .alloc = alloc };
    // Priority 60 — catch-all for plain http/https when prefer_native_http
    // is set; otherwise aria2 (priority 50) wins.
    return .{ .ptr = self, .priority = 60, .vtable = &vtable };
}

fn canHandle(_: *anyopaque, url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

fn download(ptr: *anyopaque, job: *dom.Job) errs.Error!void {
    _ = ptr;
    _ = job;
    return errs.Error.HostUnreachable; // TODO: std.http.Client.fetch + chunk to disk + verify
}

fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    alloc.destroy(self);
}

const vtable = Handler.VTable{
    .canHandle = canHandle,
    .download = download,
    .deinit = deinit,
};
