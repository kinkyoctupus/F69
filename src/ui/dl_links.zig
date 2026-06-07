//! Parsing + display helpers for a Game's `download_links` — each stored
//! as a tab-delimited `<host>\t<url>\t<label>` line (host = DownloadHost
//! `@tagName`, label optional). Pure (no dvui) so it's unit-testable; the
//! detail Downloads tab renders the result as a per-host mirror list.

const std = @import("std");
const tokens = @import("ui_tokens");

pub const Link = struct {
    /// DownloadHost tag string ("mega", "mediafire", …). Never owns memory —
    /// all three fields borrow the source entry.
    host: []const u8,
    url: []const u8,
    /// Free-text label from the OP ("Win/Linux", "v1.2 compressed", …).
    /// Empty when the line carried no label.
    label: []const u8,
};

/// Split one `host\turl\tlabel` entry. Missing trailing fields → "".
pub fn parse(entry: []const u8) Link {
    var it = std.mem.splitScalar(u8, entry, '\t');
    const host = it.next() orelse "";
    const url = it.next() orelse "";
    const label = it.next() orelse "";
    return .{ .host = host, .url = url, .label = label };
}

/// Pretty, brand-cased host name for the chip. Unknown tags pass through
/// verbatim so a host we don't special-case still shows something useful.
pub fn hostLabel(host: []const u8) []const u8 {
    const map = .{
        .{ "f95_attachment", "F95" },
        .{ "mega", "MEGA" },
        .{ "mediafire", "MediaFire" },
        .{ "gofile", "Gofile" },
        .{ "pixeldrain", "Pixeldrain" },
        .{ "workupload", "WorkUpload" },
        .{ "nopy", "NoPy" },
        .{ "zippyshare", "ZippyShare" },
        .{ "other", "Link" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, host, pair[0])) return pair[1];
    }
    return host;
}

/// Distinct accent per host so the mirror list reads at a glance. Loosely
/// brand-evocative (MEGA red, MediaFire blue, Gofile teal…).
pub fn hostColor(host: []const u8) tokens.Color {
    const C = tokens.Color;
    const map = .{
        .{ "f95_attachment", C{ .r = 0x2A, .g = 0x8A, .b = 0x82, .a = 0xff } }, // teal-grey (f95)
        .{ "mega", C{ .r = 0xD9, .g = 0x27, .b = 0x2C, .a = 0xff } }, // red
        .{ "mediafire", C{ .r = 0x1E, .g = 0x6F, .b = 0xD6, .a = 0xff } }, // blue
        .{ "gofile", C{ .r = 0x18, .g = 0x9E, .b = 0x8E, .a = 0xff } }, // teal
        .{ "pixeldrain", C{ .r = 0xE0, .g = 0x6E, .b = 0x1F, .a = 0xff } }, // orange
        .{ "workupload", C{ .r = 0x6A, .g = 0x4A, .b = 0xB0, .a = 0xff } }, // purple
        .{ "nopy", C{ .r = 0x4A, .g = 0x7C, .b = 0x3E, .a = 0xff } }, // green
        .{ "zippyshare", C{ .r = 0xC0, .g = 0x9A, .b = 0x1F, .a = 0xff } }, // gold
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, host, pair[0])) return pair[1];
    }
    return .{ .r = 0x6F, .g = 0x6F, .b = 0x6F, .a = 0xff }; // grey ("other"/unknown)
}

test "parse splits host/url/label and tolerates a missing label" {
    const a = parse("mega\thttps://mega.nz/file/x\tWin/Linux");
    try std.testing.expectEqualStrings("mega", a.host);
    try std.testing.expectEqualStrings("https://mega.nz/file/x", a.url);
    try std.testing.expectEqualStrings("Win/Linux", a.label);

    const b = parse("gofile\thttps://gofile.io/d/abc");
    try std.testing.expectEqualStrings("gofile", b.host);
    try std.testing.expectEqualStrings("https://gofile.io/d/abc", b.url);
    try std.testing.expectEqualStrings("", b.label);

    const c = parse("");
    try std.testing.expectEqualStrings("", c.host);
    try std.testing.expectEqualStrings("", c.url);
}

test "hostLabel brand-cases known hosts and passes through unknown" {
    try std.testing.expectEqualStrings("MEGA", hostLabel("mega"));
    try std.testing.expectEqualStrings("MediaFire", hostLabel("mediafire"));
    try std.testing.expectEqualStrings("F95", hostLabel("f95_attachment"));
    try std.testing.expectEqualStrings("Link", hostLabel("other"));
    try std.testing.expectEqualStrings("some_new_host", hostLabel("some_new_host"));
}

test "hostColor is stable and falls back to grey" {
    const grey = tokens.Color{ .r = 0x6F, .g = 0x6F, .b = 0x6F, .a = 0xff };
    try std.testing.expectEqual(grey, hostColor("other"));
    try std.testing.expectEqual(grey, hostColor("totally_unknown"));
    try std.testing.expect(!std.meta.eql(grey, hostColor("mega")));
}
