// Single-producer / single-consumer ring buffer. The worker thread writes
// progress events; the UI thread drains the ring once per frame.
//
// Capacity is a comptime power-of-two so masking replaces modulo. Head
// and tail are atomic, cache-line padded to avoid false sharing.

const std = @import("std");

pub fn Ring(comptime T: type, comptime cap: comptime_int) type {
    if (cap == 0 or (cap & (cap - 1)) != 0) @compileError("Ring capacity must be a non-zero power of two");
    const mask: usize = cap - 1;

    return struct {
        const Self = @This();

        buf: [cap]T = undefined,
        head: std.atomic.Value(usize) align(64) = .init(0), // producer-only writer
        tail: std.atomic.Value(usize) align(64) = .init(0), // consumer-only writer

        /// Producer side. Returns false if the ring is full.
        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head - tail == cap) return false; // full
            self.buf[head & mask] = item;
            self.head.store(head + 1, .release);
            return true;
        }

        /// Consumer side. Returns null if the ring is empty.
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (head == tail) return null; // empty
            const item = self.buf[tail & mask];
            self.tail.store(tail + 1, .release);
            return item;
        }

        pub fn count(self: *const Self) usize {
            return self.head.load(.acquire) - self.tail.load(.acquire);
        }
    };
}

test "spsc ring single-thread basic" {
    var r: Ring(u32, 4) = .{};
    try std.testing.expect(r.pop() == null);
    try std.testing.expect(r.push(1));
    try std.testing.expect(r.push(2));
    try std.testing.expectEqual(@as(usize, 2), r.count());
    try std.testing.expectEqual(@as(?u32, 1), r.pop());
    try std.testing.expectEqual(@as(?u32, 2), r.pop());
    try std.testing.expect(r.pop() == null);
}

test "spsc ring fills and rejects" {
    var r: Ring(u32, 2) = .{};
    try std.testing.expect(r.push(1));
    try std.testing.expect(r.push(2));
    try std.testing.expect(!r.push(3)); // full
}
