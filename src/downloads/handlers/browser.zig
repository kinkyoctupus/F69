// Fallback handler: open URL in user's default browser via xdg-open
// (Linux) / Start (Windows), then watch a configured staging directory
// for the resulting download. User picks the file when it appears.
//
// This is the escape hatch for hostile hosts (captcha walls, ad-locks)
// that we explicitly choose not to bypass.

const std = @import("std");
const errs = @import("../errors.zig");
const dom = @import("../domain.zig");
const Handler = @import("../handler.zig").Handler;

const Self = @This();
alloc: std.mem.Allocator,
staging_dir: []const u8,

pub fn create(alloc: std.mem.Allocator, staging_dir: []const u8) !Handler {
    const self = try alloc.create(Self);
    self.* = .{ .alloc = alloc, .staging_dir = staging_dir };
    // Priority 255 — last-ditch fallback; only matched when nothing
    // else takes the URL.
    return .{ .ptr = self, .priority = 255, .vtable = &vtable };
}

fn canHandle(_: *anyopaque, _: []const u8) bool {
    // Always last in the dispatch chain; only matched if everything else
    // declines. Callers should register this handler last.
    return true;
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
