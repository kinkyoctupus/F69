// Shared UI widgets and helpers used by multiple screen files.
//
// Anything called from 2+ screens lives here. Per-screen widgets stay
// next to their screen. Functions in this file should not reach into
// screen-private state — they take primitives or `*Frame`.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");

const types = @import("types.zig");
const state_mod = @import("state.zig");
const actions = @import("actions.zig");
const style = @import("style.zig");

const Frame = types.Frame;

/// Resolve a Game by thread id from the frame's game array. Shared
/// helper — both `recipeEditorScreen` and `modsScreen` arrive at a
/// screen carrying only the thread id (wizard state / selected thread
/// respectively). Hits `frame.games_by_thread` (per-frame snapshot
/// built at the top of `guiFrame`) for O(1) lookup; falls back to a
/// linear scan if the snapshot is missing (e.g. arena-alloc OOM).
pub fn gameByThreadId(frame: *Frame, thread_id: u64) ?*const library.Game {
    if (frame.games_by_thread) |map| return map.get(thread_id);
    for (frame.games) |*g| {
        if (g.f95_thread_id == thread_id) return g;
    }
    return null;
}

/// Short labels that fit in a corner chip. The full enum name is
/// fine in the sidebar filter, but at card scale we need ~6 chars max.
pub fn engineShortLabel(e: library.Engine) []const u8 {
    return switch (e) {
        .renpy => "Ren'Py",
        .rpgm_mv => "RPGM MV",
        .rpgm_mz => "RPGM MZ",
        .rpgm_vx => "RPGM VX",
        .unity => "Unity",
        .unreal => "Unreal",
        .html => "HTML",
        .flash => "Flash",
        .java => "Java",
        .wolf_rpg => "Wolf",
        .qsp => "QSP",
        .tyranobuilder => "Tyrano",
        .twine => "Twine",
        .other => "Other",
        .unknown => "?",
    };
}

/// Short label for the dev-status chip — kept terse so a card or
/// list row can fit one alongside the engine badge.
pub fn devStatusShortLabel(s: library.DevStatus) []const u8 {
    return switch (s) {
        .completed => "Completed",
        .abandoned => "Abandoned",
        .on_hold => "On Hold",
        .in_progress => "Ongoing",
        .orphaned => "Orphaned",
        .unknown => "?",
    };
}

/// Per-status pill color. Mirrors a "traffic light" semantic: green
/// for completed, red for abandoned, amber for on hold, blue for
/// ongoing. Orphaned (thread gone from F95) reads as muted purple —
/// distinct from "abandoned" (dev gave up) without screaming red.
pub fn devStatusColor(s: library.DevStatus) dvui.Color {
    return switch (s) {
        .completed => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 }, // green
        .abandoned => .{ .r = 0xB7, .g = 0x1C, .b = 0x1C }, // red
        .on_hold => .{ .r = 0xC0, .g = 0x84, .b = 0x1F }, // amber
        .in_progress => .{ .r = 0x1F, .g = 0x6A, .b = 0xA0 }, // blue
        .orphaned => .{ .r = 0x6E, .g = 0x4A, .b = 0x8A }, // muted purple
        .unknown => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F }, // grey
    };
}

