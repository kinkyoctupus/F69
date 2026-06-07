//! HTTP transport for aria2 JSON-RPC — the fallback (and simplest) impl of
//! `transport.Transport`. POSTs the request body to the daemon's
//! `http://127.0.0.1:<port>/jsonrpc` and returns the response body. aria2
//! has no push channel over HTTP, so `drainEvents` is a no-op — the manager
//! gets state from batch polling (`tellActive`/`tellStopped`) on tick.
//!
//! Reuses `util_http.fetch`, whose per-host limiter explicitly bypasses
//! loopback, so RPC isn't throttled.

const std = @import("std");
const transport = @import("transport.zig");
const http = @import("util_http");

pub const HttpTransport = struct {
    io: std.Io,
    /// "http://127.0.0.1:<port>/jsonrpc" — borrowed, outlives the transport.
    url: []const u8,
    alive: bool = true,

    const json_headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    pub fn asTransport(self: *HttpTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = transport.VTable{
        .call = callFn,
        .drainEvents = drainFn,
        .healthy = healthyFn,
        .close = closeFn,
    };

    fn callFn(ctx: *anyopaque, alloc: std.mem.Allocator, body: []const u8) transport.Error![]u8 {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        const resp = http.fetch(alloc, self.io, self.url, .{
            .method = .POST,
            .payload = body,
            .extra_headers = &json_headers,
        }) catch {
            self.alive = false;
            return transport.Error.CallFailed;
        };
        if (resp.status < 200 or resp.status >= 300) {
            alloc.free(resp.body);
            return transport.Error.CallFailed;
        }
        self.alive = true;
        return resp.body;
    }

    /// HTTP has no push channel — state comes from polling.
    fn drainFn(_: *anyopaque, _: std.mem.Allocator, _: *std.ArrayList(transport.Event)) void {}

    fn healthyFn(ctx: *anyopaque) bool {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        return self.alive;
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        self.alive = false;
    }
};

test "HttpTransport exposes a Transport vtable" {
    var t = HttpTransport{ .io = undefined, .url = "http://127.0.0.1:6800/jsonrpc" };
    const tr = t.asTransport();
    try std.testing.expect(tr.healthy());
}
