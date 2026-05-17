// Kahn's algorithm — topological sort with cycle detection. Used by
// the resolver to compute mod load order from `load_after` /
// `load_before` constraints.

const std = @import("std");

pub const Error = error{ CycleDetected, OutOfMemory };

pub const Edge = struct { from: []const u8, to: []const u8 };

/// Sort `nodes` so that every edge `(from, to)` places `from` before
/// `to` in the output. Returns `CycleDetected` when the constraints
/// can't be satisfied. Allocator-owned slice; caller frees.
///
/// Each input slice (nodes + edges) is borrowed for the duration of
/// the call; nothing from `alloc` is allocated for those — only the
/// output slice is.
pub fn sort(
    alloc: std.mem.Allocator,
    nodes: []const []const u8,
    edges: []const Edge,
) Error![]const []const u8 {
    // In-degree per node (by name). Use a side array indexed in lockstep
    // with `nodes` to avoid a hashmap allocation.
    const in_deg = try alloc.alloc(u32, nodes.len);
    defer alloc.free(in_deg);
    @memset(in_deg, 0);

    for (edges) |e| {
        if (indexOf(nodes, e.to)) |i| in_deg[i] += 1;
    }

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(alloc);
    for (nodes, 0..) |_, i| {
        if (in_deg[i] == 0) try queue.append(alloc, i);
    }

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);

    // Mutable copy of in_deg so the original is reusable if caller
    // re-runs with different edges (current callers don't, but cheap).
    while (queue.items.len > 0) {
        const idx = queue.orderedRemove(0);
        try out.append(alloc, nodes[idx]);

        // Walk every edge sourced from this node and decrement targets.
        for (edges) |e| {
            if (!std.mem.eql(u8, e.from, nodes[idx])) continue;
            const ti = indexOf(nodes, e.to) orelse continue;
            if (in_deg[ti] > 0) {
                in_deg[ti] -= 1;
                if (in_deg[ti] == 0) try queue.append(alloc, ti);
            }
        }
    }

    if (out.items.len < nodes.len) return Error.CycleDetected;
    return out.toOwnedSlice(alloc);
}

fn indexOf(nodes: []const []const u8, name: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

test "sort: empty" {
    const out = try sort(testing.allocator, &.{}, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "sort: single node, no edges" {
    const out = try sort(testing.allocator, &.{"a"}, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("a", out[0]);
}

test "sort: linear A→B→C" {
    const out = try sort(testing.allocator, &.{ "a", "b", "c" }, &.{
        .{ .from = "a", .to = "b" },
        .{ .from = "b", .to = "c" },
    });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("b", out[1]);
    try testing.expectEqualStrings("c", out[2]);
}

test "sort: cycle detected" {
    const out_or = sort(testing.allocator, &.{ "a", "b" }, &.{
        .{ .from = "a", .to = "b" },
        .{ .from = "b", .to = "a" },
    });
    try testing.expectError(Error.CycleDetected, out_or);
}

test "sort: edge to unknown node is ignored" {
    // `to` not in nodes — kahn just skips that constraint.
    const out = try sort(testing.allocator, &.{ "a", "b" }, &.{
        .{ .from = "a", .to = "ghost" },
    });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "sort: diamond" {
    // a → b, a → c, b → d, c → d. Valid orders: a-b-c-d or a-c-b-d.
    const out = try sort(testing.allocator, &.{ "a", "b", "c", "d" }, &.{
        .{ .from = "a", .to = "b" },
        .{ .from = "a", .to = "c" },
        .{ .from = "b", .to = "d" },
        .{ .from = "c", .to = "d" },
    });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("d", out[3]);
}
