// GoFile: documented public JSON API at api.gofile.io. No auth needed
// for public folders. Walk the folder, get direct file URLs, hand to http/aria2.

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
    return std.mem.indexOf(u8, url, "gofile.io") != null;
}

fn download(ptr: *anyopaque, job: *dom.Job) errs.Error!void {
    _ = ptr;
    _ = job;
    return errs.Error.HostUnreachable; // TODO
}

fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    alloc.destroy(self);
}

const vtable = Handler.VTable{ .canHandle = canHandle, .download = download, .deinit = deinit };
