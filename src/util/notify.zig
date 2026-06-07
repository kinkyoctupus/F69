//! Desktop notifications. The message formatting is pure (testable); the
//! sender shells out to `notify-send` (Linux/libnotify) best-effort — a
//! missing binary or a headless session is a silent no-op, never an error.
//!
//! Wired into the end-of-sync recap: when a sync batch finds updates, the UI
//! fires one summary notification (gated by a user setting).

const std = @import("std");
const builtin = @import("builtin");

/// Notification title, e.g. "3 games updated". Caller-owned buffer.
pub fn updateSummary(buf: []u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d} game{s} updated", .{
        count,
        if (count == 1) "" else "s",
    }) catch "Updates available";
}

/// Notification body — the first game's name, plus "and N more" when the
/// batch carried several. Caller-owned buffer.
pub fn updateBody(buf: []u8, first_name: []const u8, count: usize) []const u8 {
    if (count <= 1) return std.fmt.bufPrint(buf, "{s}", .{first_name}) catch first_name;
    return std.fmt.bufPrint(buf, "{s} and {d} more", .{ first_name, count - 1 }) catch first_name;
}

/// Fire a desktop notification via `notify-send`. Best-effort: any failure
/// (binary absent, headless, spawn error) is swallowed. No-op off Linux.
pub fn send(io: std.Io, summary: []const u8, body: []const u8) void {
    if (builtin.os.tag != .linux) return;
    var child = std.process.spawn(io, .{
        .argv = &.{ "notify-send", "-a", "f69", summary, body },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // notify-send returns immediately after handing the message to the
    // daemon; reap it so we don't leak a zombie.
    _ = child.wait(io) catch {};
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "updateSummary pluralizes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1 game updated", updateSummary(&buf, 1));
    try testing.expectEqualStrings("3 games updated", updateSummary(&buf, 3));
}

test "updateBody collapses extras into 'and N more'" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Game X", updateBody(&buf, "Game X", 1));
    try testing.expectEqualStrings("Game X and 2 more", updateBody(&buf, "Game X", 3));
}
