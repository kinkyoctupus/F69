// Global visual style. Every chrome widget in the app — buttons,
// dropdowns, text entries, icon chips, card frames — should source
// its dimensions and colors from here so the UI feels cohesive.
//
// Callers can override per-call by passing the relevant `opts` field;
// `defaults.override(opts)` lets the caller win. Things that need to
// break out entirely (carousel chevrons, raw `dvui.buttonIcon`) just
// keep calling dvui directly.

const std = @import("std");
const dvui = @import("dvui");

// =============================================================
//  Dimensions
// =============================================================

/// Outer "content height" used for every text button, dropdown,
/// and text entry on the toolbar. Matches `icon_size.h` so an
/// icon-only button and a text button sit at the same height.
pub const button_h: f32 = 16;

/// Square icon glyph size for icon-only buttons.
pub const icon_size: dvui.Size = .{ .w = 16, .h = 16 };

/// Standard corner radius for cards, chips, and buttons.
pub const corner_radius: dvui.Rect = .all(4);

/// Standard 1-px border for cards and chips.
pub const border_thin: dvui.Rect = .all(1);

/// Tight padding for cover-area chips (engine + status badges).
/// Vertical zero so the chip hugs the text height.
pub const chip_padding: dvui.Rect = .all(0);

/// Inset for chip text — a tiny amount of left/right breathing
/// room without the chip looking baggy.
pub const chip_label_padding: dvui.Rect = .{ .x = 1, .y = 0, .w = 1, .h = 0 };

// =============================================================
//  Typography
// =============================================================

/// Font-size scale for chip text. Multiplied by `body.size`.
pub const chip_font_scale: f32 = 0.51;

/// Font-size scale for subtitle / meta rows under card titles.
pub const meta_font_scale: f32 = 0.85;

/// Font-size scale for card titles. Multiplied by `heading.size`.
pub const title_font_scale: f32 = 0.85;

// =============================================================
//  Colors
// =============================================================

/// Border shared by card frames and chip outlines.
pub const border_color: dvui.Color = .{ .r = 0x5C, .g = 0x2A, .b = 0x3D };

/// Default card fill.
pub const card_fill: dvui.Color = .{ .r = 0x22, .g = 0x14, .b = 0x1B };

/// Letterbox / cover-empty fill behind aspect-preserved images.
pub const letterbox_fill: dvui.Color = .{ .r = 0x00, .g = 0x00, .b = 0x00 };

// =============================================================
//  Widget wrappers
// =============================================================

/// `dvui.button` with the app's standard outer height.
pub fn button(
    src: std.builtin.SourceLocation,
    label: []const u8,
    init_opts: dvui.ButtonWidget.InitOptions,
    opts: dvui.Options,
) bool {
    const defaults: dvui.Options = .{
        .min_size_content = .{ .w = 0, .h = button_h },
    };
    return dvui.button(src, label, init_opts, defaults.override(opts));
}

/// `dvui.dropdown` with the app's standard outer height.
pub fn dropdown(
    src: std.builtin.SourceLocation,
    entries: []const []const u8,
    choice: dvui.DropdownChoice(usize),
    init_opts: dvui.DropdownInitOptions,
    opts: dvui.Options,
) bool {
    const defaults: dvui.Options = .{
        .min_size_content = .{ .w = 0, .h = button_h },
    };
    return dvui.dropdown(src, entries, choice, init_opts, defaults.override(opts));
}

/// `dvui.textEntry` with the app's standard outer height.
pub fn textEntry(
    src: std.builtin.SourceLocation,
    init_opts: dvui.TextEntryWidget.InitOptions,
    opts: dvui.Options,
) *dvui.TextEntryWidget {
    const defaults: dvui.Options = .{
        .min_size_content = .{ .w = 0, .h = button_h },
    };
    return dvui.textEntry(src, init_opts, defaults.override(opts));
}
