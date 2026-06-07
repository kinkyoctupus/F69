// Compact relative-time formatting ("just now", "5m", "2d", "3w", "4mo", "2y").
// Pure; used by the library list (Last update / Last played) + downloads.

const std = @import("std");

fn unit(buf: []u8, v: i64, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}{s}", .{ v, suffix }) catch unreachable;
}

/// Render `then_s` relative to `now_s` (both unix seconds) into `buf`.
/// `then_s <= 0` → "never"; under a minute → "just now".
pub fn ago(now_s: i64, then_s: i64, buf: []u8) []const u8 {
    if (then_s <= 0) return "never";
    const d = now_s - then_s;
    if (d < 60) return "just now";
    if (d < 3600) return unit(buf, @divFloor(d, 60), "m");
    if (d < 86400) return unit(buf, @divFloor(d, 3600), "h");
    if (d < 604800) return unit(buf, @divFloor(d, 86400), "d");
    if (d < 2592000) return unit(buf, @divFloor(d, 604800), "w");
    if (d < 31536000) return unit(buf, @divFloor(d, 2592000), "mo");
    return unit(buf, @divFloor(d, 31536000), "y");
}

test "ago formats common ranges and handles missing timestamps" {
    var b: [16]u8 = undefined;
    const now: i64 = 1_000_000_000;
    try std.testing.expectEqualStrings("never", ago(now, 0, &b));
    try std.testing.expectEqualStrings("just now", ago(now, now - 10, &b));
    try std.testing.expectEqualStrings("5m", ago(now, now - 5 * 60, &b));
    try std.testing.expectEqualStrings("3h", ago(now, now - 3 * 3600, &b));
    try std.testing.expectEqualStrings("2d", ago(now, now - 2 * 86400, &b));
    try std.testing.expectEqualStrings("3w", ago(now, now - 3 * 7 * 86400, &b));
    try std.testing.expectEqualStrings("4mo", ago(now, now - 4 * 30 * 86400, &b));
    try std.testing.expectEqualStrings("2y", ago(now, now - 2 * 365 * 86400, &b));
}