/// Per-engine accent colors. Loosely chosen to evoke each engine's
/// branding (Ren'Py teal, Unity dark, Unreal navy, etc.) while staying
/// distinguishable at chip scale on top of an arbitrary cover image.
pub fn engineBadgeColor(e: library.Engine) dvui.Color {
    return switch (e) {
        .renpy => .{ .r = 0x12, .g = 0x6E, .b = 0x82 }, // teal
        .rpgm_mv => .{ .r = 0xD8, .g = 0x4A, .b = 0x2C }, // RPG-Maker red
        .rpgm_mz => .{ .r = 0xC0, .g = 0x39, .b = 0x4F }, // crimson
        .rpgm_vx => .{ .r = 0x9E, .g = 0x35, .b = 0x6F }, // mauve
        .unity => .{ .r = 0x33, .g = 0x33, .b = 0x33 }, // graphite
        .unreal => .{ .r = 0x1E, .g = 0x2D, .b = 0x4A }, // navy
        .html => .{ .r = 0xE3, .g = 0x4F, .b = 0x26 }, // HTML5 orange
        .flash => .{ .r = 0xC2, .g = 0x18, .b = 0x18 }, // red
        .java => .{ .r = 0xB0, .g = 0x6A, .b = 0x1A }, // amber-brown
        .wolf_rpg => .{ .r = 0x3E, .g = 0x7C, .b = 0x47 }, // forest green
        .qsp => .{ .r = 0x6A, .g = 0x3C, .b = 0x9E }, // purple
        .tyranobuilder => .{ .r = 0xC9, .g = 0xA2, .b = 0x27 }, // gold
        .twine => .{ .r = 0x55, .g = 0x86, .b = 0x55 }, // sage
        .other => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F }, // grey
        .unknown => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F }, // grey (unused — gated above)
    };
}

/// Toolbar icon size — pinned to the global style so every icon
/// button matches every text button / dropdown / text entry.
const ICON_SIZE: dvui.Size = style.icon_size;
const ICON_OPTS: dvui.IconRenderOptions = .{};

/// Sugar: button with a leading icon + a text label. Returns true on
/// click. Builds the ButtonWidget by hand instead of using dvui's
/// `buttonLabelAndIcon` so we can drop a fixed-width spacer between
/// icon and label — dvui's default puts them flush together which
/// reads cramped at any reasonable font size.
pub fn iconButton(
    src: std.builtin.SourceLocation,
    label: []const u8,
    tvg: []const u8,
    opts: dvui.Options,
) bool {
    const defaults: dvui.Options = .{
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
    };
    const merged = defaults.override(opts);

    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, merged);
    bw.processEvents();
    bw.drawBackground();

    // Inner row: icon, spacer, label. Each child strips parent
    // options so we don't double-pad. The label gets `expand =
    // .both` + `.align_x = 0` so left-aligns flush against the
    // spacer — the row reads "[icon] [gap] [label]".
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const child_opts = merged.strip().override(bw.style());
        dvui.icon(@src(), label, tvg, .{}, child_opts.override(.{
            .gravity_y = 0.5,
            .color_text = opts.color_text,
        }));
        // ICON_TEXT_GAP: physical px between glyph and first label
        // char. 8 reads as a single comfortable space without
        // stretching the row.
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        dvui.labelEx(@src(), "{s}", .{label}, .{ .align_x = 0, .align_y = 0.5 }, child_opts.override(.{
            .expand = .both,
            .gravity_y = 0.5,
        }));
    }

    const click = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return click;
}

/// Sugar: icon-only button (no text). Used for toolbar-style buttons
/// where space is tight and the icon is self-explanatory.
pub fn iconOnly(
    src: std.builtin.SourceLocation,
    name: []const u8,
    tvg: []const u8,
    opts: dvui.Options,
) bool {
    // Pass through gravity / margin / padding / colors so callers
    // can vertical-align the button in a toolbar row, etc. We still
    // override `min_size_content` to ICON_SIZE for visual consistency
    // across the rest of the UI; callers that need a non-default size
    // (e.g. carousel chevrons) call `dvui.buttonIcon` directly.
    return dvui.buttonIcon(src, name, tvg, .{}, ICON_OPTS, .{
        .min_size_content = ICON_SIZE,
        .id_extra = opts.id_extra orelse 0,
        .style = opts.style,
        .gravity_x = opts.gravity_x,
        .gravity_y = opts.gravity_y,
        .margin = opts.margin,
        .padding = opts.padding,
        .color_text = opts.color_text,
        .color_fill = opts.color_fill,
        .color_border = opts.color_border,
        .border = opts.border,
        .corner_radius = opts.corner_radius,
        .background = opts.background,
    });
}

