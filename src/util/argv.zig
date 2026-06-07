// Shell-free argv tokenizer for user-supplied launch commands.
//
// Splits a raw command string into argv tokens WITHOUT a shell: spaces split,
// '...'/"..." group, '\' escapes, and {install}/{exe} placeholders expand to a
// single token (so spaced paths stay one arg). Used by the per-game custom
// launch override (and the Windows launch path). No shell metachar evaluation.

const std = @import("std");

pub const Ctx = struct { install: []const u8 = "", exe: []const u8 = "" };

pub fn free(alloc: std.mem.Allocator, toks: [][]u8) void {
    for (toks) |t| alloc.free(t);
    alloc.free(toks);
}

fn starts(hay: []const u8, needle: []const u8) bool {
    return hay.len >= needle.len and std.mem.eql(u8, hay[0..needle.len], needle);
}

/// Tokenize `raw` into owned argv strings. Caller frees with `free`.
pub fn tokenize(alloc: std.mem.Allocator, raw: []const u8, ctx: Ctx) ![][]u8 {
    var toks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (toks.items) |t| alloc.free(t);
        toks.deinit(alloc);
    }
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(alloc);
    var has_token = false;
    var quote: ?u8 = null;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else if (c == '\\' and q == '"' and i + 1 < raw.len) {
                i += 1;
                try cur.append(alloc, raw[i]);
            } else {
                try cur.append(alloc, c);
            }
            has_token = true;
            continue;
        }
        switch (c) {
            ' ', '\t' => if (has_token) {
                try toks.append(alloc, try cur.toOwnedSlice(alloc));
                has_token = false;
            },
            '\'', '"' => {
                quote = c;
                has_token = true;
            },
            '\\' => if (i + 1 < raw.len) {
                i += 1;
                try cur.append(alloc, raw[i]);
                has_token = true;
            },
            '{' => {
                if (starts(raw[i..], "{install}")) {
                    try cur.appendSlice(alloc, ctx.install);
                    i += "{install}".len - 1;
                } else if (starts(raw[i..], "{exe}")) {
                    try cur.appendSlice(alloc, ctx.exe);
                    i += "{exe}".len - 1;
                } else {
                    try cur.append(alloc, c);
                }
                has_token = true;
            },
            else => {
                try cur.append(alloc, c);
                has_token = true;
            },
        }
    }
    if (has_token) try toks.append(alloc, try cur.toOwnedSlice(alloc));
    return toks.toOwnedSlice(alloc);
}

test "tokenize splits on whitespace" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "wine game.exe --fullscreen", .{});
    defer free(a, t);
    try std.testing.expectEqual(@as(usize, 3), t.len);
    try std.testing.expectEqualStrings("wine", t[0]);
    try std.testing.expectEqualStrings("game.exe", t[1]);
    try std.testing.expectEqualStrings("--fullscreen", t[2]);
}

test "tokenize groups quotes and preserves inner spaces" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "\"My Game/run.sh\" 'arg one'", .{});
    defer free(a, t);
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqualStrings("My Game/run.sh", t[0]);
    try std.testing.expectEqualStrings("arg one", t[1]);
}

test "tokenize expands placeholders without splitting spaced paths" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "wine {exe} --dir {install}", .{ .install = "/games/My Game", .exe = "g.exe" });
    defer free(a, t);
    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings("g.exe", t[1]);
    try std.testing.expectEqualStrings("/games/My Game", t[3]);
}

test "tokenize honors backslash escape and yields nothing for blank input" {
    const a = std.testing.allocator;
    const t = try tokenize(a, "a\\ b", .{});
    defer free(a, t);
    try std.testing.expectEqual(@as(usize, 1), t.len);
    try std.testing.expectEqualStrings("a b", t[0]);
    const e = try tokenize(a, "   ", .{});
    defer free(a, e);
    try std.testing.expectEqual(@as(usize, 0), e.len);
}
