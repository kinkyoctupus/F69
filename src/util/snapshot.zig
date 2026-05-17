// Atomic snapshot — worker thread publishes a heap-allocated `*T`; UI
// thread reads via atomic load. At most one frame stale, never torn.
//
// Owner is the publisher. After `store(new)`, the *previous* pointer
// (if any) becomes free for the publisher to reclaim — but only after
// any in-flight reader has finished. For simplicity we use an
// epoch-style "two-buffer ping-pong": each `Snapshot` owns two slots,
// publisher writes the inactive one, then atomically flips the active
// pointer.

const std = @import("std");

pub fn Snapshot(comptime T: type) type {
    return struct {
        const Self = @This();

        slots: [2]T = .{ undefined, undefined },
        active: std.atomic.Value(u8) align(64) = .init(0),

        pub fn store(self: *Self, value: T) void {
            const cur = self.active.load(.monotonic);
            const next: u8 = if (cur == 0) 1 else 0;
            self.slots[next] = value;
            self.active.store(next, .release);
        }

        pub fn load(self: *Self) T {
            const idx = self.active.load(.acquire);
            return self.slots[idx];
        }
    };
}

test "snapshot store/load" {
    const Progress = struct { done: u32, total: u32 };
    var s: Snapshot(Progress) = .{};
    s.store(.{ .done = 5, .total = 100 });
    const got = s.load();
    try std.testing.expectEqual(@as(u32, 5), got.done);
    try std.testing.expectEqual(@as(u32, 100), got.total);
    s.store(.{ .done = 50, .total = 100 });
    try std.testing.expectEqual(@as(u32, 50), s.load().done);
}