/// Tab-shaped button: rounded only on top, flat-bottomed so the
/// active tab visually merges with the panel below it. Inactive
/// tabs sit a touch lower and use a quieter fill so the active one
/// pops as the obvious "you are here" affordance.
pub fn tabButton(label: []const u8, active: bool) bool {
    const active_fill: dvui.Color = .{ .r = 0x33, .g = 0x1E, .b = 0x28 };
    const inactive_fill: dvui.Color = style.card_fill;
    const tab_border: dvui.Color = style.border_color;
    const highlight: dvui.Color = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A };

    const radius: dvui.Rect = .{ .x = 8, .y = 8, .w = 0, .h = 0 };
    const margin: dvui.Rect = if (active)
        .{ .x = 1, .y = 0, .w = 1, .h = 0 }
    else
        .{ .x = 1, .y = 4, .w = 1, .h = 0 };

    var opts: dvui.Options = .{
        .id_extra = @intFromPtr(label.ptr),
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .corner_radius = radius,
        .background = true,
        .border = style.border_thin,
        .margin = margin,
        // Floor every tab to the same minimum content width so short
        // labels ("Mods" / "Notes") don't read as tiny against the
        // longer ones ("Description" / "Changelog"), and the row
        // doesn't visibly resize as the user clicks between active /
        // inactive tabs (the active tab pulls in slightly different
        // text metrics from the highlight style).
        .min_size_content = .{ .w = 88, .h = 22 },
        .color_fill = if (active) active_fill else inactive_fill,
        .color_border = tab_border,
        .color_text = if (active) highlight else null,
    };
    if (active) opts.style = .highlight;
    return style.button(@src(), label, .{}, opts);
}

/// Pink-muted, wrapping help text for Settings sections + other
/// prose-under-heading slots. `dvui.label` doesn't wrap — long
/// explanations overflow the panel at narrow window widths. Using
/// `textLayout` with `.expand = .horizontal` lets the text reflow.
pub const HELP_TEXT_COLOR: dvui.Color = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 };

pub fn settingsHelpText(text: []const u8) void {
    // dvui's textLayout draws a selection / focus ring by default
    // which renders as a red box at our theme's error colour. Override
    // border + colour explicitly so the help text reads as the dim
    // grey-pink it always meant to be.
    //
    // Every call site uses the same `@src()` so widget ids collide
    // when more than one help block lives on a single screen. Hash
    // the text into `id_extra` so each unique snippet gets a stable,
    // distinct id without callers having to thread an index.
    //
    // cache_layout: help-text strings are compile-time constants —
    // safe to skip the per-frame relayout.
    var tl = dvui.textLayout(@src(), .{ .cache_layout = true }, .{
        .id_extra = std.hash.Wyhash.hash(0, text),
        .expand = .horizontal,
        .background = false,
        .border = .all(0),
        .color_border = HELP_TEXT_COLOR,
        .color_text = HELP_TEXT_COLOR,
    });
    defer tl.deinit();
    tl.addText(text, .{});
}

/// Render a unix-seconds timestamp as `YYYY-MM-DD HH:MM` UTC. No
/// seconds — matches the granularity F95 publishes in its OP info
/// block so the detail page reads consistently.
pub fn formatUtcDateTime(buf: []u8, ts: i64) ![]const u8 {
    if (ts <= 0) return std.fmt.bufPrint(buf, "—", .{});
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = es.getEpochDay();
    const day_secs = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{
            @as(u32, yd.year),
            md.month.numeric(),
            @as(u32, md.day_index) + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
        },
    );
}

/// Format a byte count to "12.3 MB" / "456 KB" / "789 B". Pure
/// formatter, no allocation — works on a caller-provided buffer.
pub fn humanBytes(buf: []u8, n: u64) []const u8 {
    const KB: f32 = 1024.0;
    const MB: f32 = 1024.0 * 1024.0;
    const GB: f32 = 1024.0 * 1024.0 * 1024.0;
    const f: f32 = @floatFromInt(n);
    if (f >= GB) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / GB}) catch "?";
    if (f >= MB) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / MB}) catch "?";
    if (f >= KB) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / KB}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

