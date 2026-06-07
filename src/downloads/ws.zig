//! WebSocket transport for aria2 JSON-RPC (karlseguin/websocket.zig).
//!
//! aria2 multiplexes responses and push notifications on one socket, so a
//! background read-loop thread classifies each frame: notifications
//! (onDownloadComplete/…) go to an event queue the manager drains; responses
//! go to the single waiting caller. Calls are assumed serialized by the
//! caller (the manager drives RPC from one thread), so correlation is
//! trivial — the next response is ours.
//!
//! Sync note: this Zig has no `std.Thread.Mutex`; `std.Io.Mutex` needs an
//! `io` (awkward across karlseguin's raw read thread and the io-less
//! `drainEvents` vtable). So we use a tiny atomic spinlock for the brief
//! critical sections, and the caller polls with `io.sleep` for its response.

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

/// How long `call` waits for a response before giving up (Fallback then
/// counts a failure). Polled in `POLL_MS` steps.
const CALL_TIMEOUT_MS: u64 = 8000;
const POLL_MS: u64 = 5;

/// Minimal atomic spinlock — critical sections here are a few instructions
/// (append/swap a pointer), so spinning never meaningfully blocks.
const Spin = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Spin) void {
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *Spin) void {
        self.flag.store(false, .release);
    }
};

pub const WsTransport = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: Client,
    thread: ?std.Thread = null,
    connected: std.atomic.Value(bool),

    // Response handoff (read thread → caller). Guarded by resp_lock.
    resp_lock: Spin = .{},
    awaiting: bool = false,
    resp_ready: bool = false,
    resp: ?[]u8 = null, // owned by gpa

    // Pushed events, drained by the manager. Guarded by ev_lock.
    ev_lock: Spin = .{},
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
            .io = io,
            .client = client,
            .connected = std.atomic.Value(bool).init(true),
        };
    }

    /// Spawn the read-loop thread. Call once, after the struct is at its
    /// final (heap) address.
    pub fn start(self: *WsTransport) transport.Error!void {
        self.thread = self.client.readLoopInNewThread(Handler{ .t = self }) catch
            return transport.Error.ConnectFailed;
    }

    pub fn deinit(self: *WsTransport) void {
        self.connected.store(false, .release);
        self.client.close(.{}) catch {};
        if (self.thread) |t| t.join();
        self.thread = null;

        self.ev_lock.lock();
        for (self.events.items) |e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.ev_lock.unlock();

        self.resp_lock.lock();
        if (self.resp) |r| self.gpa.free(r);
        self.resp = null;
        self.resp_lock.unlock();

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
            self.ev_lock.lock();
            defer self.ev_lock.unlock();
            self.events.append(self.gpa, .{ .method = n.method, .gid = n.gid }) catch {
                self.gpa.free(n.method);
                self.gpa.free(n.gid);
            };
            return;
        }
        // Otherwise it's a response — hand it to the waiting caller.
        self.resp_lock.lock();
        defer self.resp_lock.unlock();
        if (self.awaiting and !self.resp_ready) {
            self.resp = self.gpa.dupe(u8, data) catch null;
            self.resp_ready = true;
        }
        // Not awaiting → stray/late response; drop it.
    }

    // --- caller side (vtable) ---

    fn callFn(ctx: *anyopaque, alloc: std.mem.Allocator, body: []const u8) transport.Error![]u8 {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (!self.connected.load(.acquire)) return transport.Error.NotConnected;

        // Arm the response slot.
        self.resp_lock.lock();
        if (self.resp) |r| self.gpa.free(r);
        self.resp = null;
        self.resp_ready = false;
        self.awaiting = true;
        self.resp_lock.unlock();

        // writeText masks the payload in place — send a writable copy.
        const wbuf = self.gpa.dupe(u8, body) catch return transport.Error.OutOfMemory;
        defer self.gpa.free(wbuf);
        self.client.writeText(wbuf) catch {
            self.connected.store(false, .release);
            self.disarm();
            return transport.Error.CallFailed;
        };

        // Poll for the response (the read thread fills it).
        var waited: u64 = 0;
        while (waited < CALL_TIMEOUT_MS) : (waited += POLL_MS) {
            self.resp_lock.lock();
            if (self.resp_ready) {
                const r = self.resp;
                self.resp = null;
                self.resp_ready = false;
                self.awaiting = false;
                self.resp_lock.unlock();
                const taken = r orelse return transport.Error.CallFailed;
                defer self.gpa.free(taken);
                return alloc.dupe(u8, taken) catch transport.Error.OutOfMemory;
            }
            self.resp_lock.unlock();
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(POLL_MS), .awake) catch {};
        }
        self.disarm();
        return transport.Error.CallFailed;
    }

    fn disarm(self: *WsTransport) void {
        self.resp_lock.lock();
        self.awaiting = false;
        if (self.resp) |r| {
            self.gpa.free(r);
            self.resp = null;
        }
        self.resp_ready = false;
        self.resp_lock.unlock();
    }

    fn drainFn(ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList(transport.Event)) void {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        self.ev_lock.lock();
        defer self.ev_lock.unlock();
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
