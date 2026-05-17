// MediaFire: scrape the file page HTML for the direct download URL,
// then hand off to the http or aria2 handler.

const std = @import("std");
const errs = @import("../errors.zig");
const dom = @import("../domain.zig");
const Handler = @import("../handler.zig").Handler;

const Self = @This();
alloc: std.mem.Allocator,
http_delegate: Handler,

pub fn create(alloc: std.mem.Allocator, http_delegate: Handler) !Handler {
    const self = try alloc.create(Self);
    self.* = .{ .alloc = alloc, .http_delegate = http_delegate };
    return .{ .ptr = self, .priority = 20, .vtable = &vtable };
}

fn canHandle(_: *anyopaque, url: []const u8) bool {
    return std.mem.indexOf(u8, url, "mediafire.com") != null;
}

fn download(ptr: *anyopaque, job: *dom.Job) errs.Error!void {
    _ = ptr;
    _ = job;
    return errs.Error.HostUnreachable; // TODO: scrape direct link, mutate job.source_url, delegate
}

fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    alloc.destroy(self);
}

const vtable = Handler.VTable{ .canHandle = canHandle, .download = download, .deinit = deinit };