pub fn humanRate(buf: []u8, bytes_per_sec: u64) []const u8 {
    if (bytes_per_sec == 0) return "—";
    var inner_buf: [24]u8 = undefined;
    const human = humanBytes(&inner_buf, bytes_per_sec);
    return std.fmt.bufPrint(buf, "{s}/s", .{human}) catch "?";
}

// ============================================================
//  Global sync recap popup + toast overlay + sync banner — rendered
//  by ui.zig on every screen.
// ============================================================

pub fn renderSyncRecapPopup(frame: *Frame) void {
    const state = frame.state;
    const entries = actions.syncRecapEntries(state);
    if (entries.len == 0) {
        // Defensive — clear the show flag if we somehow got here
        // with no entries.
        state.sync_recap_show = false;
        return;
    }

    var win = dvui.floatingWindow(@src(), .{ .open_flag = &state.sync_recap_show }, .{
        .min_size_content = .{ .w = 480, .h = 320 },
    });
    defer win.deinit();
    _ = dvui.windowHeader("Updates available", "", &state.sync_recap_show);

    // Top blurb: "<N> games changed since last sync".
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        });
        defer hdr.deinit();
        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{d} game{s} updated", .{
            entries.len, if (entries.len == 1) "" else "s",
        }) catch "";
        dvui.label(@src(), "{s}", .{msg}, .{ .style = .highlight });
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Body: scrolling list of "Name  old → new" rows. Click a row to
    // jump to that game's detail page (also dismisses the popup).
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer scroll.deinit();

    for (entries) |e| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = e.thread_id,
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.card_fill,
            .color_border = style.border_color,
        });
        defer row.deinit();

        dvui.label(@src(), "{s}", .{e.name}, .{
            .gravity_y = 0.5,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
            .style = .highlight,
        });

        var diff_buf: [192]u8 = undefined;
        const diff = if (e.auto_downloaded)
            std.fmt.bufPrint(&diff_buf, "{s} \u{2192} {s} \u{00B7} auto-downloaded", .{ e.old_version, e.new_version }) catch ""
        else
            std.fmt.bufPrint(&diff_buf, "{s} \u{2192} {s}", .{ e.old_version, e.new_version }) catch "";
        dvui.label(@src(), "{s}", .{diff}, .{
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Open", .{}, .{
            .id_extra = e.thread_id,
            .gravity_y = 0.5,
        })) {
            state.selected_thread = e.thread_id;
            state.screen = .detail;
            state.sync_recap_show = false;
        }
    }
}

/// Global sync banner — visible on every screen while a sync-all
/// batch is in flight (or for a brief beat after a single sync
/// completes). Compact one-line strip; styling matches the bookmark
/// progress strip so the two reuse the same vocabulary.
/// Toast overlay — vertical stack of muted-pink pills floating in
/// the bottom-right of the window. Newest on top of the stack
/// (visually = bottom of column since the latest one slides into the
/// most-prominent slot). Errors carry a ✕ dismiss; info/success/warn
/// fade on their own via `state.ageToasts`. No-op when the stack is
/// empty so the overlay is invisible most of the time.
pub fn renderToasts(frame: *Frame) void {
    const state = frame.state;
    const toasts = state.toastSlice();
    if (toasts.len == 0) return;

    // Pin a floatingWindow to the bottom-center of the dvui window.
    // Strip is sized big enough for a tall stack of pills (260px); the
    // inner stack auto-sizes and is `gravity_y = 1.0`-pinned to the
    // bottom of that strip, so a single-line toast actually sits flush
    // at the bottom edge instead of floating somewhere up in the
    // invisible padding. Width scales with the window so long error
    // messages have room to wrap.
    const win_size = dvui.windowRect().size();
    const strip_w: f32 = std.math.clamp(win_size.w * 0.6, 360, 720);
    const strip_h: f32 = 260;
    const edge_margin: f32 = 8;
    state.toast_rect = .{
        .x = @max(0, (win_size.w - strip_w) / 2),
        .y = @max(0, win_size.h - strip_h - edge_margin),
        .w = strip_w,
        .h = strip_h,
    };

    var fw = dvui.floatingWindow(@src(), .{
        .modal = false,
        .stay_above_parent_window = true,
        .window_avoid = .none,
        .rect = &state.toast_rect,
    }, .{
        .background = false,
        .border = .all(0),
        .corner_radius = .all(0),
    });
    defer fw.deinit();

    // Wrapper box: pinned to the bottom of the floatingWindow's strip
    // and auto-sized vertically. Without this, the inner column with
    // `expand = .both` filled the whole 260px strip and child pills
    // landed at the *top* of it — visually that put a single-line
    // toast ~260px above the screen edge, which is what "pops up in
    // the middle" was.
    var anchor = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_y = 1.0,
        .expand = .horizontal,
    });
    defer anchor.deinit();

    // Render oldest-first so the newest pill sits at the bottom of
    // the stack — closest to where the user's eye landed for the
    // last action. `toasts[]` is newest-first, so iterate in reverse.
    var to_dismiss: ?usize = null;
    var idx_back: usize = toasts.len;
    while (idx_back > 0) : (idx_back -= 1) {
        const i = idx_back - 1;
        if (renderToastPill(i, toasts[i])) to_dismiss = i;
    }
    if (to_dismiss) |i| state.dismissToast(i);
}

