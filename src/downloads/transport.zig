//! Transport abstraction for aria2 JSON-RPC. The manager/daemon talk to a
//! `Transport` vtable; concrete impls are `ws.zig` (WebSocket, push events)
//! and `http.zig` (batch polling). `Fallback` composes two transports and
//! auto-switches primary→secondary after repeated failures — that's the
//! "use WebSocket, fall back to HTTP if it breaks" decision, isolated here
//! so it's unit-testable with fakes (the real transports are IO).

const std = @import("std");

pub const Error = error{ ConnectFailed, CallFailed, NotConnected, OutOfMemory };

/// A pushed aria2 event (WS transports produce these; HTTP yields none).
/// Strings owned by the allocator passed to `drainEvents`.
pub const Event = struct {
    method: []u8,
    gid: []u8,

    pub fn deinit(self: Event, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.gid);
    }
};

pub const VTable = struct {
    /// Send a JSON-RPC body, return the response body (owned by `alloc`).
    call: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, body: []const u8) Error![]u8,
    /// Append any buffered push events. No-op for HTTP. Caller owns events.
    drainEvents: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList(Event)) void,
    /// Is the transport currently usable?
    healthy: *const fn (ctx: *anyopaque) bool,
    close: *const fn (ctx: *anyopaque) void,
};

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn call(self: Transport, alloc: std.mem.Allocator, body: []const u8) Error![]u8 {
        return self.vtable.call(self.ctx, alloc, body);
    }
    pub fn drainEvents(self: Transport, alloc: std.mem.Allocator, out: *std.ArrayList(Event)) void {
        self.vtable.drainEvents(self.ctx, alloc, out);
    }
    pub fn healthy(self: Transport) bool {
        return self.vtable.healthy(self.ctx);
    }
    pub fn close(self: Transport) void {
        self.vtable.close(self.ctx);
    }
};

/// Routes calls to `primary` until it fails `threshold` times in a row, then
/// permanently switches to `secondary`. A failing call still gets retried on
/// `secondary` before returning, so the switch never drops a request.
pub const Fallback = struct {
    primary: Transport,
    secondary: Transport,
    threshold: u8 = 3,
    fail_count: u8 = 0,
    on_secondary: bool = false,
    /// Set true the moment we switch — lets the manager log it once.
    just_switched: bool = false,

    pub fn call(self: *Fallback, alloc: std.mem.Allocator, body: []const u8) Error![]u8 {
        if (!self.on_secondary) {
            if (self.primary.call(alloc, body)) |resp| {
                self.fail_count = 0;
                return resp;
            } else |_| {
                self.fail_count += 1;
                if (self.fail_count >= self.threshold) {
                    self.on_secondary = true;
                    self.just_switched = true;
                }
                // Fall through: serve this call from the secondary so the
                // failure doesn't propagate to the caller.
            }
        }
        return self.secondary.call(alloc, body);
    }

    pub fn active(self: *Fallback) Transport {
        return if (self.on_secondary) self.secondary else self.primary;
    }

    pub fn drainEvents(self: *Fallback, alloc: std.mem.Allocator, out: *std.ArrayList(Event)) void {
        self.active().drainEvents(alloc, out);
    }

    pub fn close(self: *Fallback) void {
        self.primary.close();
        self.secondary.close();
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

/// In-memory fake transport for testing routing/fallback without IO.
const FakeT = struct {
    label: []const u8,
    fail: bool = false,
    calls: usize = 0,

    fn doCall(ctx: *anyopaque, alloc: std.mem.Allocator, body: []const u8) Error![]u8 {
        _ = body;
        const self: *FakeT = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail) return Error.CallFailed;
        return alloc.dupe(u8, self.label);
    }
    fn drain(_: *anyopaque, _: std.mem.Allocator, _: *std.ArrayList(Event)) void {}
    fn healthyFn(ctx: *anyopaque) bool {
        const self: *FakeT = @ptrCast(@alignCast(ctx));
        return !self.fail;
    }
    fn closeFn(_: *anyopaque) void {}

    const vtable = VTable{ .call = doCall, .drainEvents = drain, .healthy = healthyFn, .close = closeFn };
    fn transport(self: *FakeT) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "Fallback stays on primary while it succeeds" {
    var p = FakeT{ .label = "primary" };
    var s = FakeT{ .label = "secondary" };
    var fb = Fallback{ .primary = p.transport(), .secondary = s.transport() };

    const r = try fb.call(testing.allocator, "x");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("primary", r);
    try testing.expect(!fb.on_secondary);
    try testing.expectEqual(@as(usize, 0), s.calls);
}

test "Fallback switches to secondary after threshold consecutive failures" {
    var p = FakeT{ .label = "primary", .fail = true };
    var s = FakeT{ .label = "secondary" };
    var fb = Fallback{ .primary = p.transport(), .secondary = s.transport(), .threshold = 3 };

    // Each failing call is served by the secondary; after 3 failures we pin it.
    for (0..3) |_| {
        const r = try fb.call(testing.allocator, "x");
        testing.allocator.free(r);
    }
    try testing.expect(fb.on_secondary);
    try testing.expect(fb.just_switched);

    // Now pinned: primary is no longer even attempted.
    const before = p.calls;
    const r = try fb.call(testing.allocator, "x");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("secondary", r);
    try testing.expectEqual(before, p.calls);
}

test "Fallback resets the failure streak on a primary success" {
    var p = FakeT{ .label = "primary" };
    var s = FakeT{ .label = "secondary" };
    var fb = Fallback{ .primary = p.transport(), .secondary = s.transport(), .threshold = 3 };

    p.fail = true;
    testing.allocator.free(try fb.call(testing.allocator, "x")); // fail 1
    testing.allocator.free(try fb.call(testing.allocator, "x")); // fail 2
    p.fail = false;
    testing.allocator.free(try fb.call(testing.allocator, "x")); // success → reset
    try testing.expectEqual(@as(u8, 0), fb.fail_count);
    try testing.expect(!fb.on_secondary);
}
