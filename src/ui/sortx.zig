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

/// A memoized filtered+sorted index permutation over a row slice — the perf +
/// stability keystone. Rows are never moved; the view recomputes only when the
/// input generation or the filter/sort signature changes. `order`/`filtered`
/// are caller-owned scratch buffers of length ≥ rows.len.
pub fn View(comptime T: type) type {
    return struct {
        order: []u32,
        filtered: []u32,
        filtered_len: usize = 0,
        gen: u64 = 0,
        sig: u64 = 0,
        computed: bool = false,
        recomputes: u64 = 0,

        const Self = @This();

        /// `gen` bumps when the row slice is rebuilt (reload); `sig` is the
        /// filter/sort-input signature. `pred(ctx, row)` keeps a row when true.
        pub fn ensure(
            self: *Self,
            rows: []const T,
            gen: u64,
            sig: u64,
            keys: []const Key(T),
            ctx: anytype,
            comptime pred: fn (@TypeOf(ctx), T) bool,
        ) void {
            if (self.computed and self.gen == gen and self.sig == sig) return;
            sortIndices(T, rows, self.order[0..rows.len], keys);
            var n: usize = 0;
            for (self.order[0..rows.len]) |idx| {
                if (pred(ctx, rows[idx])) {
                    self.filtered[n] = idx;
                    n += 1;
                }
            }
            self.filtered_len = n;
            self.gen = gen;
            self.sig = sig;
            self.computed = true;
            self.recomputes += 1;
        }

        /// The current filtered+sorted indices into the row slice.
        pub fn items(self: Self) []const u32 {
            return self.filtered[0..self.filtered_len];
        }
    };
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

const Keep = struct { min: i32 };
fn keep(p: Keep, r: Row) bool {
    return r.rating >= p.min;
}

test "View filters+sorts into a permutation and memoizes on (gen,sig)" {
    const rows = [_]Row{ .{ .name = "a", .rating = 3 }, .{ .name = "b", .rating = 9 }, .{ .name = "c", .rating = 5 } };
    var ord: [3]u32 = undefined;
    var filt: [3]u32 = undefined;
    var v = View(Row){ .order = &ord, .filtered = &filt };
    const keys = [_]Key(Row){.{ .cmp = cmpRating, .dir = .desc }};

    v.ensure(&rows, 1, 100, &keys, Keep{ .min = 5 }, keep);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, v.items()); // b(9), c(5)
    try std.testing.expectEqual(@as(u64, 1), v.recomputes);

    v.ensure(&rows, 1, 100, &keys, Keep{ .min = 5 }, keep); // unchanged → memoized
    try std.testing.expectEqual(@as(u64, 1), v.recomputes);

    v.ensure(&rows, 1, 200, &keys, Keep{ .min = 5 }, keep); // sig changed → recompute
    try std.testing.expectEqual(@as(u64, 2), v.recomputes);

    v.ensure(&rows, 2, 200, &keys, Keep{ .min = 5 }, keep); // gen changed → recompute
    try std.testing.expectEqual(@as(u64, 3), v.recomputes);
}