/// Renders one toast pill. Returns true when the user clicked anywhere
/// on it — caller dismisses to keep the loop's iteration index sane.
/// Built as a `ButtonWidget` (not a plain box) so click events are
/// captured at the pill level *before* the inner textLayout has a
/// chance to swallow them for text-selection.
fn renderToastPill(index: usize, t: state_mod.Toast) bool {
    const glyph: []const u8 = switch (t.kind) {
        .info => "",
        .success => "\u{2713} ", // ✓
        .warn => "\u{26A0} ", // ⚠
        .err => "\u{2715} ", // ✕
    };
    const text_color: dvui.Color = switch (t.kind) {
        .info => HELP_TEXT_COLOR,
        .success => .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
        .warn => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
        .err => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
    };

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = @intCast(index),
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .all(6),
        .color_fill = style.card_fill,
        .color_border = style.border_color,
        .expand = .horizontal,
    });
    bw.processEvents();
    bw.drawBackground();
    defer bw.deinit();

    var label_buf: [state_mod.MAX_TOAST_MSG + 4]u8 = undefined;
    const label_text = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ glyph, t.msg() }) catch t.msg();
    // textLayout wraps to the parent button's width — multi-line
    // errors no longer get clipped at the strip edge.
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = @intCast(index),
        .expand = .horizontal,
        .background = false,
        .border = .all(0),
        .color_text = text_color,
    });
    defer tl.deinit();
    tl.addText(label_text, .{});

    return bw.clicked();
}

pub fn renderSyncBanner(frame: *Frame) void {
    const state = frame.state;
    const has_active = state.pending_sync != null;
    const has_queue = state.sync_queue != null;
    // Phase-2 (background image fetch) keeps the banner pinned even
    // after phase-1 sync-all is done. The whole library is usable; the
    // banner just shows "still tidying up screenshots…". `image_total
    // > 0` covers the brief window where the active job is reaped but
    // the next hasn't spawned yet.
    const has_image_work = state.image_active != null or
        (state.image_queue != null and state.image_queue_head < state.image_queue_len) or
        state.image_total > 0;
    // Only surface the banner while a sync is genuinely in flight.
    // Terminal messages like "nothing to sync — all games already
    // populated" used to keep the banner pinned on every screen
    // (including during bookmark imports) — that's noisy and confusing.
    // Settled state messages live in their normal status-line slots.
    if (!has_active and !has_queue and !has_image_work) return;

    // Stack: row 1 = sync (text + cover); row 2 = phase-2 (images).
    // The outer vbox gives both rows the same padded background so it
    // reads as a single banner.
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        .background = true,
        .style = if (state.sync_status == .err) .err else .highlight,
    });
    defer outer.deinit();

    // Only render row 1 when phase-1 work is in flight; otherwise the
    // phase-2 row stands alone after the sync-all batch settles.
    if (has_active or has_queue) {
        renderSyncBannerSyncRow(frame);
    }
    if (has_image_work) {
        renderSyncBannerImageRow(frame);
    }
}

