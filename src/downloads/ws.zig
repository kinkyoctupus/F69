//! WebSocket transport for aria2 JSON-RPC (karlseguin/websocket.zig).
//!
//! aria2 multiplexes responses and push notifications on one socket, so a
//! background read-loop thread classifies each frame: notifications
//! (onDownloadComplete/…) go to an event queue the manager drains; responses
//! go to the single waiting caller. Calls are serialized (one in-flight at a
//! time) which makes correlation trivial — the next response after our send
//! is ours — and avoids per-id bookkeeping. aria2 RPC is low-frequency and
//! the manager calls sequentially, so serialization costs nothing.

const std = @import("std");
const websocket = @import("websocket");
const transport = @import("transport.zig");
const rpc = @import("rpc.zig");

pub const Client = websocket.Client;

pub const Endpoint = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
    path: []const u8 = "/jsonrpc",
};

/// How long `call` waits for a response before giving up (and letting the
/// Fallback count a failure).
const CALL_TIMEOUT_NS: u64 = 8 * std.time.ns_per_s;

pub const WsTransport = struct {
    gpa: std.mem.Allocator,
    client: Client,
    thread: ?std.Thread = null,
    connected: std.atomic.Value(bool),

    // Serializes call() so the next response frame is unambiguously ours.
    call_mu: std.Thread.Mutex = .{},

    // Response handoff from the read thread to the waiting caller.
    resp_mu: std.Thread.Mutex = .{},
    resp_cv: std.Thread.Condition = .{},
    awaiting: bool = false,
    resp: ?[]u8 = null, // owned by gpa

    // Pushed events, drained by the manager.
    ev_mu: std.Thread.Mutex = .{},
    events: std.ArrayList(transport.Event) = .empty,

    const Handler = struct {
        t: *WsTransport,
        pub fn serverMessage(self: Handler, data: []u8) !void {
            self.t.onMessage(data);
        }
        pub fn close(self: Handler) void {
            self.t.connected.store(false, .release);
        }
    };

    /// Connect + handshake. On success the caller MUST place the struct at a
    /// stable address and call `start` (the read thread holds a `*WsTransport`).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, ep: Endpoint) transport.Error!WsTransport {
        var client = Client.init(io, gpa, .{
            .host = ep.host,
            .port = ep.port,
            .tls = false,
        }) catch return transport.Error.ConnectFailed;
        errdefer client.deinit();
        client.handshake(ep.path, .{ .timeout_ms = 5000 }) catch return transport.Error.ConnectFailed;
        return .{
            .gpa = gpa,
            .client = client,
            .connected = std.atomic.Value(bool).init(true),
        };
    }

    /// Spawn the read-loop thread. Call once, after the struct is at its
    /// final address.
    pub fn start(self: *WsTransport) transport.Error!void {
        self.thread = self.client.readLoopInNewThread(Handler{ .t = self }) catch
            return transport.Error.ConnectFailed;
    }

    pub fn deinit(self: *WsTransport) void {
        self.connected.store(false, .release);
        self.client.close(.{}) catch {};
        if (self.thread) |t| t.join();
        self.thread = null;
        self.ev_mu.lock();
        for (self.events.items) |e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.ev_mu.unlock();
        if (self.resp) |r| self.gpa.free(r);
        self.client.deinit();
    }

    pub fn asTransport(self: *WsTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = transport.VTable{
        .call = callFn,
        .drainEvents = drainFn,
        .healthy = healthyFn,
        .close = closeFn,
    };

    // --- read-thread side ---

    fn onMessage(self: *WsTransport, data: []u8) void {
        // Notification? (has method, no id.) Push to the event queue.
        if (rpc.parseNotification(self.gpa, data)) |n| {
            self.ev_mu.lock();
            defer self.ev_mu.unlock();
            self.events.append(self.gpa, .{ .method = n.method, .gid = n.gid }) catch {
                self.gpa.free(n.method);
                self.gpa.free(n.gid);
            };
            return;
        }
        // Otherwise it's a response — hand it to the waiting caller.
        self.resp_mu.lock();
        defer self.resp_mu.unlock();
        if (self.awaiting) {
            self.resp = self.gpa.dupe(u8, data) catch null;
            self.awaiting = false;
            self.resp_cv.signal();
        }
        // Not awaiting → stray/late response; drop it.
    }

    // --- caller side (vtable) ---

    fn callFn(ctx: *anyopaque, alloc: std.mem.Allocator, body: []const u8) transport.Error![]u8 {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (!self.connected.load(.acquire)) return transport.Error.NotConnected;

        self.call_mu.lock();
        defer self.call_mu.unlock();

        self.resp_mu.lock();
        if (self.resp) |r| {
            self.gpa.free(r);
            self.resp = null;
        }
        self.awaiting = true;
        self.resp_mu.unlock();

        // writeText masks the payload in place — send a writable copy so we
        // never mutate the caller's buffer.
        const wbuf = self.gpa.dupe(u8, body) catch return transport.Error.OutOfMemory;
        defer self.gpa.free(wbuf);
        self.client.writeText(wbuf) catch {
            self.connected.store(false, .release);
            self.resp_mu.lock();
            self.awaiting = false;
            self.resp_mu.unlock();
            return transport.Error.CallFailed;
        };

        self.resp_mu.lock();
        defer self.resp_mu.unlock();
        while (self.awaiting) {
            self.resp_cv.timedWait(&self.resp_mu, CALL_TIMEOUT_NS) catch {
                self.awaiting = false;
                return transport.Error.CallFailed;
            };
        }
        const r = self.resp orelse return transport.Error.CallFailed;
        self.resp = null;
        const out = alloc.dupe(u8, r) catch {
            self.gpa.free(r);
            return transport.Error.OutOfMemory;
        };
        self.gpa.free(r);
        return out;
    }

    fn drainFn(ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList(transport.Event)) void {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        self.ev_mu.lock();
        defer self.ev_mu.unlock();
        for (self.events.items) |e| {
            const m = alloc.dupe(u8, e.method) catch {
                e.deinit(self.gpa);
                continue;
            };
            const g = alloc.dupe(u8, e.gid) catch {
                alloc.free(m);
                e.deinit(self.gpa);
                continue;
            };
            out.append(alloc, .{ .method = m, .gid = g }) catch {
                alloc.free(m);
                alloc.free(g);
            };
            e.deinit(self.gpa);
        }
        self.events.clearRetainingCapacity();
    }

    fn healthyFn(ctx: *anyopaque) bool {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        return self.connected.load(.acquire);
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        self.connected.store(false, .release);
    }
};

test "ws module compiles and exposes the transport surface" {
    try std.testing.expect(@hasDecl(WsTransport, "asTransport"));
    try std.testing.expect(@hasDecl(Client, "writeText"));
}
