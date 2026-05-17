// aria2c daemon wrapper. **RPC mode**, not stdout parsing — architect
// review (2026-05-08).
//
// Lifecycle:
//   1. Spawn `aria2c --enable-rpc --rpc-listen-all=false
//      --rpc-listen-port=<random> --rpc-secret=<token> --daemon=true`.
//      Random port + secret prevents other local users from driving the
//      daemon.
//   2. Send JSON-RPC over HTTP to localhost:<port>:
//      - `aria2.addUri([url], options)` → returns gid
//      - `aria2.tellStatus(gid)` → progress polling, or
//      - `aria2.onDownloadComplete` notification (websocket variant)
//   3. On manager shutdown: `aria2.shutdown` → daemon exits cleanly.
//
// Why RPC over stdout: documented protocol, pause/resume/cancel, multi-
// download mux, version-stable across aria2 releases.
//
// Handles: http(s), ftp, magnet, .torrent. Priority 50 (catch-all but
// below host-specific handlers).

const std = @import("std");
const errs = @import("../errors.zig");
const dom = @import("../domain.zig");
const Handler = @import("../handler.zig").Handler;

const Self = @This();

alloc: std.mem.Allocator,
aria2_path: []const u8, // resolved exe path
rpc_port: u16 = 0, // assigned on spawn
rpc_secret: []const u8 = "", // generated on spawn
daemon_pid: ?i32 = null,

pub fn create(alloc: std.mem.Allocator, aria2_path: []const u8, rpc_secret: []const u8) !Handler {
    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .aria2_path = aria2_path,
        .rpc_secret = rpc_secret,
    };
    // Priority 50 — catch-all for http/https/ftp/magnet/torrent. Host-
    // specific handlers (rpdl, mega, mediafire, ...) sit at 10–20 and
    // are checked first.
    return .{ .ptr = self, .priority = 50, .vtable = &vtable };
}

/// Spawn the daemon on first download. TODO: idempotent + cleanup on deinit.
fn ensureDaemon(self: *Self) errs.Error!void {
    _ = self;
}

fn canHandle(_: *anyopaque, url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "ftp://") or
        std.mem.startsWith(u8, url, "magnet:") or
        std.mem.endsWith(u8, url, ".torrent");
}

fn download(ptr: *anyopaque, job: *dom.Job) errs.Error!void {
    _ = ptr;
    _ = job;
    return errs.Error.HostUnreachable; // TODO: aria2.addUri RPC + tellStatus poll
}

fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    // TODO: send aria2.shutdown to daemon, wait for exit.
    alloc.destroy(self);
}

const vtable = Handler.VTable{
    .canHandle = canHandle,
    .download = download,
    .deinit = deinit,
};