fn renderSyncBannerSyncRow(frame: *Frame) void {
    const state = frame.state;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
    });
    defer bar.deinit();

    // Status text: current game name + queue position. Falls back to
    // a stale message when no name is set (e.g. transient state right
    // before the next worker spawns).
    const cur_name = state.currentSyncName();
    if (cur_name.len > 0 and state.sync_queue_total > 0) {
        var lbl_buf: [220]u8 = undefined;
        const lbl = std.fmt.bufPrint(
            &lbl_buf,
            "Syncing {s}  ({d}/{d})",
            .{ cur_name, state.sync_queue_started, state.sync_queue_total },
        ) catch "Syncing…";
        dvui.label(@src(), "{s}", .{lbl}, .{ .gravity_y = 0.5 });
    } else if (cur_name.len > 0) {
        var lbl_buf: [200]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lbl_buf, "Syncing {s}…", .{cur_name}) catch "Syncing…";
        dvui.label(@src(), "{s}", .{lbl}, .{ .gravity_y = 0.5 });
    } else if (!state.sync_msg.isEmpty()) {
        dvui.label(@src(), "{s}", .{state.syncMsg()}, .{ .gravity_y = 0.5 });
    } else {
        dvui.label(@src(), "Syncing…", .{}, .{ .gravity_y = 0.5 });
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // Progress bar whenever the batch counters are populated, even if
    // the transition between two jobs leaves `pending_sync` momentarily
    // null. queue_idx is 1-based after syncGame increments it.
    if (state.sync_queue_total > 0) {
        const pct: u32 = if (state.sync_queue_total > 0)
            @intCast(@min(@divTrunc(@as(u64, state.sync_queue_started) * 100, @as(u64, state.sync_queue_total)), 100))
        else
            0;
        {
            var bar_outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 200, .h = 12 },
                .border = style.border_thin,
                .corner_radius = .all(3),
                .color_border = style.border_color,
                .background = true,
                .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
                .gravity_y = 0.5,
            });
            defer bar_outer.deinit();
            if (pct > 0) {
                const fill_w: f32 = (@as(f32, @floatFromInt(pct)) * 196.0) / 100.0;
                var bar_inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{
                        .w = @max(2.0, fill_w),
                        .h = 8,
                    },
                    .background = true,
                    .color_fill = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
                    .corner_radius = .all(2),
                    .gravity_y = 0.5,
                });
                bar_inner.deinit();
            }
        }

        var pct_buf: [24]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "  {d}/{d}", .{ state.sync_queue_started, state.sync_queue_total }) catch "";
        dvui.label(@src(), "{s}", .{pct_str}, .{ .gravity_y = 0.5 });
    }

    // Intra-sync sub-progress: "step 3/12" showing image-fetch
    // progress within the current game. Worker exports `progress_done`
    // / `progress_total` atomically; we read both per frame. Once
    // cancel is requested, we replace the sub-step indicator with
    // a plain "cancelling…" hint so the percentage doesn't keep
    // ticking up after the user clicked Cancel.
    if (state.pending_sync) |j| {
        const cancelling = j.cancel.load(.acquire);
        if (cancelling) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
            dvui.label(@src(), "cancelling\u{2026}", .{}, .{
                .gravity_y = 0.5,
                .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
            });
        } else {
            const done = j.payload.progress_done.load(.acquire);
            const total = j.payload.progress_total.load(.acquire);
            if (total > 1) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
                var step_buf: [40]u8 = undefined;
                const step_str = std.fmt.bufPrint(&step_buf, "step {d}/{d}", .{ done, total }) catch "";
                dvui.label(@src(), "{s}", .{step_str}, .{
                    .gravity_y = 0.5,
                    .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
                });
            }
        }
    }

    // Cancel button — flags the worker + drops the rest of the queue.
    // Once the flag is set we immediately repaint the button as
    // "Cancelling…" greyed-out, so a user who clicks Cancel doesn't
    // see the row keep churning (worker only observes the flag
    // between phases — a single page fetch can stall for seconds).
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
    const sync_cancelling: bool = blk: {
        if (state.pending_sync) |j| {
            break :blk j.cancel.load(.acquire);
        }
        break :blk false;
    };
    if (sync_cancelling) {
        const dim: dvui.Options = .{
            .style = .control,
            .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
        };
        _ = iconButton(@src(), "Cancelling\u{2026}", entypo.cross, dim);
    } else {
        if (iconButton(@src(), "Cancel", entypo.cross, .{ .style = .err })) {
            actions.cancelSync(frame);
        }
    }
}

