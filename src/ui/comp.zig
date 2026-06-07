// Design B component layer — theme-driven dvui widgets.
//
// Colors come from `tokens.active` (the runtime theme), so every widget follows
// the user's chosen palette. Mirrors the call idioms in `style.zig`. Screens
// compose these instead of hand-building boxes. Visual parity target:
// docs/superpowers/mockups/design-B.html.

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");

/// tokens.Color → dvui.Color.
inline fn c(col: tokens.Color) dvui.Color {
    return tokens.toDvui(col, dvui.Color);
}

// ----- chips / badges -----

pub const ChipSpec = struct {
    label: []const u8,
    fill: tokens.Color,
    text: tokens.Color,
    border: tokens.Color,
};

/// The one pill renderer. All badges below are thin theme-driven wrappers.
pub fn chip(src: std.builtin.SourceLocation, spec: ChipSpec, opts: dvui.Options) void {
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = c(spec.fill),
        .color_border = c(spec.border),
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(tokens.r),
        .padding = .{ .x = 7, .y = 1, .w = 7, .h = 1 },
        .min_size_content = .{ .w = 0, .h = 19 },
    };
    var box = dvui.box(src, .{ .dir = .horizontal }, defaults.override(opts));
    defer box.deinit();
    dvui.labelNoFmt(@src(), spec.label, .{}, .{ .color_text = c(spec.text), .gravity_y = 0.5 });
}

pub fn engineChip(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = label, .fill = t.acc_wash, .text = t.acc, .border = t.acc_dim }, opts);
}

pub fn statusChip(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = label, .fill = t.bg2, .text = t.ink2, .border = t.line }, opts);
}

pub fn newChip(src: std.builtin.SourceLocation, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = "NEW", .fill = t.bg2, .text = t.accent2, .border = t.line }, opts);
}

pub fn tagChip(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = label, .fill = t.bg2, .text = t.ink2, .border = t.line }, opts);
}

/// Small status dot (install/sync state).
pub fn dot(src: std.builtin.SourceLocation, color: tokens.Color, opts: dvui.Options) void {
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = c(color),
        .corner_radius = dvui.Rect.all(2),
        .min_size_content = .{ .w = 7, .h = 7 },
    };
    var box = dvui.box(src, .{}, defaults.override(opts));
    box.deinit();
}

// ----- button -----

pub const Variant = enum { neutral, primary, danger, ghost };

pub fn button(src: std.builtin.SourceLocation, label: []const u8, variant: Variant, opts: dvui.Options) bool {
    const t = tokens.active;
    const skin: dvui.Options = switch (variant) {
        .primary => .{ .color_fill = c(t.acc), .color_text = c(t.ink_on_acc), .color_border = c(t.acc) },
        .danger => .{ .color_fill = c(t.bg2), .color_text = c(t.danger), .color_border = c(t.line) },
        .ghost => .{ .color_text = c(t.ink2) },
        .neutral => .{ .color_fill = c(t.bg2), .color_text = c(t.ink), .color_border = c(t.line) },
    };
    const layout: dvui.Options = .{
        .background = variant != .ghost,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(tokens.r),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
        .min_size_content = .{ .w = 0, .h = 29 },
    };
    return dvui.button(src, label, .{}, layout.override(skin).override(opts));
}

// ----- progress + section header -----

/// Horizontal progress bar. `frac` 0..1; `width` is the track width in px.
pub fn progressBar(src: std.builtin.SourceLocation, frac: f32, width: f32, opts: dvui.Options) void {
    const t = tokens.active;
    const f = std.math.clamp(frac, 0, 1);
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = c(t.bg3),
        .corner_radius = dvui.Rect.all(2),
        .min_size_content = .{ .w = width, .h = 7 },
    };
    var outer = dvui.box(src, .{ .dir = .horizontal }, defaults.override(opts));
    defer outer.deinit();
    var inner = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = c(t.acc),
        .corner_radius = dvui.Rect.all(2),
        .min_size_content = .{ .w = width * f, .h = 7 },
    });
    inner.deinit();
}

/// Mono, dimmed, uppercase-style section label (e.g. "PLAN SUMMARY").
pub fn sectionHeader(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    dvui.labelNoFmt(src, label, .{}, (dvui.Options{ .color_text = c(tokens.active.ink3) }).override(opts));
}

test "comp compiles against dvui + tokens" {
    std.testing.refAllDecls(@This());
}
