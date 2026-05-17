// mega.nz handler. Public API exists but free tier rate-limits aggressively.
// Two strategies: (a) direct via mega's REST API (works for public links;
// needs decryption since file content is client-side encrypted), or
// (b) shell out to `megatools dl`. Start with (b) — simpler, robust.

const std = @import("std");
const errs = @import("../errors.zig");
const dom = @import("../domain.zig");
const Handler = @import("../handler.zig").Handler;

const Self = @This();
alloc: std.mem.Allocator,

pub fn create(alloc: std.mem.Allocator) !Handler {
    const self = try alloc.create(Self);
    self.* = .{ .alloc = alloc };
    return .{ .ptr = self, .priority = 20, .vtable = &vtable };
}

fn canHandle(_: *anyopaque, url: []const u8) bool {
    return std.mem.indexOf(u8, url, "mega.nz") != null or std.mem.indexOf(u8, url, "mega.co.nz") != null;
}

fn download(ptr: *anyopaque, job: *dom.Job) errs.Error!void {
    _ = ptr;
    _ = job;
    return errs.Error.HostUnreachable; // TODO: spawn megatools dl
}

fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    alloc.destroy(self);
}

const vtable = Handler.VTable{ .canHandle = canHandle, .download = download, .deinit = deinit };