/// Phase-2 banner row: aggregate progress for background screenshot
/// fetches. Stays pinned after phase-1 wraps up so the user can see
/// "library is usable, images still trickling in".
fn renderSyncBannerImageRow(frame: *Frame) void {
    const state = frame.state;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
    });
    defer bar.deinit();

    const queue_pending: usize = if (state.image_queue) |_|
        state.image_queue_len - state.image_queue_head
    else
        0;
    const cur_name = state.currentImageName();
    const cancelling = state.image_cancel.load(.acquire);
    const done = state.image_done.load(.acquire);
    const total = state.image_total;

    if (cancelling) {
        dvui.label(@src(), "Cancelling background image fetch\u{2026}", .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    } else if (cur_name.len > 0 and queue_pending > 0) {
        var lbl_buf: [220]u8 = undefined;
        const lbl = std.fmt.bufPrint(
            &lbl_buf,
            "Fetching images: {s}  (+{d} games queued)",
            .{ cur_name, queue_pending },
        ) catch "Fetching images\u{2026}";
        dvui.label(@src(), "{s}", .{lbl}, .{ .gravity_y = 0.5 });
    } else if (cur_name.len > 0) {
        var lbl_buf: [200]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lbl_buf, "Fetching images: {s}", .{cur_name}) catch "Fetching images\u{2026}";
        dvui.label(@src(), "{s}", .{lbl}, .{ .gravity_y = 0.5 });
    } else {
        dvui.label(@src(), "Fetching images\u{2026}", .{}, .{ .gravity_y = 0.5 });
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    if (total > 0) {
        const pct: u32 = @intCast(@min(@divTrunc(@as(u64, done) * 100, @as(u64, total)), 100));
        {
            var bar_outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 200, .h = 10 },
                .border = style.border_thin,
                .corner_radius = .all(3),
                .color_border = style.border_color,
                .background = true,
                .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
                .gravity_y = 0.5,
            });
            defer bar_outer.deinit();
            if (pct > 0) {
                const fill_w: f32 = (@as(f32, @floatFromInt(pct)) * 196.0) / 100.0;
                var bar_inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{
                        .w = @max(2.0, fill_w),
                        .h = 6,
                    },
                    .background = true,
                    .color_fill = .{ .r = 0x8A, .g = 0x6E, .b = 0xC9 },
                    .corner_radius = .all(2),
                    .gravity_y = 0.5,
                });
                bar_inner.deinit();
            }
        }
        var pct_buf: [32]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "  {d}/{d}", .{ done, total }) catch "";
        dvui.label(@src(), "{s}", .{pct_str}, .{
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }

    // Cancel button (separate from the phase-1 Cancel — once phase-1
    // is done, only this remains). Same dim-on-press treatment.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
    if (cancelling) {
        const dim: dvui.Options = .{
            .style = .control,
            .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
        };
        _ = iconButton(@src(), "Cancelling\u{2026}", entypo.cross, dim);
    } else {
        if (iconButton(@src(), "Cancel images", entypo.cross, .{ .style = .control })) {
            actions.cancelImageQueue(frame);
        }
    }
}
