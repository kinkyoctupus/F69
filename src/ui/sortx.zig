// Multi-key, direction-aware sort over an index permutation.
//
// Pure module (no dvui). The library column system supplies a list of
// per-column comparators (`Key(Game)`); this sorts a `[]u32` index list
// rather than moving rows — the perf "index permutation" from the rework.
// Sorts are made total (deterministic) via an original-index tiebreak.

const std = @import("std");

pub const Dir = enum { asc, desc };

pub fn Key(comptime T: type) type {
    return struct {
        cmp: *const fn (a: T, b: T) std.math.Order,
        dir: Dir = .asc,
    };
}

/// Fill `order` with `0..items.len` then sort it by `keys` (in priority order),
/// breaking remaining ties by original index so the result is fully deterministic.
/// `order.len` must equal `items.len`.
pub fn sortIndices(comptime T: type, items: []const T, order: []u32, keys: []const Key(T)) void {
    std.debug.assert(order.len == items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        items: []const T,
        keys: []const Key(T),
        fn less(c: @This(), ia: u32, ib: u32) bool {
            for (c.keys) |k| {
                var ord = k.cmp(c.items[ia], c.items[ib]);
                if (k.dir == .desc) ord = ord.invert();
                if (ord != .eq) return ord == .lt;
            }
            return ia < ib;
        }
    };
    std.sort.pdq(u32, order, Ctx{ .items = items, .keys = keys }, Ctx.less);
}

const Row = struct { name: []const u8, rating: i32 };
fn cmpName(a: Row, b: Row) std.math.Order {
    return std.mem.order(u8, a.name, b.name);
}
fn cmpRating(a: Row, b: Row) std.math.Order {
    return std.math.order(a.rating, b.rating);
}

test "sortIndices: rating desc, then name asc, then original-index tiebreak" {
    const rows = [_]Row{
        .{ .name = "b", .rating = 5 },
        .{ .name = "a", .rating = 5 },
        .{ .name = "c", .rating = 9 },
        .{ .name = "a", .rating = 5 },
    };
    var order: [4]u32 = undefined;
    const keys = [_]Key(Row){
        .{ .cmp = cmpRating, .dir = .desc },
        .{ .cmp = cmpName, .dir = .asc },
    };
    sortIndices(Row, &rows, &order, &keys);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1, 3, 0 }, &order);
}

test "sortIndices with no keys is identity order" {
    const rows = [_]Row{ .{ .name = "x", .rating = 1 }, .{ .name = "y", .rating = 2 } };
    var order: [2]u32 = undefined;
    sortIndices(Row, &rows, &order, &.{});
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, &order);
}
