// All four screens (library / detail / settings / import) plus the
// rendering helpers they share — sidebar filters, grid+list views,
// game cards, cover renderers, tag chips, tab bar, settings rows,
// library stats, sort comparator.
//
// State mutations that aren't pure rendering live in `actions.zig`
// (sync, cover cache, browser launch, delete). This file imports
// `actions.zig` and calls those when buttons fire.

const std = @import("std");
const library = @import("library");
const f95 = @import("f95");
const downloads = @import("downloads");
const recipe = @import("recipe");
const dvui = @import("dvui");
const version_mod = @import("util_version");
const file_picker = @import("util_file_picker");
const entypo = dvui.entypo;
const state_mod = @import("state.zig");
const types = @import("types.zig");
const actions = @import("actions.zig");
const style = @import("style.zig");
const installer_mod = @import("installer");
const mod_job_queue = @import("mod_job_queue.zig");
const import_job_mod = @import("import_job.zig");
const build_options = @import("build_options");

const State = types.State;
const Frame = types.Frame;

/// Toolbar icon size — pinned to the global style so every icon
/// button matches every text button / dropdown / text entry.
const ICON_SIZE: dvui.Size = style.icon_size;
const ICON_OPTS: dvui.IconRenderOptions = .{};

/// Sugar: button with a leading icon + a text label. Returns true on
/// click. Builds the ButtonWidget by hand instead of using dvui's
/// `buttonLabelAndIcon` so we can drop a fixed-width spacer between
/// icon and label — dvui's default puts them flush together which
/// reads cramped at any reasonable font size.
fn iconButton(
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
fn iconOnly(
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

/// Tall icon button used by the carousel chevrons. `iconOnly` clamps
/// the icon size to ICON_SIZE for visual consistency across the rest
/// of the UI; the carousel chevrons explicitly want a larger button
/// so we go around `iconOnly` and call `dvui.buttonIcon` ourselves.
/// Returns true on click. The icon glyph itself is sized to a chunky
/// 36 px so it reads well at the larger button height.
fn tallChevronButton(
    src: std.builtin.SourceLocation,
    name: []const u8,
    tvg: []const u8,
    w: f32,
    h: f32,
) bool {
    return dvui.buttonIcon(src, name, tvg, .{}, ICON_OPTS, .{
        .min_size_content = .{ .w = 36, .h = 36 },
        .padding = .{ .x = (w - 36) / 2, .y = (h - 36) / 2, .w = (w - 36) / 2, .h = (h - 36) / 2 },
        .gravity_y = 0.5,
    });
}

// ============================================================
//  library screen
// ============================================================

pub fn libraryScreen(frame: *Frame) !bool {
    const state = frame.state;
    const games = frame.games;

    // Refresh the installed-set once per frame. Cheap SELECT DISTINCT
    // over the installs table; powers the "installed" indicator on
    // cards/list rows and the installed-state filter below.
    actions.refreshInstalledSet(frame);

    // Re-sort the snapshot if user changed the sort or we just reloaded.
    if (state.sort_applied_column != state.sort_column or state.sort_applied_dir != state.sort_dir) {
        sortGames(games, state.sort_column, state.sort_dir);
        state.sort_applied_column = state.sort_column;
        state.sort_applied_dir = state.sort_dir;
    }
    // ---- top bar ----
    // Top bar 1/2 — actions only. Layout:
    //   "f69 — N games" label takes the leading slack on the left,
    //   the button cluster lives in a `dvui.flexbox(.justify_content
    //   = .end)` on the right so the buttons anchor to the right
    //   edge. When the window is too narrow to fit everything on
    //   one row, the flexbox wraps the buttons onto subsequent
    //   rows (still right-aligned).
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 4 },
        });
        defer top.deinit();

        dvui.label(@src(), "f69 — {d} games", .{games.len}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        // Right-anchored, wrapping button cluster. `expand =
        // .horizontal` claims the remaining width of the row so the
        // flexbox knows where the right edge is; `justify_content =
        // .end` packs the buttons against that right edge.
        var actions_box = dvui.flexbox(@src(), .{ .justify_content = .end }, .{
            .expand = .horizontal,
        });
        defer actions_box.deinit();

        // === workflow group (in order of typical use frequency) ===
        // Split-button "Check for updates" — primary click runs the
        // cheap latest-updates walk; chevron menu has the
        // full-library re-scrape option.
        renderSyncSplitButton(frame);
        // Split-button "Add" — primary opens the paste-import screen;
        // chevron menu surfaces "Import all bookmarks (F95)" so the
        // two acquisition paths share one entry point.
        renderAddSplitButton(frame);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

        // === nav group: status → config → exit ===
        var dl_label_buf: [32]u8 = undefined;
        const dl_label = if (frame.dl_mgr.jobCount() > 0)
            std.fmt.bufPrint(&dl_label_buf, "Downloads ({d})", .{frame.dl_mgr.jobCount()}) catch "Downloads"
        else
            "Downloads";
        if (iconButton(@src(), dl_label, entypo.download, .{})) state.screen = .downloads;
        if (iconButton(@src(), "Settings", entypo.cog, .{})) state.screen = .settings;
        if (iconButton(@src(), "Quit", entypo.cross, .{ .style = .err })) return false;
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ---- bookmarks-pull progress strip (visible only while pulling
    // or while the post-pull message is fresh) ----
    renderBookmarksProgress(frame);

    // ---- body: sidebar + main ----
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer body.deinit();

    sidebar(state);

    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 1 },
    });

    var main_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    defer main_box.deinit();

    // View / search / sort toolbar — lives inside the main column so
    // it spans only the grid+list area, not the sidebar. Every child
    // gets `gravity_y = 0.5` so icons / dropdowns / text entry share
    // a baseline regardless of their natural height.
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        defer bar.deinit();

        // Sort: column dropdown + asc/desc toggle. Pretty labels so
        // the user sees "Sync state" rather than `sync_state`.
        dvui.label(@src(), "sort:", .{}, .{ .gravity_y = 0.5 });
        const sort_labels = &[_][]const u8{ "Name", "Rating", "Weighted", "Votes", "Last updated", "Sync state" };
        var sort_picked: usize = @intFromEnum(state.sort_column);
        if (style.dropdown(@src(), sort_labels, .{ .choice = &sort_picked }, .{}, .{
            .min_size_content = .{ .w = 130, .h = style.button_h },
            .gravity_y = 0.5,
        })) {
            state.sort_column = @enumFromInt(sort_picked);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        const dir_tvg = if (state.sort_dir == .asc) entypo.chevron_up else entypo.chevron_down;
        if (iconOnly(@src(), "sort-dir", dir_tvg, .{ .style = .highlight, .gravity_y = 0.5 })) {
            state.sort_dir = if (state.sort_dir == .asc) .desc else .asc;
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 16, .h = 1 } });

        // Search — fills all remaining horizontal space.
        dvui.icon(@src(), "search", entypo.magnifying_glass, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 14, .h = 14 },
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.search_buf } }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        te.deinit();

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 16, .h = 1 } });

        // View toggle on the right — interacted with rarely once
        // you've picked a layout.
        const grid_opts: dvui.Options = if (state.view == .grid)
            .{ .id_extra = 1, .style = .highlight, .gravity_y = 0.5 }
        else
            .{ .id_extra = 1, .gravity_y = 0.5 };
        const list_opts: dvui.Options = if (state.view == .list)
            .{ .id_extra = 2, .style = .highlight, .gravity_y = 0.5 }
        else
            .{ .id_extra = 2, .gravity_y = 0.5 };
        if (iconOnly(@src(), "grid", entypo.grid, grid_opts)) state.view = .grid;
        if (iconOnly(@src(), "list", entypo.list, list_opts)) state.view = .list;
    }

    const query = state.searchSlice();
    renderVirtualizedList(frame, games, query);

    return true;
}

/// Render 5 star icons for a 0..5 float rating. Filled if `rating >=
/// n - 0.5` (round-to-nearest). Pure display — non-interactive.
fn renderRatingStars(rating: f32) void {
    const accent: dvui.Color = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A };
    var n: u8 = 1;
    while (n <= 5) : (n += 1) {
        const filled = rating >= @as(f32, @floatFromInt(n)) - 0.5;
        const tvg = if (filled) entypo.star else entypo.star_outlined;
        dvui.icon(@src(), "rate", tvg, .{}, .{
            .id_extra = n,
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .color_text = if (filled) accent else null,
        });
    }
}

// ============================================================
//  Detail-screen meta layout helpers
// ============================================================

/// Top-of-meta pill bar. Renders the engine badge, dev-status badge,
/// F95 rating stars + count, plus a small "F95 #<id>" link on the
/// right. One row that establishes the game's visual identity.
fn renderIdentityPillRow(frame: *Frame, game: *const library.Game) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    defer row.deinit();

    // Engine pill.
    if (game.engine != .unknown) {
        const fill = engineBadgeColor(game.engine);
        var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = game.f95_thread_id ^ 0xE1,
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .corner_radius = .all(3),
            .background = true,
            .color_fill = fill,
            .color_border = fill,
            .border = style.border_thin,
        });
        defer pill.deinit();
        dvui.label(@src(), "{s}", .{engineShortLabel(game.engine)}, .{
            .gravity_y = 0.5,
            .color_text = dvui.Color.white,
        });
    }

    // Dev-status pill.
    if (game.dev_status != .unknown) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const fill = devStatusColor(game.dev_status);
        var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = game.f95_thread_id,
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .corner_radius = .all(3),
            .background = true,
            .color_fill = fill,
            .color_border = fill,
            .border = style.border_thin,
        });
        defer pill.deinit();
        dvui.label(@src(), "{s}", .{devStatusShortLabel(game.dev_status)}, .{
            .gravity_y = 0.5,
            .color_text = dvui.Color.white,
        });
    }

    // F95 rating stars + numeric — visually weighty enough to belong
    // up here next to engine/state.
    if (game.rating) |r| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 14, .h = 1 } });
        renderRatingStars(r);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        var lbl_buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&lbl_buf, "{d:.1} ({d} votes)", .{ r, game.vote_count orelse 0 }) catch "";
        dvui.label(@src(), "{s}", .{s}, .{
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // F95 thread id — clickable, opens the thread in the user's
    // browser. Muted styling so it doesn't compete with the pills.
    var tid_buf: [32]u8 = undefined;
    const tid_str = std.fmt.bufPrint(&tid_buf, "F95 #{d}", .{game.f95_thread_id}) catch "F95";
    if (style.button(@src(), tid_str, .{}, .{
        .gravity_y = 0.5,
        .style = .control,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    })) {
        actions.openInBrowser(frame, game.f95_thread_id);
    }
}

/// Left meta panel — verbatim "From F95" facts (Thread Updated /
/// Single-column key/value facts grid that replaces the old side-by-
/// side `From F95` + `Your library` panels. Each row is a label on
/// the left and the value (or editable control) on the right. Rows
/// reflow with the panel width — no `expand=.both` siblings that
/// would compete for space and disappear when narrow.
///
/// Editable rows (your status, your rating) use dvui widgets that
/// carry their own affordance — no need for a separate bordered
/// "Your library" card to signal editability.
fn renderDetailFactsGrid(frame: *Frame, game: *library.Game) void {
    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = game.f95_thread_id ^ 0xF9,
        .expand = .horizontal,
    });
    defer grid.deinit();

    var row_id: u32 = 1;

    // ---- Scraped facts (read-only). Pulled from `game` so we don't
    // duplicate the F95 prose block in two places — the structured
    // copy here is what the user actually scans for. The "From F95"
    // prose is now folded into the Description tab.
    if (game.latest_version) |v| {
        factsRow(&row_id, "Version", .{ .text = v });
    }
    if (game.developer) |d| {
        factsRow(&row_id, "Developer", .{ .text = d });
    }
    if (game.last_updated_at) |ts| {
        var buf: [32]u8 = undefined;
        const dt = formatUtcDateTime(&buf, ts) catch "—";
        factsRow(&row_id, "Last updated", .{ .text = dt });
    }

    // ---- "Last synced" row pairs the timestamp with an inline
    // mini-Sync button (the toolbar Sync above is still the loud
    // version; this is for "I'm looking at the data and noticed it's
    // stale" muscle memory).
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Last synced", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
        var dt_buf: [40]u8 = undefined;
        const dt = if (game.last_scraped_at) |ts|
            formatUtcDateTime(&dt_buf, ts) catch "—"
        else
            "never";
        dvui.label(@src(), "{s}", .{dt}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (iconButton(@src(), "Sync now", entypo.cycle, .{
            .style = .control,
            .gravity_y = 0.5,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        })) {
            actions.syncGame(frame, game);
        }
    }

    // ---- Editable user-state rows. These three share the row shape
    // of the scraped facts above so the eye reads them as a single
    // table. dvui's dropdown / star widgets already cue editability.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Your status", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
        const labels = completionStatusLabels();
        var picked: usize = @intFromEnum(game.completion_status);
        if (style.dropdown(@src(), labels, .{ .choice = &picked }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 200, .h = 26 },
        })) {
            game.completion_status = @enumFromInt(picked);
            frame.lib.upsertGame(game) catch {};
        }
    }
    {
        var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Your rating", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
        const ur_int: u8 = if (game.user_rating) |r| @as(u8, @intFromFloat(@round(r))) else 0;
        var n: u8 = 1;
        while (n <= 5) : (n += 1) {
            const filled = ur_int >= n;
            const tvg = if (filled) entypo.star else entypo.star_outlined;
            if (dvui.buttonIcon(@src(), "rate", tvg, .{}, .{}, .{
                .id_extra = n,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 22, .h = 22 },
                .color_text = if (filled)
                    dvui.Color{ .r = 0xE9, .g = 0x4B, .b = 0x7A }
                else
                    null,
            })) {
                if (ur_int == n) game.user_rating = null else game.user_rating = @floatFromInt(n);
                frame.lib.upsertGame(game) catch {};
            }
        }
    }
    // Editable Sandbox row — three-choice dropdown. `.use_default`
    // pulls its actual decision from the global toggle in
    // Settings → General; we surface that fact in the label so the
    // user knows what "default" means at a glance.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Sandbox", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
        const labels = sandboxOverrideLabels(frame.state.sandbox_default);
        var picked: usize = @intFromEnum(game.sandbox);
        if (style.dropdown(@src(), labels, .{ .choice = &picked }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 220, .h = 26 },
        })) {
            game.sandbox = @enumFromInt(picked);
            frame.lib.upsertGame(game) catch {};
        }
    }

    // Editable Auto-update row — twin of Sandbox row. `.use_default`
    // defers to the global toggle in Settings; label echoes the
    // current global value so "default" reads unambiguously.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Auto-update", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
        const labels = autoUpdateOverrideLabels(frame.state.auto_update_default);
        var picked: usize = @intFromEnum(game.auto_update);
        if (style.dropdown(@src(), labels, .{ .choice = &picked }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 220, .h = 26 },
        })) {
            game.auto_update = @enumFromInt(picked);
            frame.lib.upsertGame(game) catch {};
        }
    }
}

/// Labels for the AutoUpdateOverride dropdown. Order matches the
/// enum so `@intFromEnum` indexes directly. "Use default" embeds the
/// current global value so the user knows what default means.
fn autoUpdateOverrideLabels(global_default_on: bool) []const []const u8 {
    if (global_default_on) {
        return &[_][]const u8{
            "Use default (on)",
            "Always auto-update",
            "Never auto-update",
        };
    }
    return &[_][]const u8{
        "Use default (off)",
        "Always auto-update",
        "Never auto-update",
    };
}

/// Labels for the SandboxOverride dropdown. Order matches the enum
/// (`use_default`, `always`, `never`) so `@intFromEnum` indexes
/// directly. The "use default" label embeds the current global value
/// — without it, the user can't tell from the dropdown alone whether
/// "default" means sandboxed or not.
fn sandboxOverrideLabels(global_default_on: bool) []const []const u8 {
    if (global_default_on) {
        return &[_][]const u8{
            "Use default (on)",
            "Always sandbox",
            "Never sandbox",
        };
    }
    return &[_][]const u8{
        "Use default (off)",
        "Always sandbox",
        "Never sandbox",
    };
}

/// Row payload — either plain text, or a slot we render inline (the
/// editable rows skip this helper and inline their dvui widgets).
const FactsValue = union(enum) {
    text: []const u8,
};

/// Render a single `Label: value` row inside the facts grid.
/// Right column expands; left is fixed-width so labels align.
fn factsRow(row_id: *u32, label: []const u8, value: FactsValue) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = row_id.*,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    row_id.* += 1;
    dvui.label(@src(), "{s}", .{label}, .{
        .min_size_content = .{ .w = 120, .h = 20 },
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });
    switch (value) {
        .text => |t| dvui.label(@src(), "{s}", .{t}, .{
            .gravity_y = 0.5,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
        }),
    }
}

/// Inline "Install from file…" panel — three text fields plus
/// Cancel / Install buttons. Lives directly under the action row so
/// the user keeps the rest of the detail page in context while they
/// fill it in. Closing via Cancel (or the toggle button) preserves
/// what's typed; closing after Install resets the fields.
fn renderManualInstallPanel(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    // First-time auto-fill: when the user pastes a path AND the
    // version field is still empty, run the title-extraction heuristic
    // on the file's basename so they almost always just have to click
    // Install. We only do this when version is empty — once they
    // type, we leave their text alone.
    {
        const path = state.manualInstallPathSlice();
        const version = state.manualInstallVersionSlice();
        if (path.len > 0 and version.len == 0) {
            // basename
            const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
            const base_with_ext = if (slash == 0) path else path[slash + 1 ..];
            // strip extension (last '.')
            const dot = std.mem.lastIndexOfScalar(u8, base_with_ext, '.') orelse base_with_ext.len;
            const stem = base_with_ext[0..dot];
            if (version_mod.extractFromTitle(stem)) |guess| {
                const n = @min(guess.len, state.manual_install_version_buf.len - 1);
                @memcpy(state.manual_install_version_buf[0..n], guess[0..n]);
                state.manual_install_version_buf[n] = 0;
            }
        }
    }

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.card_fill,
        .color_border = style.border_color,
    });
    defer panel.deinit();

    dvui.label(@src(), "Install from file", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    settingsHelpText(
        "Point at any .zip / .7z / .tar.gz on disk and we'll extract it as a new install. " ++
            "The version is required and lives on the install row; the name is optional and lets " ++
            "you keep multiple installs of the same version apart (e.g. \"vanilla\", \"modded\").",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    manualInstallPathRow(frame);
    manualInstallRow("Version", &state.manual_install_version_buf, 2);
    manualInstallRow("Name (optional)", &state.manual_install_name_buf, 3);

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
    });
    defer btn_row.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (iconButton(@src(), "Cancel", entypo.cross, .{})) {
        state.manual_install_open = false;
    }
    if (iconButton(@src(), "Install", entypo.upload, .{ .style = .highlight })) {
        actions.startManualInstall(
            frame,
            game.f95_thread_id,
            state.manualInstallPathSlice(),
            state.manualInstallVersionSlice(),
            state.manualInstallNameSlice(),
        );
        // Only collapse the panel + clear the fields when the worker
        // accepted the job. `setDownloadMsg` is overwritten by
        // `startManualInstall` either way, so we use the panel state
        // to tell which side won.
        if (frame.state.manual_install_jobs) |list_ptr| {
            if (list_ptr.items.len > 0) {
                state.resetManualInstallFields();
                state.manual_install_open = false;
            }
        }
    }
}

/// Archive-path row for the manual-install panel — same shape as
/// `manualInstallRow` but with a Browse… button trailing the text
/// entry. Browse opens the OS-native file picker via dvui's
/// tinyfiledialogs wrapper; on cancel we leave whatever was typed
/// in place. The picker is filtered to archive extensions we know
/// how to extract.
fn manualInstallPathRow(frame: *Frame) void {
    const state = frame.state;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 1,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    dvui.label(@src(), "Archive path", .{}, .{
        .min_size_content = .{ .w = 120, .h = 22 },
        .gravity_y = 0.5,
        .color_text = HELP_TEXT_COLOR,
    });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.manual_install_path_buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 240, .h = 24 },
        .gravity_y = 0.5,
    });
    te.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    if (iconButton(@src(), "Browse\u{2026}", entypo.folder, .{
        .gravity_y = 0.5,
    })) {
        // NFDe blocks the UI thread until the user picks or cancels.
        // On Linux this routes through the XDG portal (no zenity
        // dependency); on Windows it's `IFileOpenDialog`; on macOS
        // `NSOpenPanel`. Filter specs are NFDe-style: comma-separated
        // extensions without dots / asterisks.
        const filters = [_]file_picker.FilterItem{
            .{ .name = "Archives", .spec = "zip,7z,tar.gz,tgz,rar" },
        };
        const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| blk: {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "File picker failed: {s}", .{@errorName(e)}) catch "File picker failed.";
            state.setDownloadMsg(msg);
            break :blk null;
        };
        if (picked) |p| {
            defer frame.lib.alloc.free(p);
            @memset(&state.manual_install_path_buf, 0);
            const n = @min(p.len, state.manual_install_path_buf.len - 1);
            @memcpy(state.manual_install_path_buf[0..n], p[0..n]);

            // Hash-based version pre-fill — one-shot at Browse click
            // (vs. per-frame so we don't re-hash on every render).
            // Capped at 500 MB so big game archives don't freeze the
            // UI; for those the filename heuristic in the panel's
            // auto-fill block handles it. Only fires when the user
            // hasn't already typed a version.
            if (state.manualInstallVersionSlice().len == 0) {
                if (actions.lookupVersionFromArchiveSha(frame, p)) |hit| {
                    defer frame.lib.alloc.free(hit);
                    const vn = @min(hit.len, state.manual_install_version_buf.len - 1);
                    @memcpy(state.manual_install_version_buf[0..vn], hit[0..vn]);
                    state.manual_install_version_buf[vn] = 0;
                }
            }
        }
    }
}

/// One labeled-row helper for the manual-install panel. Keeps the
/// three textEntry rows visually consistent (same label width, same
/// row height, same padding).
fn manualInstallRow(label: []const u8, buf: []u8, id_extra: u32) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    dvui.label(@src(), "{s}", .{label}, .{
        .min_size_content = .{ .w = 120, .h = 22 },
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 240, .h = 24 },
        .gravity_y = 0.5,
    });
    te.deinit();
}

/// Inline help block, toggled by the `?` icon on the action row.
/// Covers the toolbar actions in compact bullets — replaces the prior
/// Convert-only paragraph that didn't scale as the action set grew.
fn renderConvertHelp() void {
    var help = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.card_fill,
        .color_border = style.border_color,
    });
    defer help.deinit();

    dvui.label(@src(), "What the toolbar buttons do", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    const help_lines = [_][]const u8{
        "Launch / Stop - run or kill the picked install. Grayed when there's no install.",
        "Download - fetch the game via RPDL torrent (with donor-DDL fallback when you're logged in to F95).",
        "Manual install - point at a file you already downloaded and install it.",
        "Convert - extract + patch a Windows build into a Linux-native install. Idempotent.",
        "Folder - open the picked install's directory in your file manager.",
        "Saves / Backup - open or snapshot the per-game save directory.",
        "Mods - per-game mods page (queue installs, manage recipes, pick uninstall safety).",
    };
    for (help_lines) |line| {
        dvui.label(@src(), "- {s}", .{line}, .{
            .id_extra = std.hash.Wyhash.hash(0, line),
            .color_text = HELP_TEXT_COLOR,
        });
    }
}

/// End-of-batch "what got updated" popup. Shown after a Sync-all or
/// Updates check finishes, only when at least one library row's
/// version actually moved. Modeled on F95Checker's update recap so
/// the user has a single screen that summarizes "here's what you
/// might want to redownload."
///
/// Lifecycle: `actions.advanceSyncQueue` flips
/// `state.sync_recap_show = true` when the queue empties with at
/// least one entry; the user dismisses via the Close button (or by
/// clicking outside the floating window, which dvui handles).
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
        .warn => "\u{26A0} ",   // ⚠
        .err => "\u{2715} ",    // ✕
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
            const done = j.progress_done.load(.acquire);
            const total = j.progress_total.load(.acquire);
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

/// Split-button "Sync" — primary action runs the cheap
/// latest-updates walker; a chevron next to it opens a floating
/// menu where the user can pick either flavor explicitly. Lives
/// inside the library top bar.
///
/// The two controls are wrapped in a single `dvui.menu` so the
/// chevron's submenu can latch onto a stable anchor rect. The
/// primary button is rendered as a regular widget inside the
/// menu — dvui doesn't require every child of a `menu` to be a
/// `menuItem`.
fn renderSyncSplitButton(frame: *Frame) void {
    const state = frame.state;

    // Disabled while another sync-shaped worker is in flight. We
    // skip the disable for the chevron itself so the user can still
    // peek at the menu, but the menu items inside refuse to fire.
    const checking = state.pending_update_check != null;
    const importing = state.pending_bookmarks != null;
    const syncing = state.pending_sync != null or state.sync_queue != null;
    const busy = checking or importing or syncing;

    var bar = dvui.menu(@src(), .horizontal, .{});
    defer bar.deinit();

    // ----- primary half: "Check for updates" (default = updates walker) -----
    const primary_label: []const u8 = if (checking) "Checking\u{2026}" else "Check for updates";
    const primary_opts: dvui.Options = if (busy)
        .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } }
    else
        .{};
    if (iconButton(@src(), primary_label, entypo.cycle, primary_opts) and !busy) {
        actions.startUpdateCheck(frame);
    }

    // ----- chevron half: opens the scope menu -----
    // `menuItemIcon(.{ .submenu = true })` returns the anchor rect
    // when the item is active; we feed that to `floatingMenu` so
    // the dropdown is positioned right under the chevron. Using
    // an icon-shaped menu trigger (instead of a Unicode arrow
    // glyph) keeps it visually consistent with the rest of the
    // app's entypo icon set.
    if (dvui.menuItemIcon(@src(), "sync-scope", entypo.chevron_down, .{ .submenu = true }, .{
        // Match `iconButton`'s vertical metrics: same padding, and
        // let the icon size itself naturally so the chevron's
        // content row equals the icon+label row next to it.
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .min_size_content = style.icon_size,
        .gravity_y = 0.5,
        .background = true,
        .style = .control,
        .corner_radius = style.corner_radius,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        // Item 1 — updates-only (cheap walk; same as primary).
        if (dvui.menuItemLabel(@src(), "Check for updates since last run", .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (!busy) actions.startUpdateCheck(frame);
            bar.close();
        }

        // Item 2 — sync only the (unsynced) rows. Fast for a fresh
        // paste-import batch (no re-scrape of existing rows).
        if (dvui.menuItemLabel(@src(), "Sync all unsynced games", .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (!busy) actions.startSyncAllUnsynced(frame);
            bar.close();
        }

        // Item 3 — full-library re-scrape. Heavy: re-fetches every
        // game's thread. The menu placement makes the gravity of
        // that pick obvious.
        if (dvui.menuItemLabel(@src(), "Sync all games", .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (!busy) actions.startSyncAll(frame);
            bar.close();
        }
    }
}

/// "Add" split-button mirroring `renderSyncSplitButton`. Primary
/// click jumps to the paste-import screen (the everyday "add some
/// thread URLs" flow). The chevron menu carries the bigger-batch
/// option: pulling every F95 bookmark in one go. Both end at the
/// same import worker — the split exists so the bookmarks pull
/// stops needing its own top-bar slot (one fewer permanent button)
/// without burying it from logged-in users who use it regularly.
fn renderAddSplitButton(frame: *Frame) void {
    const state = frame.state;
    const logged_in = state.login_status == .logged_in;
    const pulling = state.pending_bookmarks != null;

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = 0xADD });
    defer bar.deinit();

    // ----- primary half: "Add" → paste-import screen -----
    if (iconButton(@src(), "Add", entypo.plus, .{})) {
        state.screen = .import;
    }

    // ----- chevron with submenu: paste / bookmarks pull -----
    if (dvui.menuItemIcon(@src(), "add-source", entypo.chevron_down, .{ .submenu = true }, .{
        // Heights + visual treatment tracked together with the Sync
        // chevron so both split buttons read as buttons next to the
        // plain iconButtons in the row, not as transparent affordances.
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .min_size_content = style.icon_size,
        .gravity_y = 0.5,
        .background = true,
        .style = .control,
        .corner_radius = style.corner_radius,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        // Item 1 — paste workflow (same as primary). Repeated so the
        // submenu reads as a complete listing of "how to add games".
        if (dvui.menuItemLabel(@src(), "Add by paste (URLs / thread IDs)…", .{}, .{
            .expand = .horizontal,
        }) != null) {
            state.screen = .import;
            bar.close();
        }

        // Item 2 — F95 bookmarks pull. Label tells the user *why*
        // it's unusable when it is: not logged in, or already running.
        const bookmarks_label: []const u8 = if (!logged_in)
            "Import all bookmarks (sign in to F95 first)"
        else if (pulling)
            "Pulling bookmarks\u{2026}"
        else
            "Import all bookmarks (F95)";
        if (dvui.menuItemLabel(@src(), bookmarks_label, .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (logged_in and !pulling) actions.startPullBookmarks(frame);
            bar.close();
        }
    }
}

fn renderBookmarksProgress(frame: *Frame) void {
    const state = frame.state;
    const pending = state.pending_bookmarks != null;
    const has_msg = !state.bookmarks_msg.isEmpty();
    if (!pending and !has_msg) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        .background = true,
        .style = .highlight,
    });
    defer bar.deinit();

    if (pending) {
        // Once cancel is requested, flip the banner to a "cancelling"
        // line + dim/disable the Cancel button so the click is
        // visibly acknowledged. The worker only observes the flag
        // between pages — a single in-flight page fetch can run for
        // several seconds, so without this the UI looks frozen.
        const cancelling: bool = blk: {
            const j = state.pending_bookmarks orelse break :blk false;
            break :blk j.cancel.load(.acquire);
        };

        const cur = state.bookmarks_progress_current;
        const tot = state.bookmarks_progress_total;
        var lbl_buf: [80]u8 = undefined;
        const label: []const u8 = if (cancelling)
            std.fmt.bufPrint(&lbl_buf, "Cancelling bookmarks pull\u{2026} (page {d})", .{cur}) catch "Cancelling\u{2026}"
        else if (tot > 0)
            std.fmt.bufPrint(&lbl_buf, "Pulling bookmarks: page {d}/{d}", .{ cur, tot }) catch "Pulling bookmarks…"
        else
            std.fmt.bufPrint(&lbl_buf, "Pulling bookmarks: page {d}…", .{cur}) catch "Pulling bookmarks…";
        dvui.label(@src(), "{s}", .{label}, .{ .gravity_y = 0.5 });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        // Manual progress bar — empty when total isn't known yet
        // (page-1 GET still in flight). Scoped in its own block so
        // the trailing spacer + Cancel button don't get nested inside
        // it (dvui's parent stack closes when the var goes out of
        // scope).
        const pct: u32 = if (tot > 0) @intCast(@min(@divTrunc(@as(u64, cur) * 100, @as(u64, tot)), 100)) else 0;
        {
            var bar_outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 240, .h = 14 },
                .border = style.border_thin,
                .corner_radius = .all(3),
                .color_border = style.border_color,
                .background = true,
                .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
                .gravity_y = 0.5,
            });
            defer bar_outer.deinit();
            if (pct > 0) {
                // ~240px usable width − 2px border each side = 236.
                // Fill = (pct/100) * 236.
                const fill_w: f32 = (@as(f32, @floatFromInt(pct)) * 236.0) / 100.0;
                var bar_inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{
                        .w = @max(2.0, fill_w),
                        .h = 10,
                    },
                    .background = true,
                    .color_fill = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
                    .corner_radius = .all(2),
                    .gravity_y = 0.5,
                });
                bar_inner.deinit();
            }
        }

        // Percentage label so the bar is meaningful even at low pct.
        if (tot > 0) {
            var pct_buf: [16]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "  {d}%", .{pct}) catch "";
            dvui.label(@src(), "{s}", .{pct_str}, .{ .gravity_y = 0.5 });
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (cancelling) {
            const dim: dvui.Options = .{
                .style = .control,
                .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
            };
            _ = iconButton(@src(), "Cancelling\u{2026}", entypo.cross, dim);
        } else {
            if (iconButton(@src(), "Cancel", entypo.cross, .{ .style = .err })) {
                actions.cancelBookmarks(frame);
            }
        }
    } else {
        // Post-pull result message — green-ish (highlight) on success,
        // red on cancel/error. Auto-hides on the next pull start.
        dvui.label(@src(), "{s}", .{state.bookmarksMsg()}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (iconOnly(@src(), "dismiss", entypo.cross, .{})) {
            state.bookmarks_msg.clear();
        }
    }
}

/// List-row pitch (px) used for the virtual-scroll math. The grid
/// row pitch is computed dynamically per frame from `gridLayout()`
/// since cards now scale with available width.
const LIST_ROW_PITCH: f32 = 56.0;
/// Render this many extra rows above + below the viewport so scrolling
/// never reveals an unrendered row.
const OVERSCAN_ROWS: usize = 2;

/// Virtualize the library scroll: only emit cards/rows for the
/// portion of the (filtered) list that's actually within the viewport
/// (plus an overscan band). Off-screen rows collapse to a single
/// spacer of equivalent height so the scrollbar tracks correctly.
fn renderVirtualizedList(frame: *Frame, games: []const library.Game, query: []const u8) void {
    const state = frame.state;

    const layout = if (state.view == .grid) gridLayout() else GridLayout{
        .cols = 1,
        .card_w = 0,
        .card_h = 0,
        .cover_h = 0,
    };
    const cols: usize = layout.cols;
    // Pitch = card outer footprint (body + padding + border + margin)
    // so the virtual scroll height matches what dvui actually lays out.
    const pitch: f32 = if (state.view == .grid)
        layout.card_h + CARD_CHROME_H
    else
        LIST_ROW_PITCH;

    // First pass: count filtered cards. Cheap (substring match against
    // each game's name + developer); ~µs per call so a few ms total
    // even on 10k-game libraries.
    var total_visible: usize = 0;
    for (games) |*g| if (cardVisible(state, g, query)) {
        total_visible += 1;
    };

    const total_rows: usize = (total_visible + cols - 1) / cols;
    const virtual_h: f32 = @max(@as(f32, @floatFromInt(total_rows)) * pitch, 1.0);

    // `.given` tells dvui to use our virtual_size.h verbatim instead of
    // computing from observed children — that's what makes the
    // scrollbar reflect the *full* list and not just the rows we
    // actually render this frame.
    state.lib_scroll_info.vertical = .given;
    state.lib_scroll_info.virtual_size.h = virtual_h;

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.lib_scroll_info,
    }, .{ .expand = .both });
    defer scroll.deinit();

    const viewport_y: f32 = state.lib_scroll_info.viewport.y;
    const viewport_h: f32 = @max(state.lib_scroll_info.viewport.h, 1.0);

    const overscan_px: f32 = @as(f32, @floatFromInt(OVERSCAN_ROWS)) * pitch;
    const visible_top: f32 = @max(0.0, viewport_y - overscan_px);
    const visible_bot: f32 = viewport_y + viewport_h + overscan_px;

    const first_row: usize = @intFromFloat(@floor(visible_top / pitch));
    const last_row_unclamped: usize = @intFromFloat(@ceil(visible_bot / pitch));
    const last_row: usize = @min(total_rows, last_row_unclamped);

    const start_idx: usize = first_row * cols;
    const end_idx: usize = @min(total_visible, last_row * cols);

    const top_spacer_h: f32 = @as(f32, @floatFromInt(first_row)) * pitch;
    const remaining_rows: usize = if (last_row < total_rows) total_rows - last_row else 0;
    const bot_spacer_h: f32 = @as(f32, @floatFromInt(remaining_rows)) * pitch;

    // Spacer above the rendered window. Width=1 + expand-horizontal so
    // it stretches to the scroll-container width without forcing extra
    // size. Height is what matters for the scrollbar.
    if (top_spacer_h > 0.5) {
        _ = dvui.spacer(@src(), .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = top_spacer_h },
        });
    }

    switch (state.view) {
        .grid => renderGridWindow(frame, games, query, layout, start_idx, end_idx),
        .list => renderListWindow(frame, games, query, start_idx, end_idx),
    }

    if (bot_spacer_h > 0.5) {
        _ = dvui.spacer(@src(), .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = bot_spacer_h },
        });
    }
}

fn sidebar(state: *State) void {
    // Outer box holds the sticky "Filters" header so it doesn't
    // scroll out of view; the inner scrollArea takes everything
    // below the header. Engine + Tag lists can easily run >40
    // checkboxes; without scrolling the sidebar would clip them.
    var side = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 200, .h = 100 },
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
        .background = true,
        .expand = .vertical,
    });
    defer side.deinit();

    dvui.label(@src(), "Filters", .{}, .{});
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
    });
    defer scroll.deinit();

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "Sync:", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 80, .h = 1 } });
        const sync_labels = &[_][]const u8{ "All", "Synced", "Unsynced" };
        var picked: usize = @intFromEnum(state.filters.sync_state);
        if (style.dropdown(@src(), sync_labels, .{ .choice = &picked }, .{}, .{})) {
            state.filters.sync_state = @enumFromInt(picked);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 0xF11 });
        defer row.deinit();
        dvui.label(@src(), "Installed:", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 80, .h = 1 } });
        const inst_labels = &[_][]const u8{ "All", "Installed", "Not installed" };
        var picked: usize = @intFromEnum(state.filters.installed);
        if (style.dropdown(@src(), inst_labels, .{ .choice = &picked }, .{}, .{ .id_extra = 0xF11 })) {
            state.filters.installed = @enumFromInt(picked);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Engine — foldable. Header reads "Engine (N)" when any filter is
    // active so the user can see what's selected without expanding.
    {
        const eng = &state.filters.engine;
        const active: usize = countActiveEngine(eng);
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (active == 0)
            @as([]const u8, "Engine")
        else
            std.fmt.bufPrint(&lbl_buf, "Engine ({d})", .{active}) catch "Engine";
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            _ = dvui.checkbox(@src(), &eng.renpy, "Ren'Py", .{});
            _ = dvui.checkbox(@src(), &eng.rpgm_mv, "RPGM MV", .{});
            _ = dvui.checkbox(@src(), &eng.rpgm_mz, "RPGM MZ", .{});
            _ = dvui.checkbox(@src(), &eng.rpgm_vx, "RPGM VX/Ace", .{});
            _ = dvui.checkbox(@src(), &eng.unity, "Unity", .{});
            _ = dvui.checkbox(@src(), &eng.unreal, "Unreal", .{});
            _ = dvui.checkbox(@src(), &eng.html, "HTML", .{});
            _ = dvui.checkbox(@src(), &eng.flash, "Flash", .{});
            _ = dvui.checkbox(@src(), &eng.java, "Java", .{});
            _ = dvui.checkbox(@src(), &eng.wolf_rpg, "Wolf RPG", .{});
            _ = dvui.checkbox(@src(), &eng.qsp, "QSP", .{});
            _ = dvui.checkbox(@src(), &eng.tyranobuilder, "TyranoBuilder", .{});
            _ = dvui.checkbox(@src(), &eng.twine, "Twine", .{});
            _ = dvui.checkbox(@src(), &eng.other, "Other", .{});
            _ = dvui.checkbox(@src(), &eng.unknown, "Unknown", .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Status — foldable, same pattern.
    {
        const st = &state.filters.status;
        const active: usize = countActiveStatus(st);
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (active == 0)
            @as([]const u8, "Status")
        else
            std.fmt.bufPrint(&lbl_buf, "Status ({d})", .{active}) catch "Status";
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            _ = dvui.checkbox(@src(), &st.not_started, "Not started", .{});
            _ = dvui.checkbox(@src(), &st.in_queue, "In queue", .{});
            _ = dvui.checkbox(@src(), &st.in_progress, "In progress", .{});
            _ = dvui.checkbox(@src(), &st.completed, "Completed", .{});
            _ = dvui.checkbox(@src(), &st.replaying, "Replaying", .{});
            _ = dvui.checkbox(@src(), &st.abandoned, "Abandoned", .{});
            _ = dvui.checkbox(@src(), &st.waiting_for_update, "Waiting for update", .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Min rating — foldable. Header shows the chosen threshold inline
    // when active, so the user sees `Min rating (4+)` at a glance.
    {
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (state.filters.min_rating) |r|
            std.fmt.bufPrint(&lbl_buf, "Min rating ({d:.1}+)", .{r}) catch "Min rating"
        else
            @as([]const u8, "Min rating");
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();
            if (style.button(@src(), "Any", .{}, .{})) state.filters.min_rating = null;
            if (style.button(@src(), "3+", .{}, .{})) state.filters.min_rating = 3.0;
            if (style.button(@src(), "4+", .{}, .{})) state.filters.min_rating = 4.0;
            if (style.button(@src(), "4.5+", .{}, .{})) state.filters.min_rating = 4.5;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Developer text filter — substring match against `Game.developer`.
    {
        const dev_q = state.filters.developerSlice();
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (dev_q.len > 0)
            std.fmt.bufPrint(&lbl_buf, "Developer ({s})", .{dev_q}) catch "Developer"
        else
            @as([]const u8, "Developer");
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.filters.developer_buf },
                .placeholder = "filter by dev…",
            }, .{ .expand = .horizontal });
            te.deinit();
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Game state (dev_status) — what F95 reports about the game's
    // release progress: completed / abandoned / on hold / etc.
    {
        const ds = &state.filters.dev_status;
        const active: usize = countActiveDevStatus(ds);
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (active == 0)
            @as([]const u8, "Game state")
        else
            std.fmt.bufPrint(&lbl_buf, "Game state ({d})", .{active}) catch "Game state";
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            _ = dvui.checkbox(@src(), &ds.in_progress, "Ongoing", .{});
            _ = dvui.checkbox(@src(), &ds.completed, "Completed", .{});
            _ = dvui.checkbox(@src(), &ds.on_hold, "On hold", .{});
            _ = dvui.checkbox(@src(), &ds.abandoned, "Abandoned", .{});
            _ = dvui.checkbox(@src(), &ds.orphaned, "Orphaned (gone from F95)", .{});
            _ = dvui.checkbox(@src(), &ds.unknown, "Unknown", .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Censored — value from the OP's "Censored:" line. Same multi-
    // checkbox pattern as engine / dev state.
    {
        const cs = &state.filters.censored;
        const active: usize = countActiveCensored(cs);
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (active == 0)
            @as([]const u8, "Censored")
        else
            std.fmt.bufPrint(&lbl_buf, "Censored ({d})", .{active}) catch "Censored";
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            _ = dvui.checkbox(@src(), &cs.no, "No", .{});
            _ = dvui.checkbox(@src(), &cs.yes, "Yes", .{});
            _ = dvui.checkbox(@src(), &cs.partial, "Partial", .{});
            _ = dvui.checkbox(@src(), &cs.unknown, "Unknown", .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Tags — checkbox-driven. The comma-separated buffer remains the
    // source of truth (so the existing `Filters.match` logic stays
    // unchanged); the UI just reads/writes the buffer via tag
    // include/exclude helpers. Falls back to a text input when the
    // master tag list hasn't been refreshed yet — that way the user
    // isn't blocked.
    {
        const inc_q = state.filters.tagIncludeSlice();
        const exc_q = state.filters.tagExcludeSlice();
        const inc_count = tagListCount(inc_q);
        const exc_count = tagListCount(exc_q);
        var lbl_buf: [64]u8 = undefined;
        const lbl: []const u8 = if (inc_count > 0 and exc_count > 0)
            std.fmt.bufPrint(&lbl_buf, "Tags (+{d} / −{d})", .{ inc_count, exc_count }) catch "Tags"
        else if (inc_count > 0)
            std.fmt.bufPrint(&lbl_buf, "Tags (+{d})", .{inc_count}) catch "Tags"
        else if (exc_count > 0)
            std.fmt.bufPrint(&lbl_buf, "Tags (−{d})", .{exc_count}) catch "Tags"
        else
            @as([]const u8, "Tags");
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            if (state.tags_master.len == 0) {
                dvui.label(@src(),
                    "Master tag list not refreshed yet. Open Settings → Library → Tags → Refresh.",
                    .{},
                    .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } },
                );
            } else {
                renderTagCheckboxFilter(state);
            }
        }
    }
}

/// Number of non-empty comma-separated entries in a tag-list buffer.
/// Empty buffer → 0. Trailing/leading commas are ignored.
fn tagListCount(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len > 0) n += 1;
    }
    return n;
}

/// True when `tag` appears (case-insensitive, whole-entry match) in
/// the comma-separated buffer.
fn tagListContains(buf: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, buf, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(t, tag)) return true;
    }
    return false;
}

/// Append `tag` to the comma-separated buffer (only when not already
/// present). Mutates `buf` in place; preserves a NUL terminator so
/// dvui's textEntry rendering keeps working in the fallback path.
fn addTagToBuf(buf: []u8, tag: []const u8) void {
    if (tagListContains(sliceUntilNul(buf), tag)) return;
    const cur_len = sliceUntilNul(buf).len;
    const sep_len: usize = if (cur_len == 0) 0 else 2; // ", "
    if (cur_len + sep_len + tag.len + 1 > buf.len) return; // no room
    var write_at = cur_len;
    if (sep_len > 0) {
        buf[write_at] = ',';
        buf[write_at + 1] = ' ';
        write_at += 2;
    }
    @memcpy(buf[write_at .. write_at + tag.len], tag);
    write_at += tag.len;
    // Zero the rest so `sliceUntilNul` finds the new end correctly.
    @memset(buf[write_at..], 0);
}

/// Remove every case-insensitive entry equal to `tag` from `buf`.
/// Rewrites the comma-separated list in place. Surrounding spaces +
/// separators are normalised on the way out so a remove never leaves
/// dangling `", , foo"` artifacts.
fn removeTagFromBuf(buf: []u8, tag: []const u8) void {
    var scratch: [256]u8 = undefined;
    var n: usize = 0;
    const cur = sliceUntilNul(buf);
    var it = std.mem.splitScalar(u8, cur, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(t, tag)) continue;
        if (n > 0) {
            if (n + 2 > scratch.len) break;
            scratch[n] = ',';
            scratch[n + 1] = ' ';
            n += 2;
        }
        if (n + t.len > scratch.len) break;
        @memcpy(scratch[n .. n + t.len], t);
        n += t.len;
    }
    if (n > buf.len) n = buf.len;
    @memcpy(buf[0..n], scratch[0..n]);
    @memset(buf[n..], 0);
}

/// Sentinel-trimmed view of a fixed-size text buffer.
fn sliceUntilNul(buf: []const u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) : (n += 1) {}
    return buf[0..n];
}

/// Render the include/exclude checkbox filter for tags. The body
/// inside an `dvui.expander` already runs in the sidebar's
/// scroll-area, so a nested scrollArea is unnecessary; we cap the
/// rendered set via the quick-filter to keep the click area
/// manageable when there are 200+ tags.
fn renderTagCheckboxFilter(state: *State) void {
    // Quick filter row.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.icon(@src(), "search", entypo.magnifying_glass, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.tags_filter_buf },
            .placeholder = "filter tags…",
        }, .{ .expand = .horizontal, .gravity_y = 0.5 });
        te.deinit();
    }

    const filter = sliceUntilNul(&state.tags_filter_buf);

    // Two-column legend: ✓ include · ✗ exclude. Each tag row shows
    // a tristate marker the user clicks to cycle:
    //   off → include → exclude → off
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    dvui.label(@src(),
        "Click to cycle: off → include → exclude → off",
        .{},
        .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    // Cap on rows rendered per frame so a stray empty filter on a
    // 1000-tag list doesn't tank frame time. The user can narrow
    // with the filter input above to see the rest.
    const HARD_CAP: usize = 200;
    var rendered: usize = 0;

    for (state.tags_master, 0..) |tag, i| {
        if (filter.len > 0 and !types.asciiContainsIgnoreCase(tag, filter)) continue;
        if (rendered >= HARD_CAP) break;
        rendered += 1;

        const include_buf: []const u8 = sliceUntilNul(&state.filters.tag_include_buf);
        const exclude_buf: []const u8 = sliceUntilNul(&state.filters.tag_exclude_buf);
        const in_include = tagListContains(include_buf, tag);
        const in_exclude = tagListContains(exclude_buf, tag);

        const marker: []const u8 = if (in_include) "[+] " else if (in_exclude) "[-] " else "[ ] ";
        const text_color: dvui.Color = if (in_include)
            .{ .r = 0x6F, .g = 0xC8, .b = 0x7A } // green
        else if (in_exclude)
            .{ .r = 0xE9, .g = 0x4B, .b = 0x7A } // red
        else
            .{ .r = 0xC0, .g = 0xA0, .b = 0xB8 };

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
        defer row.deinit();

        var line_buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ marker, tag }) catch tag;
        if (style.button(@src(), line, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .gravity_x = 0,
            .style = .control,
            .color_text = text_color,
        })) {
            if (in_include) {
                removeTagFromBuf(&state.filters.tag_include_buf, tag);
                addTagToBuf(&state.filters.tag_exclude_buf, tag);
            } else if (in_exclude) {
                removeTagFromBuf(&state.filters.tag_exclude_buf, tag);
            } else {
                addTagToBuf(&state.filters.tag_include_buf, tag);
            }
        }
    }

    if (rendered >= HARD_CAP) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        var more_buf: [80]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "showing first {d} matches — narrow with the filter above", .{HARD_CAP}) catch "…";
        dvui.label(@src(), "{s}", .{more}, .{
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }

    // Reset row — clears both lists in one click.
    if (tagListCount(sliceUntilNul(&state.filters.tag_include_buf)) > 0 or
        tagListCount(sliceUntilNul(&state.filters.tag_exclude_buf)) > 0)
    {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        if (style.button(@src(), "Clear tag filters", .{}, .{ .expand = .horizontal })) {
            @memset(&state.filters.tag_include_buf, 0);
            @memset(&state.filters.tag_exclude_buf, 0);
        }
    }
}

fn countActiveEngine(e: *const state_mod.Filters.EngineMask) usize {
    var n: usize = 0;
    inline for (@typeInfo(state_mod.Filters.EngineMask).@"struct".fields) |f| {
        if (f.type == bool and @field(e, f.name)) n += 1;
    }
    return n;
}

fn countActiveStatus(s: *const state_mod.Filters.StatusMask) usize {
    var n: usize = 0;
    inline for (@typeInfo(state_mod.Filters.StatusMask).@"struct".fields) |f| {
        if (f.type == bool and @field(s, f.name)) n += 1;
    }
    return n;
}

fn countActiveDevStatus(s: *const state_mod.Filters.DevStatusMask) usize {
    var n: usize = 0;
    inline for (@typeInfo(state_mod.Filters.DevStatusMask).@"struct".fields) |f| {
        if (f.type == bool and @field(s, f.name)) n += 1;
    }
    return n;
}

fn countActiveCensored(s: *const state_mod.Filters.CensoredMask) usize {
    var n: usize = 0;
    inline for (@typeInfo(state_mod.Filters.CensoredMask).@"struct".fields) |f| {
        if (f.type == bool and @field(s, f.name)) n += 1;
    }
    return n;
}

/// Card width bounds (excluding the card's own padding+border+margin).
/// Cards stretch freely between MIN and MAX; column count is the
/// smallest N such that `usable_w / N <= MAX_CARD_W + chrome`. When
/// `usable_w` would push cards past MAX, we add another column and
/// all cards drop back toward MIN.
const MIN_CARD_W: f32 = 240.0;
const MAX_CARD_W: f32 = 360.0;

/// Per-card chrome — padding (4 each side) + border (1 each side) +
/// margin (3 each side) — totals 16 px horizontally. dvui's outer
/// footprint per child = `min_size_content.w + chrome`, so the
/// column-count math has to subtract this from the available width
/// before dividing.
///
/// Keep this in sync with renderCard's box options. If you change
/// padding/border/margin there, change this too — otherwise cards
/// will overflow the row by `cols * delta` pixels and dvui shrinks
/// the rightmost card to fit (looks like "right column is smaller").
const CARD_CHROME_W: f32 = 4 + 4 + 1 + 1 + 3 + 3;
/// Same idea for vertical chrome — only used to keep `GRID_ROW_PITCH`
/// honest with the actual rendered row height.
const CARD_CHROME_H: f32 = 4 + 4 + 1 + 1 + 3 + 3;

/// Sidebar + separator + main padding. Subtracted from window width
/// before dividing by card pitch.
const NON_GRID_WIDTH: f32 = 240.0;

/// Cover-area height as a fraction of card WIDTH. Bumped from
/// 90/280 ≈ 0.32 to 120/280 ≈ 0.43 so the cover takes a clearly
/// larger share of the card without changing card_w. F95 banners
/// crop tall comfortably at 16:7-ish.
const COVER_H_PER_W: f32 = 120.0 / 280.0;

/// Fixed height (in layout units) for the title + developer + meta
/// row + their gaps + the card's vertical padding. Independent of
/// card_w because labels don't shrink with the card. This is what
/// makes card_h = (card_w * COVER_H_PER_W) + CARD_TEXT_CHROME_H —
/// without this fixed term, narrow cards clip the bottom meta row.
/// The label `max_size_content.h` values are caps, not exact heights:
/// the body × 0.85 font lands closer to ~12 logical px per line, so
/// the prior 64 left ~12 px of dead space below the meta row.
/// Tightened to 50 (4 pad + 2 spacer + ~15 title + ~12 author + 2
/// meta gap + ~12 meta + 4 pad = ~51, rounded down by 1 for absolute
/// tightness; labels still fit because their cap is the upper bound).
const CARD_TEXT_CHROME_H: f32 = 50.0;

const GridLayout = struct {
    cols: usize,
    card_w: f32,
    card_h: f32,
    cover_h: f32,
};

fn gridLayout() GridLayout {
    const win_w = dvui.windowRect().w;
    const usable = @max(win_w - NON_GRID_WIDTH, MIN_CARD_W + CARD_CHROME_W);

    // Column count: smallest N such that the card body fits within
    // MAX_CARD_W. The slot is `card_w + chrome`, so the cap is
    // `MAX_CARD_W + CARD_CHROME_W`.
    const slot_w_max = MAX_CARD_W + CARD_CHROME_W;
    var cols: usize = @intFromFloat(@ceil(usable / slot_w_max));
    if (cols < 1) cols = 1;
    if (cols > 12) cols = 12;

    // slot_w = usable / cols. Card body = slot - chrome, clamped.
    // After clamping, all cards share the same body width — and
    // because we use the actual chrome value, `cols * (card_w + chrome)
    // == usable`, so the rightmost card never gets shrunk by dvui.
    const slot_w = usable / @as(f32, @floatFromInt(cols));
    var card_w = slot_w - CARD_CHROME_W;
    if (card_w < MIN_CARD_W) card_w = MIN_CARD_W;
    if (card_w > MAX_CARD_W) card_w = MAX_CARD_W;
    // Card height = scaling cover + fixed text chrome. The text area
    // doesn't shrink with the card, so labels never get clipped at
    // narrow widths.
    const cover_h = card_w * COVER_H_PER_W;
    const card_h = cover_h + CARD_TEXT_CHROME_H;
    return .{ .cols = cols, .card_w = card_w, .card_h = card_h, .cover_h = cover_h };
}

/// Walk the filtered list, render only cards whose filtered index is
/// in `[start_idx, end_idx)`. Out-of-window cards (the vast majority
/// for any sizeable library) cost just a `cardVisible` substring
/// match — no widget creation, no cover lookup.
fn renderGridWindow(
    frame: *Frame,
    games: []const library.Game,
    query: []const u8,
    layout: GridLayout,
    start_idx: usize,
    end_idx: usize,
) void {
    const cols = layout.cols;
    var f_idx: usize = 0;
    var row_box: ?*dvui.BoxWidget = null;
    defer if (row_box) |rb| rb.deinit();

    for (games) |*g| {
        if (!cardVisible(frame.state, g, query)) continue;
        const my_idx = f_idx;
        f_idx += 1;

        if (my_idx < start_idx) continue;
        if (my_idx >= end_idx) break;

        const col = my_idx % cols;
        if (col == 0) {
            if (row_box) |rb| rb.deinit();
            // Use the absolute row number as `id_extra` so each row
            // box has a stable id even though we're rendering only a
            // window into the full list.
            row_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = my_idx / cols,
                .expand = .horizontal,
            });
        }
        renderCard(frame, g, layout);
    }
}

fn renderListWindow(
    frame: *Frame,
    games: []const library.Game,
    query: []const u8,
    start_idx: usize,
    end_idx: usize,
) void {
    const state = frame.state;
    var f_idx: usize = 0;
    for (games) |*g| {
        if (!cardVisible(state, g, query)) continue;
        const my_idx = f_idx;
        f_idx += 1;

        if (my_idx < start_idx) continue;
        if (my_idx >= end_idx) break;

        // Whole row is the click target — open detail on press anywhere.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = g.f95_thread_id,
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer row.deinit();

        // Banner thumb in front of the title. F95 banners are wide;
        // 120×40 (3:1) reads well at row scale and matches typical
        // banner aspect closely enough that letterboxing is minimal.
        renderListThumb(actions.coverBytes(frame, g.f95_thread_id), g.f95_thread_id);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });

        // Engine pill — same per-engine fill + short label as the
        // grid-view badge, just sized to sit inline with the row
        // text. `engineShortLabel` keeps the chip narrow even for
        // longer engine names like "RPGM MV".
        if (g.engine != .unknown) {
            const fill = engineBadgeColor(g.engine);
            var eng_pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = g.f95_thread_id,
                .gravity_y = 0.5,
                .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                .corner_radius = .all(2),
                .background = true,
                .color_fill = fill,
                .color_border = fill,
                .border = style.border_thin,
            });
            defer eng_pill.deinit();
            const body = dvui.Font.theme(.body);
            dvui.label(@src(), "{s}", .{engineShortLabel(g.engine)}, .{
                .gravity_y = 0.5,
                .gravity_x = 0.5,
                .color_text = dvui.Color.white,
                .font = body.withSize(body.size * 0.75),
            });
        }

        if (g.dev_status != .unknown) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            const fill = devStatusColor(g.dev_status);
            var st_pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = g.f95_thread_id ^ 0xD5,
                .gravity_y = 0.5,
                .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                .corner_radius = .all(2),
                .background = true,
                .color_fill = fill,
                .color_border = fill,
                .border = style.border_thin,
            });
            defer st_pill.deinit();
            const body = dvui.Font.theme(.body);
            dvui.label(@src(), "{s}", .{devStatusShortLabel(g.dev_status)}, .{
                .gravity_y = 0.5,
                .gravity_x = 0.5,
                .color_text = dvui.Color.white,
                .font = body.withSize(body.size * 0.75),
            });
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

        // Title takes the flexible middle column. `expand = .horizontal`
        // + a zero min-content width lets dvui clip the label inside
        // the available box on narrow windows; without this the
        // natural-width label would push rating/version off the
        // right edge whenever a long game name landed in a short row.
        dvui.label(@src(), "{s}", .{g.name}, .{
            .gravity_y = 0.5,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
        });

        // Rating: proper star icon (item 8). Falls back to "—" when
        // unrated. Same shape as the grid card meta row.
        if (g.rating) |r| {
            dvui.icon(@src(), "rating-star", entypo.star, .{}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 14, .h = 14 },
                .color_text = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
            });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            var rate_buf: [16]u8 = undefined;
            const rate_str = std.fmt.bufPrint(&rate_buf, "{d:.1}", .{r}) catch "?";
            dvui.label(@src(), "{s}", .{rate_str}, .{ .gravity_y = 0.5 });
        } else {
            dvui.label(@src(), "—", .{}, .{ .gravity_y = 0.5 });
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        const ver = if (g.latest_version) |v| v else "—";
        dvui.label(@src(), "{s}", .{ver}, .{ .gravity_y = 0.5 });

        // Install-state dot at the row tail. Mirrors the grid card.
        const dot_state = actions.installDotState(frame, g);
        if (dot_state != .none) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
            const fill: dvui.Color = switch (dot_state) {
                .up_to_date => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 },
                .outdated => .{ .r = 0xC0, .g = 0x84, .b = 0x1F },
                .none => unreachable,
            };
            const tip: []const u8 = switch (dot_state) {
                .up_to_date => "Installed",
                .outdated => "Installed (update available)",
                .none => unreachable,
            };
            const diameter: f32 = 10;
            var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = g.f95_thread_id ^ 0xAA77,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = diameter, .h = diameter },
                .max_size_content = .{ .w = diameter, .h = diameter },
                .corner_radius = .all(diameter / 2),
                .background = true,
                .color_fill = fill,
                .color_border = fill,
                .border = style.border_thin,
            });
            dvui.tooltip(@src(), .{
                .active_rect = dot.data().borderRectScale().r,
            }, "{s}", .{tip}, .{ .id_extra = g.f95_thread_id ^ 0xAA77 });
            dot.deinit();
        }

        if (dvui.clicked(row.data(), .{})) {
            state.screen = .detail;
            state.selected_thread = g.f95_thread_id;
        }
    }
}

/// Human-friendly labels for `library.CompletionStatus`. Indices line
/// up with `@intFromEnum(CompletionStatus)` so the dropdown can map
/// back via `@enumFromInt`.
fn completionStatusLabels() []const []const u8 {
    const labels = &[_][]const u8{
        "Not started",
        "In queue",
        "In progress",
        "Completed",
        "Replaying",
        "Abandoned",
        "Waiting for update",
    };
    return labels;
}

/// Human-friendly label for a single CompletionStatus value.
fn completionStatusLabel(s: library.CompletionStatus) []const u8 {
    return completionStatusLabels()[@intFromEnum(s)];
}

/// Render a unix-seconds timestamp as `YYYY-MM-DD HH:MM` UTC. No
/// seconds — matches the granularity F95 publishes in its OP info
/// block so the detail page reads consistently.
fn formatUtcDateTime(buf: []u8, ts: i64) ![]const u8 {
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

/// Pretty sandbox-override label — no underscores.
fn sandboxLabel(s: library.SandboxOverride) []const u8 {
    return switch (s) {
        .use_default => "use default",
        .always => "always",
        .never => "never",
    };
}

/// Short ASCII source-of-install tag prepended to install picker
/// entries so the user can tell at a glance whether an install is
/// recipe-fetched (auto-updatable), RPDL torrent (auto-updatable),
/// or hand-installed from a local archive (manual update only).
/// Recipe entries get no prefix — they're the default and the most
/// common case.
fn sourceTag(s: library.InstallSource) []const u8 {
    return switch (s) {
        .recipe => "",
        .manual => "[file] ",
        .rpdl => "[rpdl] ",
        .imported => "[imported] ",
    };
}

/// Human-friendly engine name for the list-view engine pill.
fn engineLabel(e: library.Engine) []const u8 {
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
        .wolf_rpg => "Wolf RPG",
        .qsp => "QSP",
        .tyranobuilder => "Tyrano",
        .twine => "Twine",
        .other => "Other",
        .unknown => "?",
    };
}

/// Banner-shaped thumbnail for list rows. Sized ~3:1 to roughly
/// match typical F95 cover banner aspect.
fn renderListThumb(bytes_opt: ?[]const u8, thread_id: u64) void {
    const w: f32 = 120;
    const h: f32 = 40;
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = "list-thumb" } },
            .shrink = .ratio,
        }, .{
            .id_extra = thread_id,
            .min_size_content = .{ .w = w, .h = h },
            .gravity_y = 0.5,
            .corner_radius = .all(3),
            .border = style.border_thin,
            .color_border = style.border_color,
        });
        return;
    }
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = thread_id,
        .min_size_content = .{ .w = w, .h = h },
        .gravity_y = 0.5,
        .background = true,
        .corner_radius = .all(3),
        .border = style.border_thin,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.border_color,
    });
    defer slot.deinit();
}

fn cardVisible(state: *const State, g: *const library.Game, query: []const u8) bool {
    if (query.len > 0) {
        const name_match = types.asciiContainsIgnoreCase(g.name, query);
        const dev_match = if (g.developer) |d| types.asciiContainsIgnoreCase(d, query) else false;
        const desc_match = if (g.description_md) |d| types.asciiContainsIgnoreCase(d, query) else false;
        if (!name_match and !dev_match and !desc_match) return false;
    }
    if (!state.filters.match(g)) return false;

    // Installed-state filter. Consults the frame-local installed-set
    // built once at the top of `libraryScreen`. Looking up the
    // pointer is null-safe — if the set was never built (e.g. first
    // frame on an empty library) we treat every row as not-installed.
    switch (state.filters.installed) {
        .all => {},
        .installed => {
            if (state.installed_set == null) return false;
            const set: *const std.AutoHashMap(u64, void) = @ptrCast(@alignCast(state.installed_set.?));
            if (!set.contains(g.f95_thread_id)) return false;
        },
        .not_installed => {
            if (state.installed_set) |p| {
                const set: *const std.AutoHashMap(u64, void) = @ptrCast(@alignCast(p));
                if (set.contains(g.f95_thread_id)) return false;
            }
        },
    }
    return true;
}

/// Static card dimensions — every card is exactly this size in the grid.
/// Combined with `min_size_content == max_size_content`, dvui won't
/// stretch a card to fill leftover row space — except now the card
/// dims are computed per frame from `gridLayout()`, so cards within
/// a frame all share the same size.
fn renderCard(frame: *Frame, g: *const library.Game, layout: GridLayout) void {
    const state = frame.state;
    // Vertical card: full-width banner cover on top, name + meta below.
    // The whole card is the click target for opening detail — no
    // dedicated "Open" button.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = g.f95_thread_id,
        .background = true,
        .border = style.border_thin,
        .corner_radius = .all(6),
        .min_size_content = .{ .w = layout.card_w, .h = layout.card_h },
        .max_size_content = .{ .w = layout.card_w, .h = layout.card_h },
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .color_fill = style.card_fill,
        .color_border = style.border_color,
    });
    defer card.deinit();

    const install_state = actions.installDotState(frame, g);

    renderCardCover(
        actions.coverBytes(frame, g.f95_thread_id),
        g.f95_thread_id,
        g.engine,
        g.dev_status,
        layout,
    );

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 2 } });

    // Title row: title text fills the line, install-state dot anchored
    // to the right (top-right of the text area). The title's
    // `expand = .horizontal` pushes the dot to the row's far end.
    var name_buf: [80]u8 = undefined;
    const name_disp = truncEllipsis(&name_buf, g.name, 52);
    const heading = dvui.Font.theme(.heading);
    const title_font = heading.withSize(heading.size * style.title_font_scale);
    {
        var title_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = g.f95_thread_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer title_row.deinit();
        dvui.label(@src(), "{s}", .{name_disp}, .{
            .expand = .horizontal,
            .max_size_content = .{ .w = 0, .h = 20 },
            .font = title_font,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        });
        if (install_state != .none) renderInstallDot(g.f95_thread_id, install_state);
    }

    // Author / studio under the title — smaller font, zero padding so
    // it sits flush against the title.
    if (g.developer) |dev| {
        const body = dvui.Font.theme(.body);
        const dev_font = body.withSize(body.size * style.meta_font_scale);
        dvui.label(@src(), "{s}", .{dev}, .{
            .expand = .horizontal,
            .max_size_content = .{ .w = 0, .h = 14 },
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
            .font = dev_font,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
    }

    var meta_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = g.f95_thread_id,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
    });
    defer meta_row.deinit();

    // Version on the left, rating on the right (swap of the earlier
    // layout — request from round 45). Zero label padding so the row
    // sits flush under the author line.
    const meta_body = dvui.Font.theme(.body);
    const meta_font = meta_body.withSize(meta_body.size * style.meta_font_scale);
    const meta_opts: dvui.Options = .{
        .gravity_y = 0.5,
        .font = meta_font,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    if (g.latest_version) |v| {
        dvui.label(@src(), "v{s}", .{v}, meta_opts);
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    if (g.rating) |r| {
        dvui.icon(@src(), "rating-star", entypo.star, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
            .color_text = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 3, .h = 1 } });

        var rate_buf: [40]u8 = undefined;
        const rate_str = if (g.vote_count) |c|
            std.fmt.bufPrint(&rate_buf, "{d:.1}  ({d})", .{ r, c }) catch "?"
        else
            std.fmt.bufPrint(&rate_buf, "{d:.1}", .{r}) catch "?";
        dvui.label(@src(), "{s}", .{rate_str}, meta_opts);
    } else {
        dvui.label(@src(), "(unrated)", .{}, meta_opts);
    }

    if (dvui.clicked(card.data(), .{})) {
        state.screen = .detail;
        state.selected_thread = g.f95_thread_id;
    }
}

/// Truncate `s` to roughly `max` bytes and append an ellipsis (`…` —
/// single visible char, 3 bytes UTF-8). Returns the original slice
/// when it already fits. Otherwise walks back from `max` to the
/// previous UTF-8 code-point boundary so we never slice in the middle
/// of a multi-byte sequence (dvui's renderText asserts via
/// `unreachable` on invalid UTF-8 and panics in Debug).
fn truncEllipsis(buf: []u8, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (buf.len < max + 3) return s;
    // Snap `cut` down to a UTF-8 leading byte (top two bits != 10).
    var cut: usize = max;
    while (cut > 0) {
        const b = s[cut];
        if ((b & 0b1100_0000) != 0b1000_0000) break;
        cut -= 1;
    }
    @memcpy(buf[0..cut], s[0..cut]);
    // U+2026 → E2 80 A6
    buf[cut] = 0xE2;
    buf[cut + 1] = 0x80;
    buf[cut + 2] = 0xA6;
    return buf[0 .. cut + 3];
}

/// Plan for rendering a source image into the cover slot. The grid
/// has a single banner-shape slot (~2.33:1) but F95 covers come in
/// wildly different aspects (cinematic 4:1, square 1:1, portrait 2:3).
/// We pick a tier based on how far the source aspect is from target:
///
///   - .cover_center : aspect close to target → CSS `object-fit: cover`
///                     centered crop. Loses ≤25% on the off-axis.
///   - .cover_top    : source is mildly tall (e.g. 1.4:1 onto a
///                     2.33:1 slot) → cover-crop but bias the y origin
///                     toward the top so faces / titles stay in frame.
///   - .fit_backdrop : source is squarer / portrait → render the image
///                     twice: a stretched-darkened backdrop fills the
///                     whole slot, then the aspect-preserved image
///                     centers on top. Whole image visible, slot fully
///                     filled, no jarring letterbox bars.
const CoverFit = union(enum) {
    cover_center: dvui.Rect, // UV rect for the cover-fit draw
    cover_top: dvui.Rect,
    fit_backdrop: void,
    // Vertical-dominant (portrait/square) source. Letterbox with a
    // 1.25× zoom from pure height-fit: the UV crops the top/bottom
    // 10% of the source so the visible aspect is `src_aspect * 1.25`,
    // narrowing the side bars without stretching the artwork.
    zoom_height: dvui.Rect,
};

/// Decide which CoverFit treatment a (source_aspect, target_aspect)
/// pair gets. Thresholds:
///   - source ≥ target / 1.30      → close-to-target / wider; cover-center.
///   - source ≥ target * 0.75      → mildly tall; cover-crop top-biased.
///   - source < target * 0.75      → squarer / portrait; backdrop fit.
fn planCoverFit(source_aspect: f32, target_aspect: f32) CoverFit {
    if (source_aspect <= 0 or target_aspect <= 0) {
        return .{ .cover_center = .{ .w = 1, .h = 1 } };
    }
    // 1) Wider-than-target → standard center-crop on x.
    if (source_aspect >= target_aspect) {
        const uv_w = target_aspect / source_aspect;
        const uv_x = (1.0 - uv_w) * 0.5;
        return .{ .cover_center = .{ .x = uv_x, .y = 0, .w = uv_w, .h = 1 } };
    }
    // 2) Within 25% of target on the tall side → cover-crop with the
    //    crop origin pulled toward the top third (game cover art keeps
    //    title text + characters in the upper half, so a centered
    //    crop cuts heads off).
    if (source_aspect >= target_aspect * 0.75) {
        const uv_h = source_aspect / target_aspect;
        // Center would be `(1 - uv_h) * 0.5`; pull the origin up by
        // 60% of that distance so we keep more of the top.
        const uv_y = (1.0 - uv_h) * 0.2;
        return .{ .cover_top = .{ .x = 0, .y = uv_y, .w = 1, .h = uv_h } };
    }
    // 3) Vertical-dominant (source taller than or equal to wide) —
    //    height-fit + 25% zoom. Crops the top/bottom 10% of the source
    //    so the rendered aspect = `src_aspect * 1.25`, reducing the
    //    side bars vs a plain letterbox without stretching artwork.
    if (source_aspect <= 1.0) {
        return .{ .zoom_height = .{ .x = 0, .y = 0.1, .w = 1, .h = 0.8 } };
    }
    // 4) Mildly tall (1 < source < target*0.75) — backdrop letterbox.
    //    UV is the whole source; foreground sizes itself with .ratio
    //    shrink so no content is cropped.
    return .{ .fit_backdrop = {} };
}

/// Card cover slot — fills card width AND height. The cover image
/// is sized via `expand = .both` and cropped (not letterboxed) by
/// `init_opts.uv` so the source aspect doesn't show whitespace bars
/// inside the card. Engine badge layers on top via `dvui.overlay`.
fn renderCardCover(bytes_opt: ?[]const u8, thread_id: u64, engine: library.Engine, status: library.DevStatus, layout: GridLayout) void {
    const cover_h: f32 = layout.cover_h;
    // Strictly bound the cover slot height. Without max_size_content
    // the inner image's `expand = .both` would push the overlay tall
    // enough to eat the title + meta rows below it.
    var ov = dvui.overlay(@src(), .{
        .id_extra = thread_id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = cover_h },
        .max_size_content = .{ .w = layout.card_w, .h = cover_h },
    });
    defer ov.deinit();

    if (bytes_opt) |bytes| {
        const source: dvui.ImageSource = .{ .imageFile = .{ .bytes = bytes, .name = "card-cover" } };
        const natural = dvui.imageSize(source) catch dvui.Size{ .w = 16, .h = 9 };
        const target_aspect = (layout.card_w - 12) / cover_h;
        const source_aspect = if (natural.h > 0) natural.w / natural.h else 16.0 / 9.0;

        switch (planCoverFit(source_aspect, target_aspect)) {
            .cover_center, .cover_top => |uv| {
                _ = dvui.image(@src(), .{
                    .source = source,
                    .shrink = null,
                    .uv = uv,
                }, .{
                    .id_extra = thread_id,
                    .expand = .both,
                    .min_size_content = .{ .w = 1, .h = 1 },
                    .corner_radius = style.corner_radius,
                    .border = style.border_thin,
                    .color_border = style.border_color,
                });
            },
            .fit_backdrop => {
                // Letterbox: solid black fills the slot, image draws
                // on top aspect-preserved + centered. Used for
                // portrait / square covers where stretching distorts
                // the artwork. Previously this rendered a darkened-
                // stretched copy of the image as the backdrop;
                // switched to flat black per UX feedback ("don't
                // stretch — fill the empty area with black").
                {
                    var bg = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = thread_id ^ 0xBD,
                        .expand = .both,
                        .gravity_x = 0.5,
                        .min_size_content = .{ .w = 1, .h = 1 },
                        .max_size_content = .{ .w = layout.card_w - 12, .h = cover_h },
                        .background = true,
                        .corner_radius = style.corner_radius,
                        .border = style.border_thin,
                        .color_border = style.border_color,
                        .color_fill = style.letterbox_fill,
                    });
                    bg.deinit();
                }
                // Foreground: full image, aspect-preserved, centered.
                // `expand = .ratio` + natural dims as `min_size_content`
                // give us a parent-placed rect that already matches the
                // image aspect (so `rect_scale` is right). See the
                // zoom_height branch for the rationale.
                _ = dvui.image(@src(), .{
                    .source = source,
                    .shrink = .ratio,
                    .uv = .{ .w = 1, .h = 1 },
                }, .{
                    .id_extra = thread_id ^ 0xFE,
                    .expand = .ratio,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = natural.w, .h = natural.h },
                });
            },
            .zoom_height => |uv| {
                // Black backdrop fills the slot, same as fit_backdrop.
                {
                    var bg = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = thread_id ^ 0xBD,
                        .expand = .both,
                        .gravity_x = 0.5,
                        .min_size_content = .{ .w = 1, .h = 1 },
                        .max_size_content = .{ .w = layout.card_w - 12, .h = cover_h },
                        .background = true,
                        .corner_radius = style.corner_radius,
                        .border = style.border_thin,
                        .color_border = style.border_color,
                        .color_fill = style.letterbox_fill,
                    });
                    bg.deinit();
                }
                // Foreground: lie about the natural height so the
                // ratio fit produces an aspect of `src_aspect / uv.h`
                // (= 1.25× source). UV crops the matching vertical
                // band — rect aspect matches UV-cropped aspect → no
                // distortion, image renders 25% wider than pure
                // height-fit. `expand = .ratio` makes the parent's
                // rectFor place us at the centered aspect-fit rect
                // up front; `.both` + `.shrink = .ratio` would leave
                // the cached rect_scale anchored at the overlay's
                // left edge while the image's internal placeIn
                // re-centered the geometry — visually left-aligned.
                _ = dvui.image(@src(), .{
                    .source = source,
                    .shrink = .ratio,
                    .uv = uv,
                }, .{
                    .id_extra = thread_id ^ 0x77,
                    .expand = .ratio,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = natural.w, .h = natural.h * uv.h },
                });
            },
        }
    } else {
        var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = thread_id,
            .expand = .both,
            .background = true,
            .corner_radius = style.corner_radius,
            .border = style.border_thin,
            .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
            .color_border = style.border_color,
        });
        defer slot.deinit();
        dvui.label(@src(), "(no cover)", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    }

    // Engine badge — top-left over the cover. Show even for `.unknown`
    // so the layout grid stays visually consistent across all cards
    // (the `?` chip turns out to be useful while reseeding the library
    // since unparsed engines are common pre-resync).
    renderEngineBadge(thread_id, engine);
    renderStatusBadge(thread_id, status);
}

/// Tiny install-state dot — bottom-right corner of the cover.
///   green  → installed and version matches the scraped latest
///   yellow → installed but the scrape shows a newer version
///   (no dot when not installed)
/// Hover-tooltip carries the textual state for users who don't
/// remember the colour code.
fn renderInstallDot(thread_id: u64, state: actions.InstallDotState) void {
    const fill: dvui.Color = switch (state) {
        .up_to_date => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 }, // green
        .outdated => .{ .r = 0xC0, .g = 0x84, .b = 0x1F }, // amber
        .none => return,
    };
    const tip: []const u8 = switch (state) {
        .up_to_date => "Installed",
        .outdated => "Installed (update available)",
        .none => "",
    };
    // Circle = box with corner_radius = half of width. 12 px feels
    // right at typical card sizes — visible but not pulling focus.
    const diameter: f32 = 12;
    var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = thread_id ^ 0xAA77,
        .gravity_x = 1.0,
        .gravity_y = 0.0,
        .min_size_content = .{ .w = diameter, .h = diameter },
        .max_size_content = .{ .w = diameter, .h = diameter },
        .background = true,
        .corner_radius = .all(diameter / 2),
        .color_fill = fill,
        .color_border = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
        .border = style.border_thin,
        .margin = .{ .x = 0, .y = 2, .w = 2, .h = 0 },
    });
    dvui.tooltip(@src(), .{
        .active_rect = dot.data().borderRectScale().r,
    }, "{s}", .{tip}, .{ .id_extra = thread_id ^ 0xAA77 });
    dot.deinit();
}

/// Status badge — sibling of the engine badge. Bottom-RIGHT of the
/// cover. Mirrors the engine badge's bottom-LEFT placement.
fn renderStatusBadge(thread_id: u64, status: library.DevStatus) void {
    if (status == .unknown) return;
    const fill = devStatusColor(status);
    var badge = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = thread_id,
        .gravity_x = 1.0,
        .gravity_y = 1.0,
        .background = true,
        .corner_radius = .all(2),
        .padding = .all(0),
        .margin = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .color_fill = fill,
        .color_border = fill,
        .border = style.border_thin,
    });
    defer badge.deinit();
    const body = dvui.Font.theme(.body);
    dvui.label(@src(), "{s}", .{devStatusShortLabel(status)}, .{
        .color_text = dvui.Color.white,
        .font = body.withSize(body.size * style.chip_font_scale),
        .padding = style.chip_label_padding,
        .margin = .all(0),
    });
}

fn renderEngineBadge(thread_id: u64, engine: library.Engine) void {
    const fill = engineBadgeColor(engine);
    var badge = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = thread_id,
        .gravity_x = 0,
        .gravity_y = 1.0,
        .background = true,
        .corner_radius = .all(2),
        .padding = .all(0),
        .margin = .{ .x = 4, .y = 0, .w = 0, .h = 4 },
        .color_fill = fill,
        .color_border = fill,
        .border = style.border_thin,
    });
    defer badge.deinit();
    const body = dvui.Font.theme(.body);
    dvui.label(@src(), "{s}", .{engineShortLabel(engine)}, .{
        .color_text = dvui.Color.white,
        .font = body.withSize(body.size * style.chip_font_scale),
        .padding = style.chip_label_padding,
        .margin = .all(0),
    });
}

/// Short labels that fit in a corner chip. The full enum name is
/// fine in the sidebar filter, but at card scale we need ~6 chars max.
fn engineShortLabel(e: library.Engine) []const u8 {
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

/// Per-engine accent colors. Loosely chosen to evoke each engine's
/// branding (Ren'Py teal, Unity dark, Unreal navy, etc.) while staying
/// distinguishable at chip scale on top of an arbitrary cover image.
/// Short label for the dev-status chip — kept terse so a card or
/// list row can fit one alongside the engine badge.
fn devStatusShortLabel(s: library.DevStatus) []const u8 {
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
fn devStatusColor(s: library.DevStatus) dvui.Color {
    return switch (s) {
        .completed => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 }, // green
        .abandoned => .{ .r = 0xB7, .g = 0x1C, .b = 0x1C }, // red
        .on_hold => .{ .r = 0xC0, .g = 0x84, .b = 0x1F }, // amber
        .in_progress => .{ .r = 0x1F, .g = 0x6A, .b = 0xA0 }, // blue
        .orphaned => .{ .r = 0x6E, .g = 0x4A, .b = 0x8A }, // muted purple
        .unknown => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F }, // grey
    };
}

fn engineBadgeColor(e: library.Engine) dvui.Color {
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

// ============================================================
//  detail screen
// ============================================================

pub fn detailScreen(frame: *Frame) !bool {
    const state = frame.state;
    const games = frame.games;
    // Keep the per-frame install-set snapshot fresh so the InstallDot
    // and "Installed" affordances on the detail page flip green the
    // instant a post-install commits, without the user having to
    // navigate away.
    actions.refreshInstalledSet(frame);
    const tid = state.selected_thread orelse {
        // Bad state — bounce back to library.
        state.screen = .library;
        return true;
    };

    // Fresh state on detail-page open. Mirrors the `carousel_for_thread`
    // pattern: detect a thread switch and zero out every per-page
    // field so each game opens with default tab + scroll + no stale
    // popups. Centralized here (instead of at the four navigation call
    // sites) so future entry points get the reset for free.
    if (state.detail_state_for_thread != tid) {
        state.resetDetailViewState();
        state.detail_state_for_thread = tid;
    }

    const game = blk: {
        for (games) |*gg| if (gg.f95_thread_id == tid) break :blk gg;
        state.screen = .library;
        state.selected_thread = null;
        return true;
    };

    // ---- top action bar ----
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();

        if (iconOnly(@src(), "back", entypo.chevron_left, .{})) {
            state.screen = .library;
            state.selected_thread = null;
            // Drop transient confirmations on nav; preserve errors —
            // the user hasn't acknowledged them yet.
            state.clearTransientToasts();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "{s}", .{game.name}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Only Delete sits up here; Sync / Open thread / Open saves /
        // Launch live in the cover column below.
        if (iconButton(@src(), "Delete", entypo.trash, .{ .style = .err })) {
            state.confirm_delete = true;
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Confirm-delete banner replaces the sync banner when active.
    // Uses the same muted-pink surround as the manual-install panel
    // so the inline confirm stays within the app's pink theme; the
    // destructive cue lives on the Delete button (still `.style = .err`)
    // rather than colouring the entire band red.
    if (state.confirm_delete) {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.card_fill,
            .color_border = style.border_color,
        });
        defer bar.deinit();
        var conf_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&conf_buf, "Really delete \"{s}\"?", .{game.name}) catch "Really delete?";
        dvui.label(@src(), "{s}", .{msg}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (iconButton(@src(), "Cancel", entypo.cross, .{})) state.confirm_delete = false;
        if (iconButton(@src(), "Delete", entypo.trash, .{ .style = .err })) {
            actions.deleteGameAndReturn(frame, game.f95_thread_id);
            return true;
        }
    }

    // (Sync status banner removed — the global `renderSyncBanner` in
    // `guiFrame` already covers running/queued progress on every
    // screen. When the per-game `sync_msg` was cleared at job start,
    // this local banner kept rendering an empty pink bar above the
    // cover carousel during sync. Errors still surface via the global
    // banner's red style.)

    // Outer scroll area covers everything below the sticky top bars
    // (back/title, confirm-delete, sync status). When the banner +
    // meta + action row + tabs + tab content combined exceed the
    // window height, the user can scroll the whole detail page.
    //
    // (No tab-change snap — the body box has a 500px min-height
    // floor, so the "short tab leaves page scrolled past its bottom"
    // problem the snap was solving no longer happens. Snapping every
    // switch back to the top was more annoying than the bug it
    // prevented.)
    var page_scroll = dvui.scrollArea(@src(), .{ .scroll_info = &state.detail_scroll }, .{ .expand = .both });

    // ---- header: banner on top, meta block below ----
    //
    // F95 uses very wide cover banners (typically 4:1 / 3.85:1). The
    // carousel takes the full content width so the banner reads at
    // its intended size; meta details are stacked underneath.
    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        });
        defer hdr.deinit();

        renderCarousel(frame, game);

        renderRibbon(frame, game);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

        // Identity pills — engine / devstate / F95 rating / F95 #.
        // Sit directly under the carousel like a movie/album hero
        // bar: rating + key tags right under the artwork.
        renderIdentityPillRow(frame, game);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

        // Action toolbar — single wrapping cluster, right-anchored.
        renderActionRow(frame, game);

        // Live status banner. ONE line; visible only when something
        // is actually happening or a message wants attention.
        // Replaces the previous boxed Notifications strip + the
        // separate "Installing…" / download-progress blocks.
        renderDetailStatusLine(frame, game);

        if (state.convert_help_open) renderConvertHelp();
        if (state.manual_install_open) renderManualInstallPanel(frame, game);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

        // Metadata grid — label/value rows that reflow at any width.
        // Replaces the side-by-side "From F95" + "Your library"
        // panels (those disappeared at narrow widths because both
        // claimed `expand=.both`). Editable user state (Status,
        // Your rating, Sandbox) sits inline next to scraped facts
        // (Version, Developer, Last updated) — same pattern as
        // Letterboxd / Calibre.
        renderDetailFactsGrid(frame, game);
    }

    // Tags chip row — full width, wrapping. Lives outside the
    // header padding so the chips can use the full content width.
    if (game.tags.len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        var tag_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 4, .w = 16, .h = 4 },
        });
        defer tag_box.deinit();
        renderTagChips(game.tags);
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ---- tabs ----
    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
        });
        defer tabs.deinit();

        if (tabButton("Description", state.detail_tab == .overview)) state.detail_tab = .overview;
        if (tabButton("Changelog", state.detail_tab == .changelog)) state.detail_tab = .changelog;
        if (tabButton("Notes", state.detail_tab == .notes)) state.detail_tab = .notes;
        if (tabButton("Downloads", state.detail_tab == .downloads)) state.detail_tab = .downloads;
        // Recipe + Mods are no longer tabs. Recipe is auto-saved on
        // sync + on mod-add — the user never has to think about it.
        // Mods has its own full-page screen via the action-row Mods
        // button.
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        // Floor the tab body's height so short tabs (Versions, Mods
        // when empty) don't visibly collapse the page when the user
        // clicks between them. Taller content still grows past the
        // floor; the outer scrollArea handles overflow.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 500 },
        });
        defer body.deinit();

        switch (state.detail_tab) {
            .overview => renderOverview(frame, game),
            .changelog => renderChangelogTab(frame, game),
            .downloads => renderDownloadsTab(frame, game),
            .notes => renderNotesTab(frame, game),
        }
    }

    // Close the outer scroll area before the image popup so the
    // popup's modal layer sits above the scroll, not inside it.
    page_scroll.deinit();

    // Click-to-enlarge image popup. Rendered last so its modal
    // backdrop sits over the rest of the detail screen. The popup
    // mirrors `state.carousel_index` — it shows whichever slide the
    // user was on when they clicked.
    renderImagePopup(frame, game);

    // Install-management modals (Rename / Delete confirm). Only
    // rendered when `state.manage_action != .none`. Same z-order
    // bucket as the image popup so they float above the scroll area.
    renderInstallManagePopups(frame, game);

    // Recipe wizard now lives on its own screen (.recipe_editor) —
    // see recipeEditorScreen. The detail page just navigates to it via
    // `actions.openWizardForModfile`.

    // File-clash modal. Active when state.clash_modal != null.
    renderClashModal(frame, game);

    return true;
}

/// Modal floating window showing the current carousel slide at
/// (close to) native size. Click the X in the header or anywhere on
/// the modal backdrop to close.
fn renderImagePopup(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (!state.image_popup_open) return;
    // If the user navigated to a different game while the popup was
    // open, close it — the path lookup below would otherwise read a
    // stale file.
    if (state.carousel_for_thread != game.f95_thread_id) {
        state.image_popup_open = false;
        return;
    }

    const idx = state.carousel_index;

    // Popup always shows the FULL-size image, mirroring the carousel.
    const bytes_opt: ?[]const u8 = if (idx == 0)
        actions.coverFullBytes(frame, game.f95_thread_id)
    else
        actions.slideBytes(frame, game.f95_thread_id, idx);

    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.image_popup_open,
    }, .{
        .min_size_content = .{ .w = 600, .h = 400 },
    });
    defer fw.deinit();

    var hdr_buf: [48]u8 = undefined;
    const title = if (idx == 0)
        @as([]const u8, "Cover")
    else
        std.fmt.bufPrint(&hdr_buf, "Screenshot {d}", .{idx}) catch "Screenshot";
    _ = dvui.windowHeader(title, "", &state.image_popup_open);

    if (bytes_opt) |b| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = b, .name = "popup" } },
            .shrink = .ratio,
        }, .{
            .expand = .both,
            .min_size_content = .{ .w = 800, .h = 600 },
        });
        return;
    }
    // No bytes — file missing or unreadable. Show a placeholder so
    // the modal is at least dismissable.
    dvui.label(@src(), "(image not available)", .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .both,
    });
}

/// Rename + Delete-confirm modals for the install picker's ⋯ menu.
/// Reads `state.manage_action` to decide which (if any) to show.
/// Closing via the X button or Cancel resets the action; OK paths
/// dispatch to `actions.doRenameInstall` / `actions.doDeleteInstall`.
fn renderInstallManagePopups(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (state.manage_action == .none) return;
    const sel_id = state.manage_install_id orelse {
        state.manage_action = .none;
        return;
    };

    // Find the target install — re-fetched from the DB each frame the
    // popup is open. Small + indexed table; the convenience of stable
    // identity (vs. stashing a pointer that could dangle if the user
    // navigates) is worth the query.
    const installs = frame.lib.listInstalls(game.f95_thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));
    var found_idx: ?usize = null;
    for (installs, 0..) |inst, i| {
        if (std.mem.eql(u8, inst.id[0..], sel_id[0..])) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse {
        // Install vanished from under us — close cleanly.
        state.manage_action = .none;
        state.manage_install_id = null;
        return;
    };
    const inst = installs[idx];

    switch (state.manage_action) {
        .none => unreachable,
        .rename => renderRenameInstallPopup(frame, &inst),
        .delete => renderDeleteInstallPopup(frame, &inst),
    }
}

fn renderRenameInstallPopup(frame: *Frame, inst: *const library.Install) void {
    const state = frame.state;
    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 420, .h = 180 },
    });
    defer fw.deinit();

    _ = dvui.windowHeader("Rename install", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer body.deinit();

    var ver_buf: [128]u8 = undefined;
    const ver_text = std.fmt.bufPrint(&ver_buf, "Version: {s} ({s})", .{ inst.version, @tagName(inst.source) }) catch inst.version;
    dvui.label(@src(), "{s}", .{ver_text}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "A name disambiguates two installs of the same version (e.g. \"vanilla\", \"modded\"). " ++
            "Leave blank to clear and fall back to the bare version in the picker.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Name", .{}, .{
            .min_size_content = .{ .w = 80, .h = 24 },
            .gravity_y = 0.5,
            .color_text = HELP_TEXT_COLOR,
        });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.manage_rename_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 240, .h = 26 },
            .gravity_y = 0.5,
        });
        te.deinit();
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (iconButton(@src(), "Cancel", entypo.cross, .{})) {
            open = false;
        }
        if (iconButton(@src(), "Save", entypo.check, .{ .style = .highlight })) {
            actions.doRenameInstall(frame, inst.id, state.manageRenameSlice());
            open = false;
        }
    }

    // dvui flipped the open flag → user closed (X / Cancel / Save).
    if (!open) {
        state.manage_action = .none;
        state.manage_install_id = null;
        @memset(&state.manage_rename_buf, 0);
    }
}

fn renderDeleteInstallPopup(frame: *Frame, inst: *const library.Install) void {
    const state = frame.state;
    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 460, .h = 200 },
    });
    defer fw.deinit();

    _ = dvui.windowHeader("Delete install", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer body.deinit();

    var ver_buf: [192]u8 = undefined;
    const have_name = if (inst.name) |n| n.len > 0 else false;
    const ver_text = if (have_name)
        std.fmt.bufPrint(&ver_buf, "{s} \u{2014} {s}  ({s})", .{ inst.version, inst.name.?, @tagName(inst.source) }) catch inst.version
    else
        std.fmt.bufPrint(&ver_buf, "{s}  ({s})", .{ inst.version, @tagName(inst.source) }) catch inst.version;
    dvui.label(@src(), "{s}", .{ver_text}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Deletes the install folder from disk AND removes the install record from the database. " ++
            "This cannot be undone — the path below will be `rm -rf`'d.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    var path_buf: [320]u8 = undefined;
    const path_text = std.fmt.bufPrint(&path_buf, "Path: {s}", .{inst.install_path}) catch inst.install_path;
    dvui.label(@src(), "{s}", .{path_text}, .{ .color_text = HELP_TEXT_COLOR });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (iconButton(@src(), "Cancel", entypo.cross, .{})) {
            open = false;
        }
        if (iconButton(@src(), "Delete from disk", entypo.trash, .{ .style = .err })) {
            actions.doDeleteInstall(frame, inst.id, inst.install_path);
            open = false;
        }
    }

    if (!open) {
        state.manage_action = .none;
        state.manage_install_id = null;
    }
}

fn tabButton(label: []const u8, active: bool) bool {
    // Tab-shaped button: rounded only on top, flat-bottomed so the
    // active tab visually merges with the panel below it. Inactive
    // tabs sit a touch lower and use a quieter fill so the active one
    // pops as the obvious "you are here" affordance.
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

fn renderOverview(frame: *Frame, game: *const library.Game) void {
    // F95 "info block" — scraped OP key/value lines that used to live
    // in the dedicated `From F95` panel. Folded here as a prelude to
    // the description because the structured facts (Version,
    // Developer, Last updated) are already on the detail facts grid;
    // what's left in the prose is the bonus OP context like Patreon /
    // Itch / Discord links + extra prose.
    if (game.thread_info_md) |info| {
        renderStructuredText(frame, info, game.f95_thread_id ^ 0xF6);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    }
    renderWrappedText(game.description_md, "No description yet. Sync this game to populate.");
}

fn renderChangelogTab(frame: *Frame, game: *const library.Game) void {
    if (game.changelog_md) |text| {
        renderStructuredText(frame, text, game.f95_thread_id);
    } else {
        dvui.label(@src(), "No changelog scraped yet. Sync this game to populate.", .{}, .{});
    }
}

/// Render a long plain-text blob inside a dvui textLayout so it
/// word-wraps to the parent box. `placeholder` is shown when `text`
/// is null or when the blob fails UTF-8 validation (dvui's renderText
/// `unreachable`-asserts on invalid sequences, so we never hand it
/// raw bytes from the wire).
fn renderWrappedText(text: ?[]const u8, placeholder: []const u8) void {
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
    defer tl.deinit();
    if (text) |md| {
        if (std.unicode.utf8ValidateSlice(md)) {
            tl.addText(md, .{});
        } else {
            tl.addText("(text contains invalid UTF-8 — re-sync to refresh)", .{});
        }
    } else {
        tl.addText(placeholder, .{});
    }
}

/// Pink-muted, wrapping help text for Settings sections + other
/// prose-under-heading slots. `dvui.label` doesn't wrap — long
/// explanations overflow the panel at narrow window widths. Using
/// `textLayout` with `.expand = .horizontal` lets the text reflow.
const HELP_TEXT_COLOR: dvui.Color = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 };

fn settingsHelpText(text: []const u8) void {
    // dvui's textLayout draws a selection / focus ring by default
    // which renders as a red box at our theme's error colour. Override
    // border + colour explicitly so the help text reads as the dim
    // grey-pink it always meant to be.
    //
    // Every call site uses the same `@src()` so widget ids collide
    // when more than one help block lives on a single screen. Hash
    // the text into `id_extra` so each unique snippet gets a stable,
    // distinct id without callers having to thread an index.
    var tl = dvui.textLayout(@src(), .{}, .{
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

/// Render a chunk of structured text emitted by
/// `f95.thread.formatStructuredHtml`. Recognised line markers:
///   `## …`              — heading
///   `• …`               — bullet (hanging indent)
///   `[SPOILER=Title]`   — start a `dvui.expander`; body until
///   `[/SPOILER]`        — matching marker is rendered nested.
///   `[LINK=URL]…[/LINK]` — inline clickable hyperlink (any line).
/// Lines that don't match a marker render as wrapped paragraphs.
fn renderStructuredText(frame: *Frame, text: []const u8, base_id: u64) void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        dvui.label(@src(), "(text contains invalid UTF-8 — re-sync to refresh)", .{}, .{});
        return;
    }
    renderStructuredLines(frame, text, base_id, 0);
}

fn renderStructuredLines(frame: *Frame, text: []const u8, base_id: u64, depth: u32) void {
    var i: usize = 0;
    var iter_idx: usize = 0;
    while (i <= text.len) {
        if (i == text.len) break;
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..nl];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Combine depth + iter index into the parent id_extra so
        // recursive spoiler bodies have stable, unique widget ids.
        const line_id: u64 = base_id +% (@as(u64, iter_idx) << @intCast(@min(depth * 4, 56)));
        iter_idx += 1;
        i = nl + 1;

        if (trimmed.len == 0) {
            _ = dvui.spacer(@src(), .{ .id_extra = line_id, .min_size_content = .{ .w = 1, .h = 4 } });
            continue;
        }

        // Spoiler open → collect body up to the matching close marker.
        if (std.mem.startsWith(u8, trimmed, "[SPOILER=") and std.mem.endsWith(u8, trimmed, "]")) {
            const title = trimmed["[SPOILER=".len .. trimmed.len - 1];
            const close_marker = "[/SPOILER]";
            const close_at = std.mem.indexOfPos(u8, text, i, close_marker) orelse text.len;
            const body = text[i..close_at];
            i = close_at + close_marker.len;
            if (i < text.len and text[i] == '\n') i += 1;

            if (dvui.expander(@src(), title, .{}, .{
                .id_extra = line_id,
                .expand = .horizontal,
            })) {
                var inner = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = line_id,
                    .expand = .horizontal,
                    .padding = .{ .x = 16, .y = 4, .w = 0, .h = 4 },
                });
                defer inner.deinit();
                renderStructuredLines(frame, body, line_id, depth + 1);
            }
            continue;
        }

        // Heading line.
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const body = trimmed[3..];
            dvui.label(@src(), "{s}", .{body}, .{
                .id_extra = line_id,
                .style = .highlight,
                .expand = .horizontal,
            });
            continue;
        }

        // Bullet line.
        const BULLET = "• ";
        if (std.mem.startsWith(u8, trimmed, BULLET)) {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = line_id,
                .expand = .horizontal,
            });
            defer row.deinit();
            dvui.label(@src(), "•", .{}, .{
                .id_extra = line_id,
                .min_size_content = .{ .w = 14, .h = 1 },
            });
            renderInlineLineWithLinks(frame, trimmed[BULLET.len..], line_id);
            continue;
        }

        // Regular paragraph (may carry inline [LINK=…][/LINK]s).
        renderInlineLineWithLinks(frame, trimmed, line_id);
    }
}

/// Render one line as a wrapped textLayout, splitting on inline
/// markers:
///   `[LINK=URL]label[/LINK]` → clickable link (opens via the
///     user's chosen browser)
///   `[B]label[/B]`           → bold inline span
/// At each step we pick whichever marker comes first; plain text in
/// between is emitted verbatim. Unclosed/malformed markers fall back
/// to literal rendering so we never lose data.
fn renderInlineLineWithLinks(frame: *Frame, line: []const u8, id: u64) void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
    });
    defer tl.deinit();

    const body = dvui.Font.theme(.body);
    const bold_font = body.withWeight(.bold);
    const link_color: dvui.Color = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A };

    var cursor: usize = 0;
    while (cursor < line.len) {
        const link_at = std.mem.indexOfPos(u8, line, cursor, "[LINK=");
        const bold_at = std.mem.indexOfPos(u8, line, cursor, "[B]");
        // Pick the earliest marker (or end of line if none).
        const next: usize = blk: {
            const la = link_at orelse std.math.maxInt(usize);
            const ba = bold_at orelse std.math.maxInt(usize);
            const n = @min(la, ba);
            break :blk if (n == std.math.maxInt(usize)) line.len else n;
        };
        if (next > cursor) tl.addText(line[cursor..next], .{});
        if (next == line.len) return;

        if (link_at != null and next == link_at.?) {
            const open = link_at.?;
            const url_start = open + "[LINK=".len;
            const url_end = std.mem.indexOfScalarPos(u8, line, url_start, ']') orelse {
                tl.addText(line[open..], .{});
                return;
            };
            const url = line[url_start..url_end];
            const label_start = url_end + 1;
            const close_marker = "[/LINK]";
            const close_at = std.mem.indexOfPos(u8, line, label_start, close_marker) orelse {
                tl.addText(line[open..], .{});
                return;
            };
            const label_text = line[label_start..close_at];
            const shown = if (label_text.len == 0) url else label_text;
            if (tl.addTextClick(shown, .{ .color_text = link_color })) |_| {
                actions.openExternalUrl(frame, url);
            }
            cursor = close_at + close_marker.len;
        } else {
            // Bold span. `[B]…[/B]` — emit the body with bold font.
            const open = bold_at.?;
            const body_start = open + "[B]".len;
            const close_marker = "[/B]";
            const close_at = std.mem.indexOfPos(u8, line, body_start, close_marker) orelse {
                tl.addText(line[open..], .{});
                return;
            };
            const body_text = line[body_start..close_at];
            tl.addText(body_text, .{ .font = bold_font });
            cursor = close_at + close_marker.len;
        }
    }
}

fn renderDownloadsTab(frame: *Frame, game: *const library.Game) void {
    if (game.downloads_md) |text| {
        renderStructuredText(frame, text, game.f95_thread_id);
        return;
    }
    dvui.label(@src(), "No download links scraped yet. Sync this game to populate.", .{}, .{});
}

/// Full-page Mods screen. Reached from the detail page's "Mods →"
/// button. Owns the merged archive-row + recipe-row UI plus a
/// header bar with a Back link to the game's detail page.
pub fn modsScreen(frame: *Frame) !bool {
    const state = frame.state;
    const game_opt = currentGameForMods(frame);
    const game = game_opt orelse {
        // No game in context (selected_thread gone). Bounce home.
        state.screen = .library;
        return true;
    };

    // ---- header: Back + title + Settings link ----
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        });
        defer hdr.deinit();
        if (style.button(@src(), "< Back", .{}, .{})) {
            state.screen = .detail;
            return true;
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Mods — {s}", .{game.name}) catch "Mods";
        dvui.label(@src(), "{s}", .{title}, .{ .style = .highlight, .gravity_y = 0.5 });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Manage install patterns...", .{}, .{ .gravity_y = 0.5 })) {
            actions.openSettingsTab(state, .mod_presets);
            return true;
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Body scrolls so very-long archive / mod lists don't push the
    // header off-screen.
    var page_scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 24, .y = 12, .w = 24, .h = 12 },
    });
    defer page_scroll.deinit();

    // Install picker — shown when more than one install exists so the
    // user can choose which version Install / Uninstall acts on.
    // Sits ABOVE the tab strip so switching tabs doesn't lose this
    // context.
    renderModsInstallPicker(frame, game);

    // Backup mode selector + queue banner — both feed off the global
    // mod-job state so they make sense on every game's Mods page.
    renderModsBackupModePicker(frame, game);
    renderModJobBanner(frame);

    // Top action bar: Add modfile / Scan / Import recipe — visible
    // on every tab so the "add stuff" affordances are never hidden.
    renderModfileActionBar(frame, game);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Tab strip — filter views over the master modfile + recipe list.
    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .y = 0, .h = 4 },
        });
        defer tabs.deinit();

        const counts = actions.modsPageCache(frame, game).counts;
        if (tabButton(modsTabLabel(.installed, "Installed", counts.installed), state.mods_tab == .installed)) state.mods_tab = .installed;
        if (tabButton(modsTabLabel(.ready, "Ready", counts.ready), state.mods_tab == .ready)) state.mods_tab = .ready;
        if (tabButton(modsTabLabel(.needs_archive, "Needs archive", counts.needs_archive), state.mods_tab == .needs_archive)) state.mods_tab = .needs_archive;
        if (tabButton(modsTabLabel(.needs_recipe, "Needs recipe", counts.needs_recipe), state.mods_tab == .needs_recipe)) state.mods_tab = .needs_recipe;
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Onboarding hint — only on the first-ever-visit case, otherwise
    // the empty tab body says the right thing per-tab.
    const modfiles_now = actions.modfilesForGame(frame, game);
    if (modfiles_now.len == 0) {
        dvui.label(@src(), "Mods extend this game with extra files.", .{}, .{ .color_text = HELP_TEXT_COLOR });
        dvui.label(@src(), "1) Add the mod's archive  -OR-  Import a recipe   2) Set up the install plan   3) Click Install.", .{}, .{ .color_text = HELP_TEXT_COLOR });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    }

    renderModsTabBody(frame, game);

    return true;
}

/// Short helper to assemble a tab label with count suffix when the
/// tab has entries. Empty tabs show plain text — keeps the bar quiet
/// for typical games. Each tab gets a fixed static buffer keyed off
/// the ModsTab tag so the label slice (and therefore the widget id
/// `tabButton` derives from `label.ptr`) stays pointer-stable across
/// frames; without this dvui sees a new id every paint and click
/// events vanish into thin air.
fn modsTabLabel(tag: state_mod.ModsTab, name: []const u8, count: usize) []const u8 {
    if (count == 0) return name;
    const Static = struct {
        var bufs: [4][64]u8 = undefined;
    };
    const slot: usize = switch (tag) {
        .installed => 0,
        .ready => 1,
        .needs_archive => 2,
        .needs_recipe => 3,
    };
    const out = std.fmt.bufPrint(&Static.bufs[slot], "{s} ({d})", .{ name, count }) catch return name;
    return out;
}

/// Tab-strip counters. Defined in `actions.zig` (`actions.ModsTabCounts`)
/// so the cache that produces them can live alongside `ModfileCache`.

/// Body of the Mods page — picks the active tab + renders the
/// filtered list.
fn renderModsTabBody(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    switch (state.mods_tab) {
        .installed => renderModsTabInstalled(frame, game),
        .ready => renderModsTabReady(frame, game),
        .needs_archive => renderModsTabNeedsArchive(frame, game),
        .needs_recipe => renderModsTabNeedsRecipe(frame, game),
    }
}

/// Surface an install-version picker at the top of the Mods page so the
/// user always sees — and can switch — which install the page is acting
/// on. Three render modes by install count:
///   0 → muted "No install for this game" hint.
///   1 → static "Applying to: vX.Y  (source)" label.
///   2+ → dropdown writing the selected id to `state.mods_page_install_id`.
/// Install / Uninstall / installed-status checks read that field via
/// `resolveModsPageInstall`.
fn renderModsInstallPicker(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const installs = frame.lib.listInstalls(game.f95_thread_id) catch {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .y = 0, .h = 8 },
        });
        defer row.deinit();
        dvui.label(@src(), "Applying to:", .{}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.label(@src(), "(failed to list installs)", .{}, .{ .gravity_y = 0.5, .style = .err });
        return;
    };
    defer if (installs.len > 0) frame.lib.freeInstalls(installs);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .y = 0, .h = 8 },
    });
    defer row.deinit();
    dvui.label(@src(), "Applying to:", .{}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    if (installs.len == 0) {
        dvui.label(
            @src(),
            "no install yet - install the game first",
            .{},
            .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR },
        );
        // Drop any stale selection so a later install ends up resolved
        // via the latest-install fallback rather than a vanished id.
        state.mods_page_install_id = null;
        return;
    }

    // Build labels: "vX.Y  (source)" — same format the detail-page
    // launch picker uses.
    var labels_buf: [16][]const u8 = undefined;
    var join_buf: [16 * 96]u8 = undefined;
    var join_used: usize = 0;
    const n = @min(installs.len, labels_buf.len);
    for (installs[0..n], 0..) |inst, i| {
        const rest = join_buf[join_used..];
        const have_name = if (inst.name) |nm| nm.len > 0 else false;
        const joined = if (have_name)
            std.fmt.bufPrint(rest, "{s}  ({s})  -  {s}", .{ inst.version, @tagName(inst.source), inst.name.? }) catch inst.version
        else
            std.fmt.bufPrint(rest, "{s}  ({s})", .{ inst.version, @tagName(inst.source) }) catch inst.version;
        labels_buf[i] = joined;
        join_used += joined.len;
    }

    if (n == 1) {
        // Single-install case: still display which install we're modding,
        // but no need for a clickable dropdown.
        dvui.label(@src(), "{s}", .{labels_buf[0]}, .{ .gravity_y = 0.5, .style = .highlight });
        if (state.mods_page_install_id == null) {
            state.mods_page_install_id = installs[0].id;
        }
        return;
    }

    // Resolve initial pick from saved id, defaulting to 0 (newest).
    var picked: usize = 0;
    if (state.mods_page_install_id) |sel| {
        for (installs[0..n], 0..) |inst, i| {
            if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                picked = i;
                break;
            }
        }
    }

    if (style.dropdown(@src(), labels_buf[0..n], .{ .choice = &picked }, .{}, .{
        .min_size_content = .{ .w = 280, .h = style.button_h },
        .gravity_y = 0.5,
    })) {
        state.mods_page_install_id = installs[picked].id;
    } else {
        // Keep the field in sync on first render so resolveModsPageInstall
        // can rely on it being populated.
        if (state.mods_page_install_id == null) {
            state.mods_page_install_id = installs[picked].id;
        }
    }
}

/// Tiny picker for the per-install backup policy. The picked value is
/// persisted on the game row (`games.mod_backup_mode`) so it survives
/// app restarts and is per-game — a heavy overlay-mod game stays
/// `.none` while a text-patch-heavy game stays `.copy` without the
/// user re-picking on each session.
fn renderModsBackupModePicker(frame: *Frame, game: *const library.Game) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .y = 0, .h = 8 },
    });
    defer row.deinit();
    dvui.label(@src(), "Uninstall safety:", .{}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    const labels = [_][]const u8{
        "no backup (mod modifications stick if uninstalled)",
        "back up originals (clean uninstall; doubles disk for touched files)",
    };
    var pick: usize = if (game.mod_backup_mode == .copy) 1 else 0;
    if (style.dropdown(@src(), &labels, .{ .choice = &pick }, .{}, .{
        .min_size_content = .{ .w = 420, .h = style.button_h },
        .gravity_y = 0.5,
    })) {
        const new_pref: library.BackupModePref = if (pick == 1) .copy else .none;
        frame.lib.setGameModBackupMode(game.f95_thread_id, new_pref) catch |e| {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to save uninstall safety: {s}", .{@errorName(e)}) catch "Failed to save uninstall safety";
            frame.state.notifyErr(msg);
            return;
        };
        // Reload the library so the in-memory snapshot reflects the
        // new value on the next paint.
        frame.state.reload_requested = true;
    }
}

/// Banner showing the in-flight mod job at the top of the Mods page.
/// Hidden when the queue is empty. Includes a Cancel button that flips
/// the job's cooperative-cancel flag.
fn renderModJobBanner(frame: *Frame) void {
    // Snapshot the head under the queue lock — no UI work inside the
    // critical section so we don't hold it across a frame.
    var head_info: ?struct {
        id: u64,
        kind: mod_job_queue.Kind,
        phase: mod_job_queue.Phase,
        display: [128]u8,
        display_len: u8,
        done: u32,
        total: u32,
        depth: usize,
    } = null;

    frame.mod_jobs.lock();
    {
        const jobs = frame.mod_jobs.jobsLocked();
        if (jobs.len > 0) {
            // Pick the first non-terminal job — drainFinished hasn't
            // run yet on the first frame after completion.
            for (jobs) |j| {
                const p = j.currentPhase();
                if (p == .done or p == .err or p == .canceled) continue;
                var info: @TypeOf(head_info.?) = undefined;
                info.id = j.id;
                info.kind = j.kind;
                info.phase = p;
                const dlen = @min(j.display.len, info.display.len);
                @memcpy(info.display[0..dlen], j.display[0..dlen]);
                info.display_len = @intCast(dlen);
                info.done = j.progress_done.load(.monotonic);
                info.total = j.progress_total.load(.monotonic);
                info.depth = jobs.len;
                head_info = info;
                break;
            }
        }
    }
    frame.mod_jobs.unlock();

    const h = head_info orelse return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer bar.deinit();

    const verb: []const u8 = if (h.kind == .install) "Installing" else "Uninstalling";
    const phase_text = mod_job_queue.phaseLabel(h.phase);
    var buf: [256]u8 = undefined;
    const disp = h.display[0..h.display_len];
    const status = blk: {
        if (h.total > 0) {
            break :blk std.fmt.bufPrint(&buf, "{s}: {s} - {s} ({d}/{d})", .{ verb, disp, phase_text, h.done, h.total }) catch "Mod job in flight";
        }
        if (h.done > 0) {
            break :blk std.fmt.bufPrint(&buf, "{s}: {s} - {s} ({d} files)", .{ verb, disp, phase_text, h.done }) catch "Mod job in flight";
        }
        break :blk std.fmt.bufPrint(&buf, "{s}: {s} - {s}", .{ verb, disp, phase_text }) catch "Mod job in flight";
    };
    dvui.label(@src(), "{s}", .{status}, .{ .gravity_y = 0.5, .style = .highlight });

    if (h.depth > 1) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        var dbuf: [64]u8 = undefined;
        const dtxt = std.fmt.bufPrint(&dbuf, "(+{d} queued)", .{h.depth - 1}) catch "";
        dvui.label(@src(), "{s}", .{dtxt}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (style.button(@src(), "Cancel", .{}, .{ .style = .err, .gravity_y = 0.5 })) {
        frame.mod_jobs.cancel(h.id);
    }
}

/// Resolve the game whose Mods page is being rendered. Uses
/// `state.selected_thread` (set by the detail screen before nav).
fn currentGameForMods(frame: *Frame) ?*const library.Game {
    const tid = frame.state.selected_thread orelse return null;
    return gameByThreadId(frame, tid);
}

/// Which slice of the mod-recipe list a tab body should render. The
/// orphan-modfile bucket lives in its own renderer because its row
/// shape differs (modfile metadata, not recipe metadata).
const ModRecipeFilter = enum { installed, ready, needs_archive };

/// Tab body: only mod recipes whose archive is registered AND whose
/// install tracker shows their thread id.
fn renderModsTabInstalled(frame: *Frame, game: *const library.Game) void {
    renderModRecipeList(frame, game, .installed);
}

/// Tab body: mod recipes with an archive on disk but not yet installed.
fn renderModsTabReady(frame: *Frame, game: *const library.Game) void {
    renderModRecipeList(frame, game, .ready);
}

/// Tab body: mod recipes the user has imported (or authored) but for
/// which no archive is registered. The row CTA flips to "Add modfile..."
/// so the next step is one click away.
fn renderModsTabNeedsArchive(frame: *Frame, game: *const library.Game) void {
    renderModRecipeList(frame, game, .needs_archive);
}

/// Tab body: orphan modfiles — archives on disk with zero linked
/// recipes. The CTA on each row is "Create recipe..." which opens the
/// recipe editor scoped to that archive.
fn renderModsTabNeedsRecipe(frame: *Frame, game: *const library.Game) void {
    const preset_bundle = actions.getMergedPresets(frame);
    const presets_slice: []const recipe.Preset = if (preset_bundle) |b| b.presets else &.{};

    const mods = actions.modfilesForGame(frame, game);
    var count: usize = 0;
    for (mods) |m| {
        if (m.recipe_ids.len > 0) continue;
        renderModfileRow(frame, game, m, presets_slice);
        count += 1;
    }
    if (count == 0) {
        dvui.label(
            @src(),
            "No archives waiting on a recipe. Use Add modfile... above to register one.",
            .{},
            .{ .color_text = HELP_TEXT_COLOR },
        );
    }
}

/// Shared body for the three recipe-driven tabs (installed / ready /
/// needs_archive). One pass loads the parsed mod recipes, computes
/// installed-state + load-order, then filters + renders rows.
fn renderModRecipeList(frame: *Frame, game: *const library.Game, filter: ModRecipeFilter) void {
    const state = frame.state;
    const cache = actions.modsPageCache(frame, game);

    if (cache.game_parsed == null) {
        renderTabEmptyHint(filter);
        return;
    }
    if (cache.mods.len == 0) {
        renderTabEmptyHint(filter);
        return;
    }

    var rendered: usize = 0;
    for (cache.mods, 0..) |*pm, i| {
        const installed = cache.installed[i];
        const have_archive = cache.have_archive[i];
        const load_index = cache.load_index[i];

        const keep = switch (filter) {
            .installed => installed,
            .ready => !installed and have_archive,
            .needs_archive => !installed and !have_archive,
        };
        if (!keep) continue;

        renderRecipeRow(frame, game, pm, load_index, installed, have_archive, state);
        rendered += 1;
    }

    if (rendered == 0) {
        renderTabEmptyHint(filter);
    }
}

/// Per-tab placeholder shown when the filtered list is empty. Keeps
/// the page from going blank without forcing the user to guess what
/// the tab is supposed to contain. `dvui.label` wants a comptime fmt
/// string so we route each case to its own call site.
fn renderTabEmptyHint(filter: ModRecipeFilter) void {
    switch (filter) {
        .installed => dvui.label(
            @src(),
            "No mods installed yet. Switch to Ready or Needs archive to set one up.",
            .{},
            .{ .color_text = HELP_TEXT_COLOR },
        ),
        .ready => dvui.label(
            @src(),
            "Nothing waiting to install. Add a modfile or create a recipe to get started.",
            .{},
            .{ .color_text = HELP_TEXT_COLOR },
        ),
        .needs_archive => dvui.label(
            @src(),
            "Every imported recipe already has its archive. Import another recipe to add more.",
            .{},
            .{ .color_text = HELP_TEXT_COLOR },
        ),
    }
}

/// Render one mod-recipe row. Caller decides whether to render based
/// on the active tab filter; this function just lays out the row.
fn renderRecipeRow(
    frame: *Frame,
    game: *const library.Game,
    pm: *recipe.ParsedMod,
    load_index: ?u32,
    installed: bool,
    have_archive: bool,
    state: anytype,
) void {
    const row_key = std.hash.Wyhash.hash(0, pm.recipe.id);
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .id_extra = row_key,
    });
    defer row.deinit();

    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        if (load_index) |li| {
            var idx_buf: [16]u8 = undefined;
            const idx_txt = std.fmt.bufPrint(&idx_buf, "#{d:0>2}", .{li}) catch "#?";
            dvui.label(@src(), "{s}", .{idx_txt}, .{ .style = .highlight, .gravity_y = 0.5 });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        }
        dvui.label(@src(), "{s}  v{s}", .{ pm.recipe.name, pm.recipe.version }, .{ .style = .highlight, .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        const busy = frame.mod_jobs.isModBusy(game.f95_thread_id, pm.recipe.f95_thread);

        if (installed) {
            const label: []const u8 = if (busy) "Uninstalling\u{2026}" else "Uninstall";
            if (style.button(@src(), label, .{}, .{ .style = .err })) {
                if (!busy) actions.doUninstallMod(frame, game, &pm.recipe);
            }
        } else if (have_archive) {
            const label: []const u8 = if (busy) "Installing\u{2026}" else "Install";
            if (style.button(@src(), label, .{}, .{ .style = .highlight })) {
                if (!busy) actions.doInstallMod(frame, game, &pm.recipe);
            }
        } else {
            if (style.button(@src(), "Add modfile\u{2026}", .{}, .{ .style = .highlight })) {
                pickAndRegisterModArchive(frame, game, &pm.recipe);
            }
        }

        if (have_archive) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
            if (style.button(@src(), "Save as preset\u{2026}", .{}, .{})) {
                actions.doSaveModRecipeAsPreset(frame, game, &pm.recipe);
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const pending_slice = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
        const armed = std.mem.eql(u8, pending_slice, pm.recipe.id);
        const del_label: []const u8 = if (armed) "Confirm delete recipe" else "Delete recipe";
        if (style.button(@src(), del_label, .{}, .{ .style = .err })) {
            actions.doDeleteModRecipeArmed(frame, game, pm.recipe.id);
        }
    }

    if (pm.recipe.post_url) |url| {
        var url_row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer url_row.deinit();
        dvui.label(@src(), "  source:", .{}, .{ .gravity_y = 0.5 });
        if (style.button(@src(), url, .{}, .{
            .gravity_y = 0.5,
            .style = .control,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        })) {
            actions.openExternalUrl(frame, url);
        }
    }
    if (pm.recipe.for_game_version) |fgv| {
        dvui.label(@src(), "  targets game version: {s}", .{fgv}, .{});
    }
    if (pm.recipe.files.len > 0) {
        dvui.label(@src(), "  declares {d} file(s) — conflict-checked at install", .{pm.recipe.files.len}, .{});
    }
    if (pm.recipe.requires.len > 0) {
        dvui.label(@src(), "  requires: {d} mod(s)", .{pm.recipe.requires.len}, .{});
    }
    if (pm.recipe.conflicts.len > 0) {
        dvui.label(@src(), "  conflicts with: {d} mod(s)", .{pm.recipe.conflicts.len}, .{ .style = .err });
    }
}

/// Open the NFDe picker scoped to .zon recipe files, then forward the
/// pick to `doImportModRecipe`. Used from the Mods page action bar so
/// users can pull in shared recipes that don't yet have a local archive.
fn pickAndImportModRecipe(frame: *Frame) void {
    const filters = [_]file_picker.FilterItem{
        .{ .name = "Recipe (ZON)", .spec = "zon" },
    };
    const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Picker failed: {s}", .{@errorName(e)}) catch "Picker failed";
        frame.state.pushToast(.err, msg);
        return;
    } orelse return; // user cancelled
    defer frame.lib.alloc.free(picked);
    actions.doImportModRecipe(frame, picked);
}

/// Open the NFDe picker, scoped to known archive extensions, and on
/// selection hand the path to `doRegisterModArchive`.
fn pickAndRegisterModArchive(frame: *Frame, game: *const library.Game, mod_recipe: *const recipe.ModRecipe) void {
    const filters = [_]file_picker.FilterItem{
        .{ .name = "Mod archives", .spec = "zip,7z,rar,tar,tar.gz,tar.bz2,tar.xz,tar.zst,tgz,tbz2,txz,gz,bz2,xz,zst" },
    };
    const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Picker failed: {s}", .{@errorName(e)}) catch "Picker failed";
        frame.state.setDownloadMsg(msg);
        return;
    } orelse return; // user cancelled
    defer frame.lib.alloc.free(picked);
    actions.doRegisterModArchive(frame, game, mod_recipe, picked);
}

// ============================================================
//  Modfiles tab — per-game managed archives + recipe authoring
// ============================================================

/// Top action bar shared by the Mods tab — Add modfile / Scan + the
/// scan-status message. Extracted so the merged Mods tab can compose
/// it above both the orphan-archive list and the recipe list.
fn renderModfileActionBar(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 0, .h = 8 } });
    defer bar.deinit();

    if (style.button(@src(), "Add modfile\u{2026}", .{}, .{ .style = .highlight })) {
        actions.clearPendingDelete(frame);
        pickAndAddModfile(frame, game);
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    const scan_label: []const u8 = if (state.modfile_scan_busy) "Scanning\u{2026}" else "Scan mods folder";
    if (style.button(@src(), scan_label, .{}, .{})) {
        actions.clearPendingDelete(frame);
        if (!state.modfile_scan_busy) actions.doScanModfiles(frame, game);
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    if (style.button(@src(), "Import recipe...", .{}, .{})) {
        actions.clearPendingDelete(frame);
        pickAndImportModRecipe(frame);
    }

    if (!state.modfile_scan_msg.isEmpty()) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        const txt = state.modfile_scan_msg.read();
        dvui.label(@src(), "{s}", .{txt}, .{ .gravity_y = 0.5 });
    }
}

fn renderModfileRow(frame: *Frame, game: *const library.Game, m: anytype, presets: []const recipe.Preset) void {
    const state = frame.state;
    // Single horizontal row: info column on the left grows to fill,
    // action buttons sit flush right. Two compact lines of info stack
    // inside the left column so the row reads at the same height as
    // a button.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .id_extra = std.hash.Wyhash.hash(0, m.id),
    });
    defer row.deinit();

    // ---- left: info column ----
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer info.deinit();

        dvui.label(@src(), "{s}", .{m.filename}, .{ .style = .highlight });

        // Second line — size · sha-prefix · recipe linkage, joined
        // into one bufPrint so it always lays out on a single line
        // even if the row gets narrow.
        var sz_buf: [32]u8 = undefined;
        const sz_txt = if (m.size_bytes >= 1024 * 1024)
            std.fmt.bufPrint(&sz_buf, "{d:.1} MiB", .{@as(f64, @floatFromInt(m.size_bytes)) / (1024.0 * 1024.0)}) catch "?"
        else
            std.fmt.bufPrint(&sz_buf, "{d:.1} KiB", .{@as(f64, @floatFromInt(m.size_bytes)) / 1024.0}) catch "?";
        const sha_prefix = m.id[0..@min(12, m.id.len)];
        var meta_buf: [320]u8 = undefined;
        const meta_txt = if (m.recipe_ids.len > 0) blk: {
            // First-link-then-count summary keeps the meta line short
            // even when many recipes share the archive.
            const head = m.recipe_ids[0];
            if (m.recipe_ids.len == 1) {
                break :blk std.fmt.bufPrint(&meta_buf, "{s}  -  sha:{s}...  -  linked: {s}", .{ sz_txt, sha_prefix, head }) catch sz_txt;
            }
            break :blk std.fmt.bufPrint(&meta_buf, "{s}  -  sha:{s}...  -  linked: {s} (+{d} more)", .{ sz_txt, sha_prefix, head, m.recipe_ids.len - 1 }) catch sz_txt;
        } else if (m.preset_id) |p|
            std.fmt.bufPrint(&meta_buf, "{s}  -  sha:{s}...  -  preset: {s}", .{ sz_txt, sha_prefix, p }) catch sz_txt
        else
            std.fmt.bufPrint(&meta_buf, "{s}  -  sha:{s}...  -  (no recipe)", .{ sz_txt, sha_prefix }) catch sz_txt;
        dvui.label(@src(), "{s}", .{meta_txt}, .{ .color_text = HELP_TEXT_COLOR });
    }

    // ---- right: action buttons ----
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
        defer btns.deinit();

        // Preset override — only meaningful while no recipe is bound.
        // Once a recipe exists, its install steps supersede the
        // preset attribution, and showing a dropdown would suggest
        // an effect the click won't have.
        if (m.recipe_ids.len == 0 and presets.len > 0) {
            renderPresetOverrideDropdown(frame, game, m, presets);
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        }

        if (m.recipe_ids.len > 0) {
            // "Create another..." lets a single archive back multiple
            // recipes (e.g. one per game-version target).
            if (style.button(@src(), "Create another...", .{}, .{})) {
                actions.clearPendingDelete(frame);
                actions.openWizardForModfile(frame, game, m.id);
            }
        } else {
            if (style.button(@src(), "Create recipe...", .{}, .{ .style = .highlight })) {
                actions.clearPendingDelete(frame);
                actions.openWizardForModfile(frame, game, m.id);
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

        const pending_slice = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
        const armed = std.mem.eql(u8, pending_slice, m.id);
        const del_label: []const u8 = if (armed) "Confirm delete from disk" else "Delete";
        if (style.button(@src(), del_label, .{}, .{ .style = .err })) {
            actions.doDeleteModfile(frame, game, m.id);
        }
    }
}

/// Per-row preset chooser. Index 0 is "None"; the rest map 1:1 onto
/// `presets`. Strings live in the bundle's arena (loaded one level up
/// in `renderModfiles`), so they stay valid for the entire dropdown
/// call including the popup-menu render. On selection change, dispatches
/// the new id (or null) to `setPresetId`.
fn renderPresetOverrideDropdown(
    frame: *Frame,
    game: *const library.Game,
    m: anytype,
    presets: []const recipe.Preset,
) void {
    // Build a label slice on the frame heap. Capacity = presets + 1
    // for the leading "None" row. Freed after the dropdown call —
    // dvui doesn't retain label slices across frames.
    const alloc = frame.lib.alloc;
    const labels = alloc.alloc([]const u8, presets.len + 1) catch return;
    defer alloc.free(labels);
    labels[0] = "None";
    for (presets, 0..) |p, i| labels[i + 1] = p.name;

    // Pick = index of currently-applied preset, or 0 ("None") when
    // `preset_id` is null or stale (id no longer in the merged set).
    var pick: usize = 0;
    if (m.preset_id) |pid| {
        for (presets, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, pid)) {
                pick = i + 1;
                break;
            }
        }
    }
    const prev = pick;

    if (style.dropdown(@src(), labels, .{ .choice = &pick }, .{}, .{
        .id_extra = std.hash.Wyhash.hash(1, m.id),
        .min_size_content = .{ .w = 140, .h = style.button_h },
        .gravity_y = 0.5,
    })) {
        if (pick != prev) {
            const new_id: ?[]const u8 = if (pick == 0) null else presets[pick - 1].id;
            actions.doSetModfilePreset(frame, game, m.id, new_id);
        }
    }
}

// ============================================================
//  Recipe wizard modal
// ============================================================

/// Full-page recipe editor — replaces the old modal wizard. All four
/// sections (metadata, install steps, relations, save) render as
/// stacked panels on a single scrolling page. The user can see the
/// preview pane in context with the install plan without juggling
/// modal "Next/Back" navigation.
pub fn recipeEditorScreen(frame: *Frame) !bool {
    const state = frame.state;

    // No wizard state in flight → the user got here via stale state or
    // a back-nav after closeWizard. Bounce home.
    if (state.wizard == null) {
        state.screen = .detail;
        return true;
    }

    // Resolve the parent game from the wizard's thread id; needed by
    // most of the section renderers.
    const w_ptr = &state.wizard.?;
    const game_opt = gameByThreadId(frame, w_ptr.game_thread_id);
    const game = game_opt orelse {
        // Game vanished (deleted mid-edit). Drop the wizard.
        actions.closeWizard(frame);
        return true;
    };

    // ---- header bar: back link + title ----
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        });
        defer hdr.deinit();
        if (style.button(@src(), "< Back", .{}, .{})) {
            actions.closeWizard(frame);
            return true;
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Set up install plan — {s}", .{game.name}) catch "Set up install plan";
        dvui.label(@src(), "{s}", .{title}, .{ .style = .highlight, .gravity_y = 0.5 });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var page_scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 24, .y = 12, .w = 24, .h = 12 },
    });
    defer page_scroll.deinit();

    // ---- section: metadata ----
    {
        editorSectionHeader("1. Metadata");
        renderWizardMeta(w_ptr);
    }

    editorSectionDivider("after-metadata");

    // ---- section: install steps + live preview pane underneath ----
    {
        editorSectionHeader("2. Install steps");
        renderWizardInstallBlocks(frame, game, w_ptr);
    }

    editorSectionDivider("after-install");

    // ---- section: relations ----
    {
        editorSectionHeader("3. Relations (optional)");
        renderWizardRelations(frame, game, w_ptr);
    }

    editorSectionDivider("after-relations");

    // ---- section: test + save ----
    {
        editorSectionHeader("4. Test & save");
        renderWizardReview(frame, game, w_ptr);

        if (w_ptr.err_msg_len > 0) {
            const err_txt = w_ptr.err_msg_buf[0..w_ptr.err_msg_len];
            dvui.label(@src(), "Error: {s}", .{err_txt}, .{ .style = .err });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        }

        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 8, .h = 4 } });
            defer btn_row.deinit();
            if (style.button(@src(), "Cancel", .{}, .{ .style = .err })) {
                actions.closeWizard(frame);
                return true;
            }
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            if (style.button(@src(), "Save install plan", .{}, .{ .style = .highlight })) {
                actions.wizardSave(frame, game);
            }
        }
    }

    return true;
}

fn editorSectionHeader(title: []const u8) void {
    const key = std.hash.Wyhash.hash(0, title);
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 8 } });
    dvui.label(@src(), "{s}", .{title}, .{
        .style = .highlight,
        .id_extra = key,
    });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 4 } });
}

fn editorSectionDivider(key: []const u8) void {
    const k = std.hash.Wyhash.hash(0, key);
    _ = dvui.spacer(@src(), .{ .id_extra = k, .min_size_content = .{ .w = 1, .h = 12 } });
    _ = dvui.separator(@src(), .{ .id_extra = k, .expand = .horizontal });
}

/// Locate a game by F95 thread id from the per-frame `games` slice.
/// Shared by `recipeEditorScreen` and `modsScreen` — both arrive at
/// a screen carrying only the thread id (wizard state / selected
/// thread respectively).
fn gameByThreadId(frame: *Frame, thread_id: u64) ?*const library.Game {
    for (frame.games) |*g| {
        if (g.f95_thread_id == thread_id) return g;
    }
    return null;
}

fn renderWizardMeta(w: *state_mod.WizardState) void {
    dvui.label(@src(), "Mod metadata. Required: Name, Version, Targets game version.", .{}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    wizardTextRow(@src(), "Name", &w.name_buf);
    wizardTextRow(@src(), "Version", &w.version_buf);
    wizardTextRow(@src(), "F95 post URL", &w.post_url_buf);

    // Target-game-version: dropdown over installed builds. The wizard
    // refuses to open when there are no installs (in actions.zig), so
    // we always have ≥1 entry here. Selecting a row mirrors it into
    // `for_game_version_buf` so the serializer doesn't have to know
    // about the dropdown indirection.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
        defer row.deinit();
        dvui.label(@src(), "Targets game version", .{}, .{
            .min_size_content = .{ .w = 160, .h = 24 },
            .gravity_y = 0.5,
            .color_text = HELP_TEXT_COLOR,
        });

        // Build a list of `[]const u8` slices into the wizard's
        // 32-byte fixed-size buffers — dvui.dropdown takes the slice
        // of slices and shows them as menu entries.
        var labels_buf: [state_mod.WIZARD_MAX_INSTALL_VERSIONS][]const u8 = undefined;
        var labels_n: usize = 0;
        while (labels_n < w.install_versions_count) : (labels_n += 1) {
            const v = w.install_versions_buf[labels_n];
            const end = std.mem.indexOfScalar(u8, &v, 0) orelse v.len;
            labels_buf[labels_n] = w.install_versions_buf[labels_n][0..end];
        }
        const labels = labels_buf[0..labels_n];

        var pick: usize = w.install_versions_pick;
        if (style.dropdown(@src(), labels, .{ .choice = &pick }, .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 280, .h = 26 },
            .gravity_y = 0.5,
        })) {
            w.install_versions_pick = pick;
            // Mirror the picked label into for_game_version_buf so
            // wizardSave reads it without poking at the buffers array.
            @memset(&w.for_game_version_buf, 0);
            const picked_label = labels[pick];
            const n = @min(picked_label.len, w.for_game_version_buf.len);
            @memcpy(w.for_game_version_buf[0..n], picked_label[0..n]);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    dvui.label(@src(), "for_game (auto): {s}", .{w.for_game_buf[0..w.for_game_len]}, .{ .color_text = HELP_TEXT_COLOR });
}

fn wizardTextRow(src: std.builtin.SourceLocation, label: []const u8, buf: []u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
    defer row.deinit();
    dvui.label(@src(), "{s}", .{label}, .{ .min_size_content = .{ .w = 160, .h = 24 }, .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 280, .h = 26 },
        .gravity_y = 0.5,
    });
    te.deinit();
}

/// Wizard text input + Browse popups for archive- and install-side
/// suggestions. Each non-empty list gets its own folder-icon button.
/// Click an item → fills `buf` (with a trailing `/`). Empty lists hide
/// the corresponding button. `block_idx` + `field_idx` ensure every
/// menu has a unique id_extra so multiple browse menus on the same
/// page don't collide.
fn wizardPathRow(
    src: std.builtin.SourceLocation,
    label: []const u8,
    buf: []u8,
    archive_dirs: []const []const u8,
    install_dirs: []const []const u8,
    block_idx: usize,
    field_idx: usize,
) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
    defer row.deinit();
    dvui.label(@src(), "{s}", .{label}, .{ .min_size_content = .{ .w = 160, .h = 24 }, .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 280, .h = 26 },
        .gravity_y = 0.5,
    });
    te.deinit();

    if (archive_dirs.len > 0) {
        wizardBrowseMenu(buf, archive_dirs, "Pick from archive", "browse-arch", block_idx, field_idx, 0);
    }
    if (install_dirs.len > 0) {
        wizardBrowseMenu(buf, install_dirs, "Pick from install", "browse-inst", block_idx, field_idx, 1);
    }
}

/// Render one Browse menu (folder icon with submenu of suggestions).
/// `salt` differentiates archive vs install menus on the same row.
fn wizardBrowseMenu(
    buf: []u8,
    suggestions: []const []const u8,
    tooltip: []const u8,
    id_tag: []const u8,
    block_idx: usize,
    field_idx: usize,
    salt: u8,
) void {
    _ = tooltip;
    const menu_key: u32 = @intCast(((block_idx & 0xFFFF) << 16) | ((field_idx & 0xFF) << 8) | salt);
    var m = dvui.menu(@src(), .horizontal, .{ .id_extra = menu_key, .gravity_y = 0.5 });
    defer m.deinit();
    if (dvui.menuItemIcon(@src(), id_tag, entypo.folder, .{ .submenu = true }, .{
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .min_size_content = .{ .w = 28, .h = style.button_h },
        .gravity_y = 0.5,
        .background = true,
        .style = .control,
        .corner_radius = style.corner_radius,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();
        for (suggestions, 0..) |s, i| {
            var sbuf: [256]u8 = undefined;
            const item = std.fmt.bufPrint(&sbuf, "{s}/", .{s}) catch s;
            if (dvui.menuItemLabel(@src(), item, .{}, .{
                .id_extra = @intCast(i),
                .expand = .horizontal,
            }) != null) {
                @memset(buf, 0);
                const n = @min(item.len, buf.len);
                @memcpy(buf[0..n], item[0..n]);
                m.close();
            }
        }
    }
}

fn renderWizardInstallBlocks(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    // Simulate the current plan once per paint. The result threads
    // through the block-rows (for per-block counts + inline diagnostics)
    // and the bottom summary panel (aggregate + detail list).
    var sim_opt = actions.simulateCurrentPlan(frame, game);
    defer if (sim_opt) |*s| s.deinit();
    const sim_ptr: ?*const installer_mod.SimulationResult = if (sim_opt) |*s| s else null;

    // Suggestion sources for the Browse… menus on each path field.
    // Computed once per paint; freed at end. Two independent lists:
    //   - archive top-level dirs (source-side suggestions)
    //   - install dir top-level dirs (destination-side suggestions)
    // Either can be empty (e.g. archive missing, install dir not on
    // disk yet) — wizardPathRow hides the corresponding browse menu.
    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    const archive_path_opt = actions.modfileArchivePath(frame, game, modfile_id);
    defer if (archive_path_opt) |p| frame.lib.alloc.free(p);
    const archive_dirs_opt = if (archive_path_opt) |p| actions.archiveTopDirs(frame, p) else null;
    defer if (archive_dirs_opt) |d| actions.freeTopDirs(frame.lib.alloc, d);
    const archive_dirs: []const []const u8 = if (archive_dirs_opt) |d| @as([]const []const u8, d) else &.{};

    const install_dirs_opt = actions.installTopDirs(frame, game);
    defer if (install_dirs_opt) |d| actions.freeTopDirs(frame.lib.alloc, d);
    const install_dirs: []const []const u8 = if (install_dirs_opt) |d| @as([]const []const u8, d) else &.{};

    dvui.label(@src(), "What this mod will do — steps applied in order at install time.", .{}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    var i: usize = 0;
    while (i < w.block_count) : (i += 1) {
        renderWizardBlockRow(frame, w, i, sim_ptr, archive_dirs, install_dirs);
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer col.deinit();
        dvui.label(@src(), "Add step:", .{}, .{ .color_text = HELP_TEXT_COLOR });
        // Split into two rows so labels fit at typical wizard widths.
        // Shortened to one-two words; the help text under the added
        // block explains the full action.
        {
            var r1 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2 } });
            defer r1.deinit();
            if (style.button(@src(), "Drop in...", .{}, .{})) actions.wizardAddBlock(frame, .extract);
            if (style.button(@src(), "Unpack inner...", .{}, .{})) actions.wizardAddBlock(frame, .extract_inner);
            if (style.button(@src(), "Copy...", .{}, .{})) actions.wizardAddBlock(frame, .copy);
        }
        {
            var r2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2 } });
            defer r2.deinit();
            if (style.button(@src(), "Rename...", .{}, .{})) actions.wizardAddBlock(frame, .move);
            if (style.button(@src(), "Remove...", .{}, .{})) actions.wizardAddBlock(frame, .delete);
            if (style.button(@src(), "Runnable...", .{}, .{})) actions.wizardAddBlock(frame, .chmod_x);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    {
        // Distinct parent so this preview pane's widget ids don't
        // collide with the second instance under the Review section.
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .id_extra = std.hash.Wyhash.hash(0, "sim-panel-blocks"),
        });
        defer wrap.deinit();
        renderSimulationPanel(frame, w, sim_ptr);
    }
}

/// Aggregate preview + collapsible per-file detail. Pulled out of the
/// install-blocks step so the Review step can render the same panel
/// without re-running the simulation.
fn renderSimulationPanel(
    frame: *Frame,
    w: *state_mod.WizardState,
    sim_opt: ?*const installer_mod.SimulationResult,
) void {
    if (sim_opt == null) {
        dvui.label(@src(), "Preview: not available yet (need an install + an archive on disk).", .{}, .{ .color_text = HELP_TEXT_COLOR });
        return;
    }
    const sim = sim_opt.?;

    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        dvui.label(@src(), "Preview", .{}, .{ .style = .highlight, .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        const has_rows = sim.writes.len > 0 or sim.mode_changes.len > 0 or sim.deletions.len > 0;
        if (has_rows) {
            const lbl: []const u8 = if (w.sim_details_expanded) "Hide details" else "Show details";
            if (style.button(@src(), lbl, .{}, .{ .gravity_y = 0.5 })) {
                w.sim_details_expanded = !w.sim_details_expanded;
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    renderSimulationAggregate(sim);

    if (w.sim_details_expanded) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        renderSimulationDetail(frame, w, sim);
    }
}

/// Plain-English aggregate (one labeled line per category). Hidden
/// when the plan is empty.
fn renderSimulationAggregate(sim: *const installer_mod.SimulationResult) void {
    const add_n = sim.addCount();
    const ow_van = sim.overwriteVanillaCount();
    const ow_mod = sim.overwriteModCount();
    const total_bytes = sim.totalBytes();
    const mode_n = sim.mode_changes.len;
    const del_n = sim.deletions.len;

    if (add_n + ow_van + ow_mod == 0 and mode_n == 0 and del_n == 0) {
        dvui.label(@src(), "This plan won't touch any files. Add at least one step above.", .{}, .{ .color_text = HELP_TEXT_COLOR });
        return;
    }

    if (add_n > 0) {
        var size_buf: [32]u8 = undefined;
        const size_txt = humanBytes(&size_buf, total_bytes);
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "+ Adds {d} new file(s)  ({s})", .{ add_n, size_txt }) catch "+ Adds files";
        dvui.label(@src(), "{s}", .{txt}, .{ .color_text = .{ .r = 0x4F, .g = 0xC3, .b = 0x6F } });
    }
    if (ow_van > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "~ Overwrites {d} vanilla file(s)", .{ow_van}) catch "~ Overwrites vanilla";
        dvui.label(@src(), "{s}", .{txt}, .{ .color_text = .{ .r = 0xE0, .g = 0xC0, .b = 0x70 } });
    }
    if (ow_mod > 0) {
        var buf: [160]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "\u{26A0} Conflicts: {d} file(s) already owned by another mod", .{ow_mod}) catch "Conflicts with another mod";
        dvui.label(@src(), "{s}", .{txt}, .{ .color_text = .{ .r = 0xFF, .g = 0x80, .b = 0x80 } });
    }
    if (mode_n > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "* Marks {d} file(s) as runnable", .{mode_n}) catch "Marks file(s) runnable";
        dvui.label(@src(), "{s}", .{txt}, .{ .color_text = HELP_TEXT_COLOR });
    }
    if (del_n > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "- Removes {d} file(s)", .{del_n}) catch "Removes file(s)";
        dvui.label(@src(), "{s}", .{txt}, .{ .color_text = .{ .r = 0xE0, .g = 0xC0, .b = 0x70 } });
    }

    if (sim.diagnostics.len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        for (sim.diagnostics) |d| {
            // Step-scoped diagnostics show next to their block; this
            // panel only renders the global ones (no source step).
            if (d.source_step_index != null) continue;
            const color: dvui.Color = switch (d.severity) {
                .info => HELP_TEXT_COLOR,
                .warn => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
                .err => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
            };
            dvui.label(@src(), "{s}", .{d.msg}, .{ .color_text = color, .id_extra = std.hash.Wyhash.hash(0, d.msg) });
        }
    }
}

/// Tree-view detail with the install dir as the root header. Wraps
/// the rows in a `scrollArea` so long mod installs scroll instead of
/// stretching the wizard. Each directory rolls up file count + total
/// bytes from its descendants; files show action / size / step index.
/// 600-row hard cap to keep the renderer's worst case bounded.
fn renderSimulationDetail(frame: *Frame, w: *state_mod.WizardState, sim: *const installer_mod.SimulationResult) void {
    // Frame allocator (DebugAllocator-backed in debug builds) so the
    // per-paint tree's lifetime can be reported / leak-checked. Arena
    // sits on top of it for cheap one-deinit cleanup of the per-node
    // strings.
    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    // Build the tree once per paint. Small enough (one allocation per
    // path segment, max a few thousand) that we don't bother caching.
    const root = TreeNode.init(aalloc, "", "", false) catch return;
    for (sim.writes) |*wr| insertWrite(aalloc, root, wr) catch {};
    for (sim.mode_changes) |*mc| annotateMode(aalloc, root, mc) catch {};
    for (sim.deletions) |*d| annotateDeletion(aalloc, root, d) catch {};
    rollupAggregates(root);
    sortTree(root);

    // Outer pane — same look as before but the inner column lives in
    // a scrollArea so long trees scroll inside a bounded height.
    // `expand = .both` lets the pane consume any vertical room the
    // wizard modal hands down past the aggregate / button rows; the
    // `min_size_content.h` floor keeps it usable even when the modal
    // is shrunk by the user.
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .color_fill = .{ .r = 0x14, .g = 0x0A, .b = 0x10 },
        .color_border = style.border_color,
        .min_size_content = .{ .w = 1, .h = 240 },
    });
    defer pane.deinit();

    // Root header — "<install_path>/" with aggregate counts. The
    // path here is the GAME ROOT (after wrapper-folder detection in
    // `simulateCurrentPlan`), so it matches where files will actually
    // land on disk.
    {
        var hdr_buf: [768]u8 = undefined;
        var counts_buf: [128]u8 = undefined;
        const counts_txt = std.fmt.bufPrint(&counts_buf, " ({d} file(s), {s})", .{
            root.sub_files,
            humanBytesLocal(root.sub_bytes),
        }) catch "";
        const hdr = std.fmt.bufPrint(&hdr_buf, "Game root: {s}/{s}", .{ sim.install_dir, counts_txt }) catch sim.install_dir;
        dvui.label(@src(), "{s}", .{hdr}, .{ .style = .highlight, .font = .theme(.mono) });
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
    });
    defer scroll.deinit();

    var rendered: usize = 0;
    const ROW_CAP: usize = 600;
    renderTreeNode(w, root, 1, &rendered, ROW_CAP);

    if (rendered >= ROW_CAP) {
        dvui.label(@src(), "... (more rows hidden; cap reached)", .{}, .{ .color_text = HELP_TEXT_COLOR });
    }
}

const TreeNode = struct {
    /// Last segment of the path (file or dir name).
    name: []const u8,
    /// Full path relative to install_dir. Used as a stable id_extra
    /// key for the row's dvui widget.
    rel_path: []const u8,
    /// True when this node represents a single file (leaf); false for
    /// directories.
    is_file: bool,
    /// Set for leaves that came from `sim.writes`.
    file: ?*const installer_mod.simulate_mod.FileWrite = null,
    /// Set for leaves that came from `sim.mode_changes` (chmod_x).
    /// May coexist with `file` (chmod on an extracted file).
    mode_change: ?*const installer_mod.simulate_mod.ModeChange = null,
    /// Set for leaves from `sim.deletions`.
    deletion: ?*const installer_mod.simulate_mod.PathDel = null,
    children: std.ArrayList(*TreeNode) = .empty,
    sub_files: usize = 0,
    sub_bytes: u64 = 0,

    pub fn init(a: std.mem.Allocator, name: []const u8, rel_path: []const u8, is_file: bool) !*TreeNode {
        const n = try a.create(TreeNode);
        n.* = .{ .name = name, .rel_path = rel_path, .is_file = is_file };
        return n;
    }
};

fn ensureChild(a: std.mem.Allocator, parent: *TreeNode, name: []const u8, rel_path: []const u8, is_file: bool) !*TreeNode {
    for (parent.children.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    const child = try TreeNode.init(a, name, rel_path, is_file);
    try parent.children.append(a, child);
    return child;
}

fn insertWrite(a: std.mem.Allocator, root: *TreeNode, w: *const installer_mod.simulate_mod.FileWrite) !void {
    const node = try walkOrCreate(a, root, w.rel_path);
    node.is_file = true;
    node.file = w;
}

fn annotateMode(a: std.mem.Allocator, root: *TreeNode, mc: *const installer_mod.simulate_mod.ModeChange) !void {
    const node = try walkOrCreate(a, root, mc.rel_path);
    if (node.file == null and node.deletion == null) node.is_file = true;
    node.mode_change = mc;
}

fn annotateDeletion(a: std.mem.Allocator, root: *TreeNode, d: *const installer_mod.simulate_mod.PathDel) !void {
    const node = try walkOrCreate(a, root, d.rel_path);
    if (node.file == null and node.mode_change == null) node.is_file = true;
    node.deletion = d;
}

fn walkOrCreate(a: std.mem.Allocator, root: *TreeNode, rel: []const u8) !*TreeNode {
    var cursor = root;
    var rest = rel;
    while (rest.len > 0) {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        if (slash) |s| {
            const seg = rest[0..s];
            // Build the full path-to-here so the node carries it.
            const here = if (cursor.rel_path.len == 0)
                try a.dupe(u8, seg)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ cursor.rel_path, seg });
            cursor = try ensureChild(a, cursor, try a.dupe(u8, seg), here, false);
            rest = rest[s + 1 ..];
        } else {
            const here = if (cursor.rel_path.len == 0)
                try a.dupe(u8, rest)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ cursor.rel_path, rest });
            const leaf = try ensureChild(a, cursor, try a.dupe(u8, rest), here, true);
            return leaf;
        }
    }
    return cursor;
}

fn rollupAggregates(node: *TreeNode) void {
    for (node.children.items) |c| rollupAggregates(c);
    if (node.is_file) {
        node.sub_files = 1;
        node.sub_bytes = if (node.file) |f| f.size_bytes else 0;
        return;
    }
    var files: usize = 0;
    var bytes: u64 = 0;
    for (node.children.items) |c| {
        files += c.sub_files;
        bytes += c.sub_bytes;
    }
    node.sub_files = files;
    node.sub_bytes = bytes;
}

fn sortTree(node: *TreeNode) void {
    std.mem.sort(*TreeNode, node.children.items, {}, struct {
        fn lessThan(_: void, a: *TreeNode, b: *TreeNode) bool {
            // Dirs (non-leaf) before files; otherwise name-asc.
            const a_dir = !a.is_file;
            const b_dir = !b.is_file;
            if (a_dir != b_dir) return a_dir;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    for (node.children.items) |c| sortTree(c);
}

fn renderTreeNode(
    w: *state_mod.WizardState,
    node: *TreeNode,
    depth: usize,
    rendered: *usize,
    cap: usize,
) void {
    for (node.children.items) |c| {
        if (rendered.* >= cap) return;
        renderOneRow(w, c, depth, rendered);
        if (!c.is_file) {
            renderTreeNode(w, c, depth + 1, rendered, cap);
        }
    }
}

fn renderOneRow(
    w: *state_mod.WizardState,
    node: *TreeNode,
    depth: usize,
    rendered: *usize,
) void {
    // Indent via leading spaces. Two spaces per depth level — mono
    // font is set on the labels so the columns line up.
    var indent_buf: [128]u8 = undefined;
    const indent_count = @min(depth * 2, indent_buf.len);
    @memset(indent_buf[0..indent_count], ' ');
    const indent = indent_buf[0..indent_count];

    const highlight = w.sim_highlight_step;
    const id_extra = std.hash.Wyhash.hash(3, node.rel_path);

    // Mono font at typical wizard widths fits ~60 chars per line
    // before the right edge clips. Reserve room for indent + suffix
    // metadata and middle-truncate names longer than the remainder.
    const max_name_len: usize = if (depth >= 4) 38 else 50;
    var name_buf: [128]u8 = undefined;
    const name_shown = truncMiddle(&name_buf, node.name, max_name_len);

    if (!node.is_file) {
        // Directory row — name + aggregate counts, dim.
        var line_buf: [320]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}/  ({d} file(s), {s})", .{
            indent, name_shown, node.sub_files, humanBytesLocal(node.sub_bytes),
        }) catch node.name;
        dvui.label(@src(), "{s}", .{line}, .{
            .id_extra = id_extra,
            .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 },
            .font = .theme(.mono),
        });
        rendered.* += 1;
        return;
    }

    // File row — action + name + size + step idx + extras.
    var action_glyph: []const u8 = "* "; // chmod-only by default
    var action_color: dvui.Color = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 };
    var step_idx: usize = 0;
    var dimmed = false;
    var extra_buf: [192]u8 = undefined;
    var extras: []const u8 = "";
    var size_bytes: u64 = 0;

    if (node.file) |f| {
        size_bytes = f.size_bytes;
        step_idx = f.source_step_index;
        action_glyph = switch (f.action) {
            .add => "+ ",
            .overwrite_vanilla => "~ ",
            .overwrite_mod => "! ",
        };
        action_color = switch (f.action) {
            .add => .{ .r = 0x4F, .g = 0xC3, .b = 0x6F },
            .overwrite_vanilla => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
            .overwrite_mod => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
        };
        if (f.conflicting_mod) |m| {
            extras = std.fmt.bufPrint(&extra_buf, "   (owned by `{s}`)", .{m}) catch "";
        }
    } else if (node.deletion) |d| {
        step_idx = d.source_step_index;
        action_glyph = "- ";
        action_color = if (!d.existed)
            .{ .r = 0xC0, .g = 0x90, .b = 0xA8 }
        else
            .{ .r = 0xE0, .g = 0xC0, .b = 0x70 };
        if (!d.existed) extras = "   (no matching file in plan)";
    } else if (node.mode_change) |mc| {
        step_idx = mc.source_step_index;
        if (mc.missing) {
            extras = "   (no-op - file not produced)";
            action_color = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 };
        }
    }

    if (highlight) |h| dimmed = h != step_idx;
    const eff_color = if (dimmed) HELP_TEXT_COLOR else action_color;

    var line_buf: [320]u8 = undefined;
    const size_txt = humanBytesLocal(size_bytes);
    const line = std.fmt.bufPrint(&line_buf, "{s}{s}{s}   {s}   step #{d}{s}", .{
        indent,
        action_glyph,
        name_shown,
        size_txt,
        step_idx + 1,
        extras,
    }) catch node.name;
    dvui.label(@src(), "{s}", .{line}, .{
        .id_extra = id_extra,
        .color_text = eff_color,
        .font = .theme(.mono),
    });
    rendered.* += 1;
}

/// Tiny humanBytes wrapper that returns a static-buffer string. Used
/// by the tree row formatter; each call has its own scratch.
fn humanBytesLocal(n: u64) []const u8 {
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    return humanBytes(&Static.buf, n);
}

/// Middle-ellipsize a string longer than `max_len` so it fits on a
/// tree row without sliding off the right edge of the scroll area.
/// Returns either the original slice (when short enough) or a view
/// into `out_buf` containing `<head>…<tail>`. UTF-8-naive — fine for
/// archive paths which are conventionally ASCII.
fn truncMiddle(out_buf: []u8, s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    if (out_buf.len < max_len) return s;
    if (max_len < 5) return s; // not enough room for "a…b"
    const ellipsis = "...";
    const head_len = (max_len - ellipsis.len) / 2;
    const tail_len = max_len - ellipsis.len - head_len;
    @memcpy(out_buf[0..head_len], s[0..head_len]);
    @memcpy(out_buf[head_len .. head_len + ellipsis.len], ellipsis);
    @memcpy(out_buf[head_len + ellipsis.len .. head_len + ellipsis.len + tail_len], s[s.len - tail_len ..]);
    return out_buf[0 .. head_len + ellipsis.len + tail_len];
}

/// Back-compat helper — Review step calls this. Re-runs the simulator
/// independently so the Review tab doesn't have to share state with
/// the install-blocks tab.
fn renderSimulationSummary(frame: *Frame, game: *const library.Game) void {
    var sim_opt = actions.simulateCurrentPlan(frame, game);
    defer if (sim_opt) |*s| s.deinit();
    const sim_ptr: ?*const installer_mod.SimulationResult = if (sim_opt) |*s| s else null;

    // Use the same panel as the install-blocks step so Review reads
    // identically — same details toggle, same aggregate counts.
    const w = &(frame.state.wizard orelse return);
    {
        // Distinct parent so the Review preview's widget ids don't
        // collide with the Install-blocks preview (same code, different
        // call site, both rendered on the same paint).
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .id_extra = std.hash.Wyhash.hash(0, "sim-panel-review"),
        });
        defer wrap.deinit();
        renderSimulationPanel(frame, w, sim_ptr);
    }
}


/// Plain-language label for a wizard block kind. Used in row titles.
fn blockKindLabel(k: state_mod.WizardBlockKind) []const u8 {
    return switch (k) {
        .extract => "Drop files in",
        .extract_inner => "Unpack nested archive",
        .copy => "Copy a file",
        .move => "Rename or move",
        .delete => "Remove a file",
        .chmod_x => "Mark a file as runnable",
    };
}

/// Per-block help text, shown under the kind label so the user
/// understands what this step does without leaving the wizard.
fn blockKindHelp(k: state_mod.WizardBlockKind) []const u8 {
    return switch (k) {
        .extract => "Unpack the archive into a folder of the game. Use \".\" for the install root.",
        .extract_inner => "Some mods ship as an archive inside an archive. This unpacks the inner one.",
        .copy => "Copy a file (already produced by an earlier step) to another location.",
        .move => "Rename or move a file that an earlier step put down.",
        .delete => "Remove a file (from the install dir, even a vanilla one).",
        .chmod_x => "Mark a script/binary as executable. No-op on Windows.",
    };
}

fn renderWizardBlockRow(
    frame: *Frame,
    w: *state_mod.WizardState,
    idx: usize,
    sim: ?*const installer_mod.SimulationResult,
    archive_dirs: []const []const u8,
    install_dirs: []const []const u8,
) void {
    const b = &w.blocks[idx];
    const is_highlight = w.sim_highlight_step != null and w.sim_highlight_step.? == idx;

    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .id_extra = idx,
        .background = is_highlight,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .corner_radius = style.corner_radius,
    });
    defer row.deinit();

    // ---- header: index + name + click-to-highlight + remove ----
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();

        const title_color: ?dvui.Color = if (is_highlight) .{ .r = 0xE9, .g = 0x4B, .b = 0x7A } else null;
        // Clickable title — toggles highlight on the simulation panel.
        if (style.button(@src(), blockKindLabel(b.kind), .{}, .{
            .style = if (is_highlight) .highlight else .control,
            .gravity_y = 0.5,
            .color_text = title_color,
        })) {
            w.sim_highlight_step = if (is_highlight) null else idx;
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        var idx_buf: [16]u8 = undefined;
        const idx_txt = std.fmt.bufPrint(&idx_buf, "step #{d}", .{idx + 1}) catch "step";
        dvui.label(@src(), "{s}", .{idx_txt}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Remove", .{}, .{ .style = .err })) {
            actions.wizardRemoveBlock(frame, idx);
            return;
        }
    }

    // ---- one-line help text ----
    dvui.label(@src(), "{s}", .{blockKindHelp(b.kind)}, .{ .color_text = HELP_TEXT_COLOR });

    // ---- per-block live-count summary, when sim is available ----
    if (sim) |s| {
        if (idx < s.impacts.len) {
            const imp = s.impacts[idx];
            renderBlockImpactLine(b.kind, imp);
        }
    }

    // ---- block-specific inputs ----
    // Per-field suggestion routing:
    //   source-shaped fields (archive contents) → archive_dirs only
    //   destination-shaped fields (install paths) → install_dirs only
    //   For each field, the unused slice is `&.{}` and the picker
    //   button hides automatically.
    const empty_dirs: []const []const u8 = &.{};
    switch (b.kind) {
        .extract => {
            wizardPathRow(@src(), "Drop into (folder under install)", &b.a_buf, empty_dirs, install_dirs, idx, 0);
            wizardStripCheckbox(b);
        },
        .extract_inner => {
            wizardPathRow(@src(), "Inner archive (relative to staged tree)", &b.a_buf, archive_dirs, empty_dirs, idx, 1);
            wizardPathRow(@src(), "Drop into (folder under install)", &b.b_buf, empty_dirs, install_dirs, idx, 2);
            wizardStripCheckbox(b);
        },
        .copy, .move => {
            wizardPathRow(@src(), "Source (path in archive or earlier-step output)", &b.a_buf, archive_dirs, empty_dirs, idx, 3);
            wizardPathRow(@src(), "Destination (path under install)", &b.b_buf, empty_dirs, install_dirs, idx, 4);
        },
        .delete => {
            wizardPathRow(@src(), "Path under install", &b.a_buf, empty_dirs, install_dirs, idx, 5);
        },
        .chmod_x => {
            wizardPathRow(@src(), "Path under install", &b.a_buf, empty_dirs, install_dirs, idx, 6);
        },
    }

    // ---- inline diagnostics for THIS block ----
    if (sim) |s| {
        for (s.diagnostics) |d| {
            if (d.source_step_index == null or d.source_step_index.? != idx) continue;
            const color: dvui.Color = switch (d.severity) {
                .info => HELP_TEXT_COLOR,
                .warn => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
                .err => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
            };
            dvui.label(@src(), "{s}", .{d.msg}, .{
                .color_text = color,
                .id_extra = std.hash.Wyhash.hash(0, d.msg) ^ @as(u64, idx),
            });
        }
    }
}

/// One-line "Will write N file(s), X.X MiB" under the block header
/// when the simulator has data for this block. Helps the user verify
/// each step before saving.
fn renderBlockImpactLine(kind: state_mod.WizardBlockKind, imp: installer_mod.simulate_mod.StepImpact) void {
    if (imp.no_op) {
        dvui.label(@src(), "No effect from this step yet.", .{}, .{ .color_text = HELP_TEXT_COLOR });
        return;
    }
    switch (kind) {
        .extract, .extract_inner, .copy => {
            if (imp.files_written == 0) return;
            var size_buf: [32]u8 = undefined;
            const size_txt = humanBytes(&size_buf, imp.bytes_written);
            var buf: [128]u8 = undefined;
            const mod_part: []const u8 = if (imp.files_modified > 0) blk: {
                var mb: [48]u8 = undefined;
                break :blk std.fmt.bufPrint(&mb, "  ({d} overwrite existing)", .{imp.files_modified}) catch "";
            } else "";
            const line = std.fmt.bufPrint(&buf, "Will write {d} file(s), {s}{s}", .{
                imp.files_written, size_txt, mod_part,
            }) catch "";
            dvui.label(@src(), "{s}", .{line}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
        .move => {
            if (imp.files_written == 0) return;
            dvui.label(@src(), "Will relocate 1 file.", .{}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
        .delete => {
            if (imp.deletions == 0) return;
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "Will remove {d} path(s).", .{imp.deletions}) catch "";
            dvui.label(@src(), "{s}", .{line}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
        .chmod_x => {
            if (imp.mode_changes == 0) return;
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "Will mark {d} file(s) runnable.", .{imp.mode_changes}) catch "";
            dvui.label(@src(), "{s}", .{line}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
    }
}

/// Plain-checkbox replacement for the old +/- strip stepper. The
/// integer field stays on the block (recipes support strip > 1 in
/// principle), but the wizard's UI maps it to a two-state toggle —
/// 0 (off) vs 1 (on). Covers the 99% case without forcing the user
/// to parse "strip components."
fn wizardStripCheckbox(b: *state_mod.WizardBlock) void {
    var on: bool = b.strip > 0;
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
    defer row.deinit();
    if (dvui.checkbox(@src(), &on, "Skip the top-level folder", .{})) {
        b.strip = if (on) 1 else 0;
    }
    const help: []const u8 = if (on)
        "Archive's top dir will be flattened — e.g. `MyMod-1.2/game/...` → `<install>/game/...`"
    else
        "Archive is extracted as-is — top dir, if any, becomes a subfolder of the destination.";
    dvui.label(@src(), "{s}", .{help}, .{ .color_text = HELP_TEXT_COLOR });
}

fn renderWizardRelations(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    _ = frame;
    _ = game;
    dvui.label(@src(), "Relations to other mods. Comma-separated recipe ids.", .{}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // For v1: each row is a fixed-size textbox the user types one id
    // into. Up to WIZARD_MAX_RELATIONS rows. A future polish pass can
    // turn this into a picker over `recipe_repo.listModsForGame`.
    // Each group must have a distinct id_extra on its outer box so
    // the three groups' children (label, rows, Add button) don't
    // collide on the same `@src()`. Without this dvui flags every
    // duplicate-widget error every frame.
    wizardRelationGroup(0, "Requires", &w.requires_buf, &w.requires_len);
    wizardRelationGroup(1, "Conflicts with", &w.conflicts_buf, &w.conflicts_len);
    wizardRelationGroup(2, "Load after", &w.load_after_buf, &w.load_after_len);
}

fn wizardRelationGroup(group_idx: usize, label: []const u8, bufs: [][64]u8, len: *usize) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .y = 4, .h = 4 },
        .id_extra = group_idx,
    });
    defer box.deinit();
    dvui.label(@src(), "{s}:", .{label}, .{ .style = .highlight });
    var i: usize = 0;
    while (i < len.*) : (i += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &bufs[i] } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 280, .h = 24 },
            .gravity_y = 0.5,
        });
        te.deinit();
        if (style.button(@src(), "−", .{}, .{ .style = .err })) {
            var j: usize = i;
            while (j + 1 < len.*) : (j += 1) {
                bufs[j] = bufs[j + 1];
            }
            @memset(&bufs[len.* - 1], 0);
            len.* -= 1;
            return;
        }
    }
    if (len.* < bufs.len) {
        if (style.button(@src(), "Add", .{}, .{})) {
            @memset(&bufs[len.*], 0);
            len.* += 1;
        }
    }
}

/// Trim a wizard inline buffer to the first null byte. Buffers are
/// fixed-size `[N]u8` zero-padded; raw slicing leaks the trailing
/// zeros which dvui renders as tofu/null-glyph boxes.
fn bufToSlice(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn renderWizardReview(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    dvui.label(@src(), "Review. Save writes <id>.mod.zon to your local recipes dir.", .{}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Slice the inline buffers up to the first null byte — printing
    // the raw fixed-size buffer leaks trailing zero bytes which dvui
    // renders as tofu/null-glyph boxes.
    const name = bufToSlice(&w.name_buf);
    const version = bufToSlice(&w.version_buf);
    dvui.label(@src(), "Name:    {s}", .{name}, .{});
    dvui.label(@src(), "Version: {s}", .{version}, .{});
    dvui.label(@src(), "for_game: {s}", .{w.for_game_buf[0..w.for_game_len]}, .{});

    var ver_count_buf: [64]u8 = undefined;
    const block_count_txt = std.fmt.bufPrint(&ver_count_buf, "{d}", .{w.block_count}) catch "?";
    dvui.label(@src(), "Install steps: {s}", .{block_count_txt}, .{});

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    if (w.requires_len > 0) dvui.label(@src(), "requires {d}", .{w.requires_len}, .{});
    if (w.conflicts_len > 0) dvui.label(@src(), "conflicts {d}", .{w.conflicts_len}, .{});
    if (w.load_after_len > 0) dvui.label(@src(), "load_after {d}", .{w.load_after_len}, .{});

    // Show the same preview here so the user has a final-look summary
    // before they hit Save. Game is needed for the install dir lookup.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    renderSimulationSummary(frame, game);

    // Test install (real). Runs the actual installer against a
    // scratch dir under /tmp; surfaces file count + total bytes as
    // a toast. Trust-but-verify before committing the recipe. The
    // worker runs on a background thread so the UI stays responsive
    // for large mods; button label flips to "Testing…" + click is a
    // no-op while in flight.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Trust-but-verify:", .{}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const running = actions.isTestInstallRunning(frame.state);
        const lbl: []const u8 = if (running) "Testing\u{2026}" else "Test install (real)";
        if (style.button(@src(), lbl, .{}, .{ .style = if (running) .control else null })) {
            if (!running) actions.doTestInstallPreview(frame, game);
        }
    }
    dvui.label(@src(), "Runs the actual installer against `/tmp/f69-preview-…` on a background thread. Doesn't touch your game's install dir.", .{}, .{ .color_text = HELP_TEXT_COLOR });
}

fn renderClashModal(frame: *Frame, game: *const library.Game) void {
    const m = actions.clashModalState(frame) orelse return;

    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 520, .h = 360 },
    });
    defer fw.deinit();

    _ = dvui.windowHeader("File conflicts", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer body.deinit();

    dvui.label(@src(), "Mod `{s}` overwrites paths owned by other installed mods.", .{m.recipe_id}, .{ .style = .err });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    dvui.label(@src(), "Last-applied wins — earlier mods' files will be replaced.", .{}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer list.deinit();
        for (m.conflicts) |c| {
            dvui.label(@src(), "  · {s}   ← owned by mod {s}", .{ c.path, c.with_mod_id }, .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        if (style.button(@src(), "Cancel", .{}, .{ .style = .err })) open = false;
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Install anyway (accept all)", .{}, .{ .style = .highlight })) {
            actions.clashModalAcceptAll(frame, game);
            // clashModalAcceptAll closed the modal already; nothing else to do.
            return;
        }
    }

    if (!open) actions.closeClashModal(frame);
}

fn pickAndAddModfile(frame: *Frame, game: *const library.Game) void {
    const filters = [_]file_picker.FilterItem{
        .{ .name = "Mod archives", .spec = "zip,7z,rar,tar,tar.gz,tar.bz2,tar.xz,tar.zst,tgz,tbz2,txz,gz,bz2,xz,zst" },
    };
    const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Picker failed: {s}", .{@errorName(e)}) catch "Picker failed";
        frame.state.setDownloadMsg(msg);
        return;
    } orelse return;
    defer frame.lib.alloc.free(picked);
    actions.doAddModfile(frame, game, picked);
}

fn renderNotesTab(frame: *Frame, game: *library.Game) void {
    const state = frame.state;

    // Lazy-load: only refill the buffer when switching games.
    if (state.notes_for_thread != game.f95_thread_id) {
        @memset(&state.notes_buf, 0);
        if (game.notes) |n| {
            const len = @min(n.len, state.notes_buf.len - 1);
            @memcpy(state.notes_buf[0..len], n[0..len]);
        }
        state.notes_for_thread = game.f95_thread_id;
    }

    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        defer bar.deinit();
        if (style.button(@src(), "Save", .{}, .{ .style = .highlight })) {
            const text_end = std.mem.indexOfScalar(u8, &state.notes_buf, 0) orelse state.notes_buf.len;
            const trimmed = std.mem.trim(u8, state.notes_buf[0..text_end], " \t\n\r");
            frame.lib.setNotes(game, trimmed) catch {};
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Clear", .{}, .{})) {
            @memset(&state.notes_buf, 0);
            frame.lib.setNotes(game, "") catch {};
        }
    }

    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.notes_buf },
        .multiline = true,
    }, .{
        .expand = .both,
        .min_size_content = .{ .w = 600, .h = 240 },
        .id_extra = game.f95_thread_id,
    });
    te.deinit();
}

/// Recipe tab — shows the install recipe for this game. If the user
/// has saved one to `<config>/f69/recipes/<id>.game.zon`, that file is
/// rendered. Otherwise we derive a minimal recipe from the scraped
/// metadata in-memory and display that, with a Save button to persist.
///
/// Phase-2 scope: read-only ZON view + Save. The inline editor (with
/// validation feedback) lands in phase 7.
fn renderRecipeTab(frame: *Frame, game: *library.Game) void {
    const alloc = frame.lib.alloc;

    // 1. Try loading from disk.
    var repo = recipe.Repo.init(alloc, frame.io, frame.info.recipes_dir);
    var recipe_id_buf: [64]u8 = undefined;
    const recipe_id = std.fmt.bufPrint(&recipe_id_buf, "{d}", .{game.f95_thread_id}) catch "id";

    var on_disk: ?recipe.ParsedGame = null;
    defer if (on_disk) |*p| p.deinit();
    on_disk = repo.findGame(recipe_id) catch |e| blk: {
        std.log.scoped(.ui_recipe).warn("findGame failed: {s}", .{@errorName(e)});
        break :blk null;
    };

    // 2. Build display: prefer on-disk; fallback to a derived in-memory
    // recipe from current game state.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const display_recipe: recipe.GameRecipe = if (on_disk) |p|
        p.recipe
    else
        deriveLiveRecipe(aalloc, game) catch {
            dvui.label(@src(), "(failed to derive recipe)", .{}, .{});
            return;
        };

    // 3. Stringify for display.
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(aalloc, 4096) catch {
        dvui.label(@src(), "(out of memory)", .{}, .{});
        return;
    };
    std.zon.stringify.serialize(display_recipe, .{}, &aw.writer) catch {
        dvui.label(@src(), "(failed to serialize recipe)", .{}, .{});
        return;
    };
    const zon_text = aw.writer.buffered();

    // 4. Status row + Save button.
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        defer bar.deinit();
        const status: []const u8 = if (on_disk != null) "Saved recipe — derived from disk" else "Auto-derived (not saved)";
        dvui.label(@src(), "{s}", .{status}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), if (on_disk != null) "Re-save" else "Save", .{}, .{ .style = .highlight })) {
            // Re-derive fresh from the live game and write — captures
            // any sync that happened since the tab was opened.
            const fresh = deriveLiveRecipe(aalloc, game) catch {
                std.log.scoped(.ui_recipe).warn("derive failed at save", .{});
                return;
            };
            repo.saveGame(&fresh) catch |e| {
                std.log.scoped(.ui_recipe).warn("saveGame failed: {s}", .{@errorName(e)});
                return;
            };
        }
    }

    // 5. Read-only ZON pane.
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .color_fill = .{ .r = 0x14, .g = 0x0A, .b = 0x10 },
        .color_border = style.border_color,
        .min_size_content = .{ .w = 1, .h = 240 },
    });
    defer pane.deinit();
    dvui.label(@src(), "{s}", .{zon_text}, .{
        .expand = .horizontal,
        .font = .theme(.mono),
    });
}

/// Build an in-memory recipe from the current Game state. Used when no
/// recipe file exists yet — gives the user something concrete to look
/// at + save. `download_links` is empty for now: the F95 OP scrape
/// doesn't extract host-tagged download URLs yet (phase 4 work).
fn deriveLiveRecipe(arena: std.mem.Allocator, game: *const library.Game) !recipe.GameRecipe {
    const engine = mapLibEngine(game.engine);
    const version = game.latest_version orelse "0";
    return try recipe.derive.deriveGameRecipe(arena, .{
        .thread_id = game.f95_thread_id,
        .name = game.name,
        .version = version,
        .download_links = &.{},
        .engine = engine,
        .engine_version = null,
    });
}

/// `library.Engine` and `recipe.Engine` are different enums (recipe's
/// is narrower). Map the common cases; everything else collapses to
/// `.unknown`.
fn mapLibEngine(e: library.Engine) recipe.Engine {
    return switch (e) {
        .renpy => .renpy,
        .rpgm_mv => .rpgm_mv,
        .rpgm_mz => .rpgm_mz,
        .unity => .unity,
        else => .unknown,
    };
}

// ============================================================
//  settings screen
// ============================================================

pub fn settingsScreen(frame: *Frame) !bool {
    const state = frame.state;

    // ----- sticky top bar -----
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Settings", .{}, .{ .gravity_y = 0.5, .style = .highlight });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ----- tab bar -----
    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
        });
        defer tabs.deinit();

        if (tabButton("General", state.settings_tab == .general)) state.settings_tab = .general;
        if (tabButton("Sync", state.settings_tab == .sync)) state.settings_tab = .sync;
        if (tabButton("Accounts", state.settings_tab == .accounts)) state.settings_tab = .accounts;
        if (tabButton("Library", state.settings_tab == .library)) state.settings_tab = .library;
        if (tabButton("Downloads", state.settings_tab == .downloads)) state.settings_tab = .downloads;
        if (tabButton("Mod presets", state.settings_tab == .mod_presets)) state.settings_tab = .mod_presets;
        if (tabButton("Convert presets", state.settings_tab == .convert_presets)) state.settings_tab = .convert_presets;
        if (tabButton("About", state.settings_tab == .about)) state.settings_tab = .about;
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ----- body — scrollable per-tab area -----
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    switch (state.settings_tab) {
        .general => renderSettingsGeneral(frame),
        .sync => renderSettingsSync(frame),
        .accounts => renderSettingsAccounts(frame),
        .library => renderSettingsLibrary(frame),
        .downloads => renderSettingsDownloads(frame),
        .mod_presets => renderSettingsModPresets(frame),
        .convert_presets => renderSettingsConvertPresets(frame),
        .about => renderSettingsAbout(frame),
    }

    return true;
}

/// General tab — UI scale + browser path.
fn renderSettingsGeneral(frame: *Frame) void {
    renderUiScaleSection(frame);
    settingsSectionDivider(1);
    renderBrowserSection(frame);
    settingsSectionDivider(8);
    renderAutoConvertSection(frame);
    settingsSectionDivider(9);
    renderSandboxDefaultSection(frame);
    settingsSectionDivider(10);
    renderAutoUpdateDefaultSection(frame);
}

/// "Auto-download updates" checkbox. When on, the batch sync /
/// scheduled update-check kicks off a Download for any game whose
/// version moved AND has an auto-fetchable recipe source. Each game's
/// detail-page dropdown can override this.
fn renderAutoUpdateDefaultSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Auto-download updates", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "When sync finds a newer version, automatically download + install it. " ++
            "Only fires from batch sync (Sync All / scheduled update-check), never from a single-game sync. " ++
            "Manual installs without a recipe are skipped — they need a fresh archive to update.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    _ = dvui.checkbox(@src(), &state.auto_update_default, "Auto-download updates on batch sync", .{});
}

/// "Sandbox on launch by default" checkbox. Each game's per-game
/// SandboxOverride wins over this — only `.use_default` consults it.
fn renderSandboxDefaultSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Sandbox on launch", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Run games inside a sandbox by default (bwrap on Linux, Sandboxie on Windows). " ++
            "Each game's detail page can override this with always / never.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    _ = dvui.checkbox(@src(), &state.sandbox_default, "Sandbox games by default", .{});
}

/// "Auto-convert new installs" checkbox. When on, post-install
/// kicks off Convert immediately after the archive extracts (for
/// games with a recipe `convert_linux` block). Off by default
/// because Convert pulls SDKs and can be slow.
fn renderAutoConvertSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Auto-convert new installs", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "When a download finishes and extracts, automatically run Convert (Ren'Py / RPGM Win→Linux). " ++
            "Requires a recipe with a `convert_linux` block — games without one need manual Convert.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    _ = dvui.checkbox(@src(), &state.auto_convert, "Convert new installs automatically", .{});
}

/// Sync tab — auto-check preferences + the F95 rate-limit info row.
fn renderSettingsSync(frame: *Frame) void {
    renderAutoCheckSection(frame);
    settingsSectionDivider(2);
    dvui.label(@src(), "Network", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    var rl_buf: [32]u8 = undefined;
    const rl = std.fmt.bufPrint(&rl_buf, "{d} ms", .{frame.info.rate_limit_ms}) catch "?";
    var row_id: u32 = 0;
    settingsRow(&row_id, "F95 forum rate limit", rl);
    settingsHelpText(
        "Throttle between forum HTTP requests. Image fetches against attachments.f95zone.to (CDN) bypass this limit.",
    );
}

/// Accounts tab — F95 forum login + RPDL torrent login.
fn renderSettingsAccounts(frame: *Frame) void {
    renderF95Account(frame);
    settingsSectionDivider(3);
    renderRpdlAccount(frame);
}

/// Library tab — portable paths, library statistics, mod section.
fn renderSettingsLibrary(frame: *Frame) void {
    dvui.label(@src(), "Paths", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    var row_id: u32 = 0;
    settingsRow(&row_id, "Database", frame.info.db_path);
    settingsRow(&row_id, "Covers cache", frame.info.covers_dir);
    settingsRow(&row_id, "Library root", frame.info.library_root);

    settingsSectionDivider(3);

    renderSettingsImport(frame);

    settingsSectionDivider(4);

    dvui.label(@src(), "Statistics", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    const stats = libraryStats(frame.games);

    var n_buf: [32]u8 = undefined;
    settingsRow(&row_id, "Games loaded", std.fmt.bufPrint(&n_buf, "{d}", .{frame.games.len}) catch "?");
    var synced_buf: [48]u8 = undefined;
    settingsRow(&row_id, "Synced / unsynced", std.fmt.bufPrint(&synced_buf, "{d} / {d}", .{ stats.synced, stats.unsynced }) catch "?");

    var rate_buf: [48]u8 = undefined;
    if (stats.rated_count > 0) {
        const avg = stats.rating_sum / @as(f32, @floatFromInt(stats.rated_count));
        settingsRow(&row_id, "Mean F95 rating", std.fmt.bufPrint(&rate_buf, "\xE2\x98\x85 {d:.2} (over {d} games)", .{ avg, stats.rated_count }) catch "?");
    }

    var eng_buf: [256]u8 = undefined;
    settingsRow(&row_id, "Engines", std.fmt.bufPrint(
        &eng_buf,
        "Ren'Py {d} \xC2\xB7 RPGM {d}/{d}/{d} \xC2\xB7 Unity {d} \xC2\xB7 Unreal {d} \xC2\xB7 HTML {d} \xC2\xB7 Wolf {d} \xC2\xB7 ? {d}",
        .{
            stats.engine_renpy,
            stats.engine_rpgm_mv,    stats.engine_rpgm_mz,    stats.engine_rpgm_vx,
            stats.engine_unity,      stats.engine_unreal,
            stats.engine_html,       stats.engine_wolf_rpg,
            stats.engine_unknown,
        },
    ) catch "?");

    var tag_buf: [32]u8 = undefined;
    settingsRow(&row_id, "Distinct tags", std.fmt.bufPrint(&tag_buf, "{d}", .{stats.distinct_tags}) catch "?");

    var cover_buf: [32]u8 = undefined;
    var cover_filled: u32 = 0;
    for (frame.state.cover_cache) |slot| if (slot != null) {
        cover_filled += 1;
    };
    settingsRow(&row_id, "Cover cache", std.fmt.bufPrint(&cover_buf, "{d}/{d}", .{ cover_filled, frame.state.cover_cache.len }) catch "?");

    settingsSectionDivider(5);
    renderTagsRefreshSection(frame);
}

/// Settings → Library → Import section. Two buttons: F95Checker
/// (SQLite at ~/.config/f95checker/) and xLibrary (JSON at
/// ~/.config/xlibrary/). Each opens a folder picker for the source's
/// games-base-dir, then spawns the worker. A live banner under the
/// buttons surfaces progress while one is running.
fn renderSettingsImport(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Import library", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Bring in games + installs from F95Checker or xLibrary. Existing entries in this library are skipped. " ++
            "Install directories are copied + SHA-256 verified before the originals are removed, so a crash or " ++
            "verification mismatch leaves both copies intact.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const running = state.import_job != null;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    const f95_label: []const u8 = if (running) "Importing\u{2026}" else "Import from F95Checker\u{2026}";
    if (style.button(@src(), f95_label, .{}, .{
        .style = .highlight,
        .min_size_content = .{ .w = 240, .h = style.button_h },
    })) {
        if (!running) actions.doImportFromF95Checker(frame);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    const xl_label: []const u8 = if (running) "Importing\u{2026}" else "Import from xLibrary\u{2026}";
    if (style.button(@src(), xl_label, .{}, .{
        .min_size_content = .{ .w = 220, .h = style.button_h },
    })) {
        if (!running) actions.doImportFromXLibrary(frame);
    }

    if (running) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        renderImportBanner(frame);
    }
}

/// Banner under the import buttons while a job runs. Source name +
/// phase + per-game progress + cancel.
fn renderImportBanner(frame: *Frame) void {
    const job = frame.state.import_job orelse return;

    var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer bar.deinit();

    const phase = job.currentPhase();
    const phase_text = import_job_mod.phaseLabel(phase);
    const src_text: []const u8 = switch (job.source) {
        .f95checker => "F95Checker",
        .xlibrary => "xLibrary",
    };
    const done = job.progress_done.load(.monotonic);
    const total = job.progress_total.load(.monotonic);

    var hdr_buf: [192]u8 = undefined;
    const hdr = if (total > 0)
        std.fmt.bufPrint(&hdr_buf, "{s} - {s} ({d}/{d})", .{ src_text, phase_text, done, total }) catch "Importing"
    else
        std.fmt.bufPrint(&hdr_buf, "{s} - {s}", .{ src_text, phase_text }) catch "Importing";

    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer line.deinit();
    dvui.label(@src(), "{s}", .{hdr}, .{ .gravity_y = 0.5, .style = .highlight });

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (style.button(@src(), "Cancel", .{}, .{ .style = .err, .gravity_y = 0.5 })) {
        job.cancel.store(true, .release);
    }

    // Second row: which game is currently being migrated.
    job.current_mu.lockUncancelable(job.io);
    defer job.current_mu.unlock(job.io);
    const cur = job.currentSlice();
    if (cur.len > 0) {
        var cur_buf: [192]u8 = undefined;
        const cur_text = std.fmt.bufPrint(&cur_buf, "  current: {s}", .{cur}) catch cur;
        dvui.label(@src(), "{s}", .{cur_text}, .{
            .color_text = HELP_TEXT_COLOR,
            .id_extra = std.hash.Wyhash.hash(0, cur),
        });
    }
}

/// Downloads tab — aria2 daemon port + seed-ratio. Port changes
/// require an app restart
/// because aria2 binds the listener at spawn time and we don't tear
/// the daemon down on edit (in-flight downloads would die).
fn renderSettingsDownloads(frame: *Frame) void {
    const state = frame.state;

    dvui.label(@src(), "aria2 RPC port", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "TCP port for the local aria2 daemon's JSON-RPC. Leave blank or 0 to let aria2 pick a random " ++
            "ephemeral port on every launch. Setting a fixed port helps when you want to reuse the same " ++
            "firewall/forward rule across restarts.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    dvui.label(@src(), "Port", .{}, .{
        .min_size_content = .{ .w = 60, .h = 20 },
        .gravity_y = 0.5,
    });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.aria2_port_buf } }, .{
        .min_size_content = .{ .w = 120, .h = 28 },
        .gravity_y = 0.5,
    });
    te.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    if (style.button(@src(), "Save", .{}, .{ .style = .highlight, .gravity_y = 0.5 })) {
        if (actions.saveAria2Port(state, frame.info.aria2_port_path, frame.io)) |port| {
            var msg_buf: [80]u8 = undefined;
            const m = if (port == 0)
                std.fmt.bufPrint(&msg_buf, "saved (random port on next launch)", .{}) catch "saved"
            else
                std.fmt.bufPrint(&msg_buf, "saved — port {d} active after restart", .{port}) catch "saved";
            setAria2PortMsg(state, m);
        } else |e| {
            var msg_buf: [80]u8 = undefined;
            const m: []const u8 = switch (e) {
                error.PrivilegedPort => "ports 1..1023 are privileged — pick 1024+",
                error.InvalidCharacter, error.Overflow => "not a valid port number",
                else => std.fmt.bufPrint(&msg_buf, "save failed: {s}", .{@errorName(e)}) catch "save failed",
            };
            setAria2PortMsg(state, m);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    // Effective-now indicator: shows what's currently bound vs. what's
    // persisted on disk. Helps the user see that the change won't take
    // effect until restart.
    var live_buf: [64]u8 = undefined;
    const live_port = if (frame.dl_mgr.daemon) |d| d.port else 0;
    const live_msg = if (live_port == 0)
        "(aria2 not yet started)"
    else
        std.fmt.bufPrint(&live_buf, "now bound to {d}", .{live_port}) catch "(bound)";
    dvui.label(@src(), "{s}", .{live_msg}, .{
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });

    if (state.aria2_port_msg_len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.label(@src(), "{s}", .{state.aria2_port_msg_buf[0..state.aria2_port_msg_len]}, .{
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }

    settingsSectionDivider(7);

    // ----- BitTorrent seed-ratio target -----
    dvui.label(@src(), "Seed ratio", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "How much each completed torrent uploads before aria2 stops seeding. 2.0× is the RPDL community " ++
            "floor (give back twice what you took); 5.0× is the f69 default — generous and gets you a " ++
            "good-seeder reputation. Effective on next launch.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    var sr_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer sr_row.deinit();

    dvui.label(@src(), "Ratio", .{}, .{
        .min_size_content = .{ .w = 60, .h = 20 },
        .gravity_y = 0.5,
    });
    const sr_te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.aria2_seed_ratio_buf } }, .{
        .min_size_content = .{ .w = 120, .h = 28 },
        .gravity_y = 0.5,
    });
    sr_te.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    if (style.button(@src(), "Save", .{}, .{ .style = .highlight, .gravity_y = 0.5, .id_extra = 0xCEED })) {
        if (actions.saveAria2SeedRatio(state, frame.info.aria2_seed_ratio_path, frame.io)) |ratio| {
            var msg_buf: [80]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "saved — {d:.1}× target active after restart", .{ratio}) catch "saved";
            setAria2SeedRatioMsg(state, m);
        } else |e| {
            const m: []const u8 = switch (e) {
                error.Empty => "ratio cannot be blank",
                error.BelowFloor => "ratio must be ≥ 2.0",
                error.NotFinite => "not a finite number",
                error.InvalidCharacter => "not a valid number",
                else => "save failed",
            };
            setAria2SeedRatioMsg(state, m);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    var live_sr_buf: [48]u8 = undefined;
    const live_sr = if (frame.dl_mgr.daemon) |d| d.seed_ratio else 0;
    const live_sr_msg = if (live_sr == 0)
        "(aria2 not yet started)"
    else
        std.fmt.bufPrint(&live_sr_buf, "now using {d:.1}×", .{live_sr}) catch "(set)";
    dvui.label(@src(), "{s}", .{live_sr_msg}, .{
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });

    if (state.aria2_seed_ratio_msg_len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.label(@src(), "{s}", .{state.aria2_seed_ratio_msg_buf[0..state.aria2_seed_ratio_msg_len]}, .{
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }
}

fn setAria2PortMsg(state: *State, msg: []const u8) void {
    const n = @min(msg.len, state.aria2_port_msg_buf.len);
    @memcpy(state.aria2_port_msg_buf[0..n], msg[0..n]);
    state.aria2_port_msg_len = n;
}

fn setAria2SeedRatioMsg(state: *State, msg: []const u8) void {
    const n = @min(msg.len, state.aria2_seed_ratio_msg_buf.len);
    @memcpy(state.aria2_seed_ratio_msg_buf[0..n], msg[0..n]);
    state.aria2_seed_ratio_msg_len = n;
}

/// Master tag list refresh button. The list lives at
/// `<data_root>/tags.txt`; sidebar checkbox lists read from it.
/// Tags change rarely so this is a one-button manual refresh — we
/// don't auto-fetch.
fn renderTagsRefreshSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Tags", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Scrapes F95's tag index for the sidebar include/exclude checkboxes. Tags rarely change — refresh once in a while.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    const busy = state.pending_tags_refresh != null;
    const lbl: []const u8 = if (busy) "Refreshing…" else "Refresh tag list";
    const opts: dvui.Options = if (busy)
        .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 }, .gravity_y = 0.5 }
    else
        .{ .style = .highlight, .gravity_y = 0.5 };
    if (iconButton(@src(), lbl, entypo.cycle, opts) and !busy) {
        actions.startRefreshTags(frame);
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

    var info_buf: [128]u8 = undefined;
    const info_text: []const u8 = blk: {
        if (state.tags_master.len == 0 and state.tags_master_fetched_at == 0) {
            break :blk "no tags cached yet";
        }
        if (state.tags_master_fetched_at == 0) {
            break :blk std.fmt.bufPrint(&info_buf, "{d} tags (never refreshed)", .{state.tags_master.len}) catch "cached";
        }
        var ts_buf: [32]u8 = undefined;
        const ts = formatUtcDateTime(&ts_buf, state.tags_master_fetched_at) catch "—";
        break :blk std.fmt.bufPrint(&info_buf, "{d} tags · last refresh {s}", .{ state.tags_master.len, ts }) catch "cached";
    };
    dvui.label(@src(), "{s}", .{info_text}, .{
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });
}

/// Mod-preset management tab. Lists every preset currently loaded
/// (built-ins + user) with id, name, engine hint, source, and a
/// Delete button for user-authored entries. Built-ins are read-only
/// — they ship with the binary and are restored every launch.
fn renderSettingsModPresets(frame: *Frame) void {
    dvui.label(@src(), "Mod-install presets", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Presets match an archive's file layout to an install recipe so f69 can pick the right " ++
            "install steps automatically when you add a mod. Built-in presets ship with the app; " ++
            "user presets live in `<data_root>/mod-presets/` and override built-ins of the same id. " ++
            "Use \"Save as preset…\" on a working mod row to author one from a known-good recipe.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });

    const bundle_ptr = actions.getMergedPresets(frame) orelse {
        dvui.label(@src(), "Failed to load preset bundle.", .{}, .{ .style = .err });
        return;
    };

    if (bundle_ptr.presets.len == 0) {
        dvui.label(@src(), "No presets loaded.", .{}, .{});
        return;
    }

    // Dir path readout — helps the user find where to drop ZON files.
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer bar.deinit();
        dvui.label(@src(), "User dir:", .{}, .{ .color_text = HELP_TEXT_COLOR });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.label(@src(), "{s}", .{frame.info.mod_presets_dir}, .{
            .font = .theme(.mono),
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const armed_id = frame.state.presetPendingDeleteSlice();
    for (bundle_ptr.presets, bundle_ptr.from_user, 0..) |p, from_user, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .id_extra = std.hash.Wyhash.hash(0, p.id) ^ @as(u64, i),
        });
        defer row.deinit();

        // Left: name + id + engine + description.
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            defer info.deinit();

            // Header — name + source tag.
            {
                var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer hdr.deinit();
                dvui.label(@src(), "{s}", .{p.name}, .{ .style = .highlight });
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
                const tag: []const u8 = if (from_user) "[user]" else "[built-in]";
                dvui.label(@src(), "{s}", .{tag}, .{
                    .color_text = if (from_user)
                        .{ .r = 0xE9, .g = 0x4B, .b = 0x7A }
                    else
                        HELP_TEXT_COLOR,
                });
            }

            // Sub-line — id + engine + weight + pattern count.
            var sub_buf: [256]u8 = undefined;
            const engine_txt: []const u8 = if (p.engine_hint) |e| @tagName(e) else "any";
            const sub_txt = std.fmt.bufPrint(&sub_buf, "id: {s}  \u{00B7}  engine: {s}  \u{00B7}  patterns: {d}  \u{00B7}  weight: {d:.1}", .{
                p.id, engine_txt, p.match.requires.len, p.weight,
            }) catch p.id;
            dvui.label(@src(), "{s}", .{sub_txt}, .{ .color_text = HELP_TEXT_COLOR });

            if (p.description.len > 0) {
                dvui.label(@src(), "{s}", .{p.description}, .{ .color_text = HELP_TEXT_COLOR });
            }
        }

        // Right: Delete button — only for user presets. Built-ins
        // ship in the binary and re-appear next launch even if the
        // disk file is removed; better to skip the button entirely.
        // Two-click arm: first click flips label to "Confirm delete
        // preset"; second click on the same row executes.
        if (from_user) {
            var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
            defer btns.deinit();
            const this_armed = std.mem.eql(u8, armed_id, p.id);
            const del_label: []const u8 = if (this_armed) "Confirm delete preset" else "Delete";
            if (style.button(@src(), del_label, .{}, .{ .style = .err, .id_extra = std.hash.Wyhash.hash(1, p.id) })) {
                actions.doDeleteUserPresetArmed(frame, p.id);
            }
        }
    }
}

/// Convert-strategy presets. Same two-tier layout as the mod-preset
/// panel: built-ins are read-only, user-authored entries (in
/// `<data_root>/convert-presets/`) can be edited / deleted out of band
/// (no in-app editor yet). The list documents what each strategy
/// does so users can see WHY their game converts the way it does.
fn renderSettingsConvertPresets(frame: *Frame) void {
    dvui.label(@src(), "Convert-strategy presets", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Presets bind a game engine to a Win->Linux conversion strategy (Ren'Py SDK overlay, " ++
            "RPGM nwjs install, etc). Built-in presets cover the common cases; drop additional " ++
            "`*.preset.zon` files into the user dir to extend or override.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });

    const convert_mod = @import("convert");
    var bundle = convert_mod.loadMergedPresets(frame.lib.alloc, frame.io, frame.info.convert_presets_dir) catch {
        dvui.label(@src(), "Failed to load convert preset bundle.", .{}, .{ .style = .err });
        return;
    };
    defer bundle.deinit();

    if (bundle.presets.len == 0) {
        dvui.label(@src(), "No presets loaded.", .{}, .{});
        return;
    }

    // Dir path readout — same format as the mod-presets panel.
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer bar.deinit();
        dvui.label(@src(), "User dir:", .{}, .{ .color_text = HELP_TEXT_COLOR });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.label(@src(), "{s}", .{frame.info.convert_presets_dir}, .{
            .font = .theme(.mono),
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    for (bundle.presets, bundle.from_user, 0..) |p, from_user, i| {
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .id_extra = std.hash.Wyhash.hash(0, p.id) ^ @as(u64, i),
        });
        defer row.deinit();

        // Header — name + source tag.
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hdr.deinit();
            dvui.label(@src(), "{s}", .{p.name}, .{ .style = .highlight });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
            const tag: []const u8 = if (from_user) "[user]" else "[built-in]";
            dvui.label(@src(), "{s}", .{tag}, .{
                .color_text = if (from_user)
                    .{ .r = 0xE9, .g = 0x4B, .b = 0x7A }
                else
                    HELP_TEXT_COLOR,
            });
        }

        // Sub-line — id + engine + spec variant + weight.
        var sub_buf: [256]u8 = undefined;
        const engine_txt: []const u8 = if (p.engine_hint) |e| @tagName(e) else "any";
        const spec_txt: []const u8 = switch (p.spec) {
            .none => "no-op",
            .renpy => "renpy-sdk-overlay",
            .rpgm => "nwjs-overlay",
        };
        const sub_txt = std.fmt.bufPrint(&sub_buf, "id: {s}  -  engine: {s}  -  strategy: {s}  -  weight: {d:.1}", .{
            p.id, engine_txt, spec_txt, p.weight,
        }) catch p.id;
        dvui.label(@src(), "{s}", .{sub_txt}, .{ .color_text = HELP_TEXT_COLOR });

        if (p.description.len > 0) {
            dvui.label(@src(), "{s}", .{p.description}, .{ .color_text = HELP_TEXT_COLOR });
        }
    }
}

/// About tab — diagnostics link + version blurb.
fn renderSettingsAbout(frame: *Frame) void {
    renderDiagnosticsLink(frame);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 16 } });
    settingsHelpText("f69 — phase 1 alpha. Editable settings land in phase 1.5 (config.toml).");
}

/// Vertical-gap separator between settings sections within a tab.
/// Kept as a one-call helper so every tab has the same rhythm.
///
/// Each call site must pass a unique `key` — dvui derives widget ids
/// from `@src()` + `id_extra`, and since the three child widgets
/// here share the helper's source location, every call to this fn
/// otherwise produces the same triple of ids → "duplicate widget id"
/// errors when the divider is used more than once per frame. The key
/// distinguishes one call from another.
fn settingsSectionDivider(key: u64) void {
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 16 } });
    _ = dvui.separator(@src(), .{ .id_extra = key, .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 12 } });
}

/// Live UI scale slider. Writes back to `state.ui_scale` so the
/// outer main loop picks the new value up on the next frame; the
/// persistence step debounces to disk via `persistUiScaleIfDirty`.
fn renderUiScaleSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "UI scale", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Bigger or smaller text, icons, paddings. Applies live; saved on release.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // dvui's slider takes a 0..1 fraction; map to [SCALE_MIN, SCALE_MAX].
    const SCALE_MIN: f32 = 0.75;
    const SCALE_MAX: f32 = 3.0;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    dvui.label(@src(), "{d:.2}×", .{state.ui_scale}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 70, .h = 24 },
    });

    var frac: f32 = (state.ui_scale - SCALE_MIN) / (SCALE_MAX - SCALE_MIN);
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;
    if (dvui.slider(@src(), .{ .fraction = &frac, .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 240, .h = 24 },
        .gravity_y = 0.5,
    })) {
        // Snap to 0.05 increments so the user lands on round numbers.
        const raw = SCALE_MIN + frac * (SCALE_MAX - SCALE_MIN);
        state.ui_scale = @round(raw / 0.05) * 0.05;
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    if (style.button(@src(), "Reset", .{}, .{ .gravity_y = 0.5 })) {
        state.ui_scale = 1.25;
    }
}

/// Auto-update-check preferences: one-shot startup trigger plus an
/// optional recurring interval (X minutes / hours / days). State is
/// the source of truth; `persistAutoCheckIfDirty` debounces writes
/// to disk so a slider drag isn't a write storm.
fn renderAutoCheckSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Update checks", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText(
        "Walks F95's latest-updates pages since the last check; mismatched games get queued for a sync.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    _ = dvui.checkbox(@src(), &state.auto_check.on_startup, "Check on startup", .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Recurring-interval row: [x] Check every [count] [unit-dropdown]
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = dvui.checkbox(@src(), &state.auto_check.interval_enabled, "Check every", .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

        // Integer count input — clamped to 1..999. We keep the value
        // in a fixed-size text buffer so dvui's textEntry can edit it,
        // then re-parse on focus loss / each frame.
        var count_buf: [4]u8 = [_]u8{0} ** 4;
        const printed = std.fmt.bufPrint(&count_buf, "{d}", .{state.auto_check.interval_count}) catch "";
        var buf: [4]u8 = [_]u8{0} ** 4;
        @memcpy(buf[0..printed.len], printed);
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &buf },
        }, .{
            .min_size_content = .{ .w = 60, .h = 24 },
            .gravity_y = 0.5,
        });
        te.deinit();
        const typed = std.mem.sliceTo(&buf, 0);
        if (std.fmt.parseInt(u32, typed, 10)) |n| {
            const clamped = std.math.clamp(n, 1, 999);
            if (clamped != state.auto_check.interval_count) {
                state.auto_check.interval_count = clamped;
            }
        } else |_| {}

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

        const unit_labels = &[_][]const u8{ "minutes", "hours", "days" };
        var picked: usize = @intFromEnum(state.auto_check.interval_unit);
        if (style.dropdown(@src(), unit_labels, .{ .choice = &picked }, .{}, .{
            .min_size_content = .{ .w = 110, .h = 24 },
            .gravity_y = 0.5,
        })) {
            state.auto_check.interval_unit = @enumFromInt(picked);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    // Surface the last-check timestamp so the user can see why /
    // whether the recurring trigger has fired recently.
    if (state.last_update_check_ts > 0) {
        var ts_buf: [32]u8 = undefined;
        const ts = formatUtcDateTime(&ts_buf, state.last_update_check_ts) catch "—";
        dvui.label(@src(), "Last check: {s}", .{ts}, .{
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    } else {
        dvui.label(@src(), "Last check: never", .{}, .{
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
        });
    }
}

fn renderDiagnosticsLink(frame: *Frame) void {
    dvui.label(@src(), "Diagnostics", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    dvui.label(@src(), "Engine probes, runtime info, and sandbox state.", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    if (iconButton(@src(), "Open diagnostics", entypo.help, .{ .style = .highlight })) {
        frame.state.screen = .diagnostics;
    }
}

fn renderBrowserSection(frame: *Frame) void {
    const state = frame.state;

    dvui.label(@src(), "Browser", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    settingsHelpText("Used to open F95 thread links from the detail screen.");
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Detected list as a row of buttons. Clicking copies the chosen
    // exe path into the editable field below.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        for (frame.info.browsers, 0..) |b, i| {
            const cur = state.browserPathSlice();
            const is_active = std.mem.eql(u8, cur, b.path);
            const opts: dvui.Options = if (is_active)
                .{ .id_extra = i, .style = .highlight }
            else
                .{ .id_extra = i };
            if (style.button(@src(), b.display, .{}, opts)) {
                state.setBrowserPath(b.path);
                state.setBrowserMsg("");
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Editable path — the source of truth. Type a custom path here
    // (handy for portable installs or AppImages).
    dvui.label(@src(), "Path or command:", .{}, .{});
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.browser_path_buf },
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 480, .h = 28 },
        });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Save", .{}, .{ .style = .highlight })) {
            actions.saveBrowserPath(frame, state.browserPathSlice());
        }
    }
    if (!state.browser_msg.isEmpty()) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        dvui.label(@src(), "{s}", .{state.browserMsg()}, .{ .style = .highlight });
    }
}

fn renderF95Account(frame: *Frame) void {
    const state = frame.state;

    dvui.label(@src(), "F95Zone account", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Status line.
    const status_text = switch (state.login_status) {
        .unknown => "(checking)",
        .logged_out => "not logged in",
        .logged_in => "logged in",
        .logging_in => "logging in…",
        .err => "error",
    };
    const status_opts: dvui.Options = switch (state.login_status) {
        .logged_in => .{ .style = .highlight },
        .err => .{ .style = .err },
        else => .{},
    };
    dvui.label(@src(), "status: {s}", .{status_text}, status_opts);
    if (!state.login_msg.isEmpty()) {
        dvui.label(@src(), "{s}", .{state.loginMsg()}, .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Logged-in: just a logout button. (Pull bookmarks lives on the
    // library top bar — it's a one-click action you do from the main
    // view, not buried under Settings.)
    if (state.login_status == .logged_in) {
        if (iconButton(@src(), "Logout", entypo.cross, .{ .style = .err })) {
            actions.doLogout(frame);
        }
        return;
    }

    // Logged-out / error: form.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "username:", .{}, .{ .min_size_content = .{ .w = 90, .h = 24 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.f95_user_buf } }, .{
            .min_size_content = .{ .w = 240, .h = 24 },
        });
        te.deinit();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "password:", .{}, .{ .min_size_content = .{ .w = 90, .h = 24 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.f95_pass_buf },
            .password_char = "•",
        }, .{
            .min_size_content = .{ .w = 240, .h = 24 },
        });
        te.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    if (style.button(@src(), "Login", .{}, .{ .style = .highlight })) {
        actions.doLogin(frame, state.f95UserSlice(), state.f95PassSlice());
    }
}

fn renderRpdlAccount(frame: *Frame) void {
    const state = frame.state;

    dvui.label(@src(), "RPDL account (dl.rpdl.net)", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    const status_text = switch (state.rpdl_status) {
        .unknown => "(unknown)",
        .logged_out => "not logged in",
        .logged_in => "logged in",
        .logging_in => "logging in…",
        .err => "error",
    };
    const status_opts: dvui.Options = switch (state.rpdl_status) {
        .logged_in => .{ .style = .highlight },
        .err => .{ .style = .err },
        else => .{},
    };
    dvui.label(@src(), "status: {s}", .{status_text}, status_opts);
    if (!state.rpdl_msg.isEmpty()) {
        dvui.label(@src(), "{s}", .{state.rpdlMsg()}, .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    if (state.rpdl_status == .logged_in) {
        if (iconButton(@src(), "Logout", entypo.cross, .{ .style = .err })) {
            actions.doRpdlLogout(frame);
        }
        return;
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "username:", .{}, .{ .min_size_content = .{ .w = 90, .h = 24 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.rpdl_user_buf } }, .{
            .min_size_content = .{ .w = 240, .h = 24 },
        });
        te.deinit();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "password:", .{}, .{ .min_size_content = .{ .w = 90, .h = 24 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.rpdl_pass_buf },
            .password_char = "•",
        }, .{
            .min_size_content = .{ .w = 240, .h = 24 },
        });
        te.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    if (style.button(@src(), "Login", .{}, .{ .style = .highlight })) {
        actions.doRpdlLogin(frame, state.rpdlUserSlice(), state.rpdlPassSlice());
    }
}

const LibraryStats = struct {
    synced: u32 = 0,
    unsynced: u32 = 0,
    rated_count: u32 = 0,
    rating_sum: f32 = 0,
    engine_renpy: u32 = 0,
    engine_rpgm_mv: u32 = 0,
    engine_rpgm_mz: u32 = 0,
    engine_rpgm_vx: u32 = 0,
    engine_unity: u32 = 0,
    engine_unreal: u32 = 0,
    engine_html: u32 = 0,
    engine_flash: u32 = 0,
    engine_java: u32 = 0,
    engine_wolf_rpg: u32 = 0,
    engine_qsp: u32 = 0,
    engine_tyranobuilder: u32 = 0,
    engine_twine: u32 = 0,
    engine_other: u32 = 0,
    engine_unknown: u32 = 0,
    distinct_tags: u32 = 0,
};

/// Single linear pass — counts engine breakdown, mean rating, and the
/// number of distinct tags via a small (256-bucket) probe table.
/// "Distinct" is approximate; collisions undercount slightly.
fn libraryStats(games: []const library.Game) LibraryStats {
    var s: LibraryStats = .{};
    var tag_seen: [256]u64 = [_]u64{0} ** 256;
    var tag_count: u32 = 0;
    for (games) |*g| {
        if (std.mem.eql(u8, g.name, "(unsynced)")) {
            s.unsynced += 1;
        } else {
            s.synced += 1;
        }
        if (g.rating) |r| {
            s.rated_count += 1;
            s.rating_sum += r;
        }
        switch (g.engine) {
            .renpy => s.engine_renpy += 1,
            .rpgm_mv => s.engine_rpgm_mv += 1,
            .rpgm_mz => s.engine_rpgm_mz += 1,
            .rpgm_vx => s.engine_rpgm_vx += 1,
            .unity => s.engine_unity += 1,
            .unreal => s.engine_unreal += 1,
            .html => s.engine_html += 1,
            .flash => s.engine_flash += 1,
            .java => s.engine_java += 1,
            .wolf_rpg => s.engine_wolf_rpg += 1,
            .qsp => s.engine_qsp += 1,
            .tyranobuilder => s.engine_tyranobuilder += 1,
            .twine => s.engine_twine += 1,
            .other => s.engine_other += 1,
            .unknown => s.engine_unknown += 1,
        }
        for (g.tags) |t| {
            const h = std.hash.Wyhash.hash(0, t);
            const slot = h % tag_seen.len;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const idx = (slot + i) % tag_seen.len;
                if (tag_seen[idx] == 0) {
                    tag_seen[idx] = h;
                    tag_count += 1;
                    break;
                }
                if (tag_seen[idx] == h) break;
            }
        }
    }
    s.distinct_tags = tag_count;
    return s;
}

fn settingsRow(id_counter: *u32, label: []const u8, value: []const u8) void {
    const id = id_counter.*;
    id_counter.* += 1;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .id_extra = id,
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .min_size_content = .{ .w = 160, .h = 20 },
        .gravity_y = 0.5,
    });
    dvui.label(@src(), "{s}", .{value}, .{ .gravity_y = 0.5 });
}

// ============================================================
//  import screen — paste F95 thread URLs / IDs, bulk-create rows
// ============================================================

pub fn importScreen(frame: *Frame) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (style.button(@src(), "← Back", .{}, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Import F95 threads", .{}, .{ .gravity_y = 0.5, .style = .highlight });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Import", .{}, .{ .style = .highlight })) {
            const result = doImport(frame, state.importBufSlice());
            var msg_buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "imported {d}, skipped {d}", .{ result.ok, result.skipped }) catch "imported";
            state.setImportMsg(m);
            if (result.ok > 0) {
                // Manual paste import: same rule as the bookmark
                // worker — never auto-sync. Just reload so the grid
                // shows the new placeholders; the user starts syncs
                // explicitly via Sync All / Updates / per-game Sync.
                state.reload_requested = true;
                @memset(&state.import_buf, 0);
                state.screen = .library;
            }
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    dvui.label(@src(), "Paste F95Zone thread URLs or numeric IDs (one per line):", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.import_buf },
        .multiline = true,
    }, .{
        .expand = .both,
        .min_size_content = .{ .w = 600, .h = 300 },
    });
    te.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    if (!state.import_msg.isEmpty()) {
        dvui.label(@src(), "{s}", .{state.importMsg()}, .{ .style = .highlight });
    } else {
        dvui.label(@src(), "Imported games show up as \"(unsynced)\". Click Sync on each to populate.", .{}, .{});
    }

    return true;
}

const ImportResult = struct { ok: u32 = 0, skipped: u32 = 0 };

fn doImport(frame: *Frame, blob: []const u8) ImportResult {
    var result: ImportResult = .{};
    var iter = std.mem.tokenizeAny(u8, blob, "\n\r");
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const tid_str: ?[]const u8 = blk: {
            if (f95.extractThreadId(trimmed)) |s| break :blk s;
            // Fallback: maybe the user pasted a bare numeric id.
            _ = std.fmt.parseInt(u64, trimmed, 10) catch break :blk null;
            break :blk trimmed;
        };
        const ts = tid_str orelse {
            result.skipped += 1;
            continue;
        };
        const tid = std.fmt.parseInt(u64, ts, 10) catch {
            result.skipped += 1;
            continue;
        };
        const g = library.Game{ .f95_thread_id = tid, .name = "(unsynced)" };
        const inserted = frame.lib.insertIfMissing(&g) catch {
            result.skipped += 1;
            continue;
        };
        if (inserted) result.ok += 1 else result.skipped += 1;
    }
    return result;
}

// ============================================================
//  cover renderers — used by both detail screen and grid card
// ============================================================

/// Carousel widget. Slide 0 shows the cover; slides 1..N show the
/// screenshots scraped from the OP. Manual nav only — the user
/// drives prev/next, no auto-rotation. F95 banners are usually wide,
/// so the slot is sized 16:9 (~480×270) and `dvui.image` shrinks-to-
/// ratio inside.
/// Stable height for the carousel slot. The image inside letterboxes
/// via `shrink = .ratio` — wide banners use the full width and leave
/// vertical whitespace; tall portraits use the full height and leave
/// horizontal whitespace. The slot itself never resizes when the user
/// flips between slides with different aspect ratios.
pub const CAROUSEL_H: f32 = 360;
/// Thumbnail-strip slot dimensions. ~16:9 thumbs read clean for both
/// banner-aspect covers and screenshot-aspect screenshots; the slot
/// itself locks to RIBBON_H so the ribbon row stays a single line.
pub const RIBBON_THUMB_W: f32 = 96;
pub const RIBBON_THUMB_H: f32 = 54;
pub const RIBBON_H: f32 = RIBBON_THUMB_H + 12;

/// Detail-page action row. Launch + install dropdown sit on the far
/// left so the primary verb is always in the same physical spot;
/// everything else (sync / open thread / open saves / backup /
/// download / convert) clusters on the right with a small spacer
/// between the two groups. Convert carries a help icon that flips a
/// tooltip block underneath the row.
fn renderActionRow(frame: *Frame, game: *library.Game) void {
    const state = frame.state;

    // One wrapping cluster, anchored to the left edge of the row.
    // At any width the buttons read as one toolbar. Wide windows put
    // everything on one line; narrow windows wrap onto subsequent
    // left-aligned rows.
    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    defer row.deinit();

    // --- Launch / Stop (primary, hot-pink fill) ---
    const launch_fill: dvui.Color = .{ .r = 0xFF, .g = 0x33, .b = 0x77 };
    const launch_hover: dvui.Color = .{ .r = 0xFF, .g = 0x66, .b = 0xA0 };
    const launch_press: dvui.Color = .{ .r = 0xCC, .g = 0x29, .b = 0x5E };
    // Muted variants used when there's no install — same shape so
    // layout doesn't shift, but visually "off" so the user reads it
    // as unavailable. Click is also a no-op below.
    const launch_fill_off: dvui.Color = .{ .r = 0x3A, .g = 0x22, .b = 0x2A };
    const launch_text_off: dvui.Color = .{ .r = 0x80, .g = 0x60, .b = 0x70 };

    if (actions.isGameRunning(frame, game.f95_thread_id)) {
        if (iconButton(@src(), "Stop", entypo.cross, .{ .style = .err })) {
            actions.doStopGame(frame, game);
        }
    } else {
        const enabled = actions.installDotState(frame, game) != .none;
        const click = iconButton(@src(), "Launch", entypo.forward, if (enabled) .{
            .color_fill = launch_fill,
            .color_fill_hover = launch_hover,
            .color_fill_press = launch_press,
            .color_text = dvui.Color.white,
            .color_border = launch_fill,
        } else .{
            .color_fill = launch_fill_off,
            .color_fill_hover = launch_fill_off,
            .color_fill_press = launch_fill_off,
            .color_text = launch_text_off,
            .color_border = launch_fill_off,
        });
        if (click and enabled) {
            actions.doLaunchGame(frame, game);
        } else if (click and !enabled) {
            frame.state.notifyInfo("Nothing to launch yet — download or import an install first.");
        }
    }

    // --- Update to vX.Y — primary, shown only when outdated and
    // nothing else is in flight. Sits between Launch and the install
    // picker so it reads as a second primary action without hiding
    // Launch (the user might want to play the old version while a
    // newer one exists). Click branches: auto-fetchable recipe →
    // Download; manual-only → open the manual-install panel
    // pre-filled with the new version.
    if (!actions.isGameRunning(frame, game.f95_thread_id) and
        !actions.hasActiveDownloadForGame(frame, game.f95_thread_id) and
        !actions.isInstallingForGame(frame, game.f95_thread_id) and
        actions.installDotState(frame, game) == .outdated)
    {
        const newer = game.latest_version orelse "latest";
        var btn_buf: [48]u8 = undefined;
        const btn_label = std.fmt.bufPrint(&btn_buf, "Update to {s}", .{newer}) catch "Update";
        if (iconButton(@src(), btn_label, entypo.cloud, .{
            .color_fill = launch_fill,
            .color_fill_hover = launch_hover,
            .color_fill_press = launch_press,
            .color_text = dvui.Color.white,
            .color_border = launch_fill,
        })) {
            if (actions.hasAutoFetchableSource(frame, game.f95_thread_id)) {
                actions.doDownloadGame(frame, game);
            } else {
                actions.openManualInstallForUpdate(frame.state, newer);
            }
        }
    }

    // --- Install picker (sits immediately right of Launch) ---
    const installs = frame.lib.listInstalls(game.f95_thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));
    if (installs.len == 0) {
        const versions = [_][]const u8{"(no installs)"};
        var picked: usize = 0;
        _ = style.dropdown(@src(), &versions, .{ .choice = &picked }, .{}, .{
            .min_size_content = .{ .w = 160, .h = 28 },
            .gravity_y = 0.5,
        });
    } else {
        // Label format: `[src] <version> — <name>`. Launch follows
        // whatever the user picks here, so no leading marker is
        // needed — selection IS the target.
        var labels_buf: [32][]const u8 = undefined;
        var join_buf: [32 * 144]u8 = undefined;
        var join_used: usize = 0;
        const n = @min(installs.len, labels_buf.len);
        for (installs[0..n], 0..) |inst, i| {
            const tag = sourceTag(inst.source);
            const rest = join_buf[join_used..];
            const have_name = if (inst.name) |nm| nm.len > 0 else false;
            const joined_or_err = if (have_name)
                std.fmt.bufPrint(rest, "{s}{s} \u{2014} {s}", .{ tag, inst.version, inst.name.? })
            else
                std.fmt.bufPrint(rest, "{s}{s}", .{ tag, inst.version });
            if (joined_or_err) |joined| {
                labels_buf[i] = joined;
                join_used += joined.len;
            } else |_| {
                labels_buf[i] = inst.version;
            }
        }
        // Resolve initial pick from saved id, falling back to 0
        // (newest install) when the saved id no longer exists.
        var picked: usize = 0;
        if (frame.state.detail_picker_install_id) |sel| {
            for (installs[0..n], 0..) |inst, i| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                    picked = i;
                    break;
                }
            }
        }
        _ = style.dropdown(@src(), labels_buf[0..n], .{ .choice = &picked }, .{}, .{
            .min_size_content = .{ .w = 220, .h = 28 },
            .gravity_y = 0.5,
        });
        // Persist whichever install the user landed on so the
        // selection sticks across frames and the ⋯ menu has a
        // stable target.
        if (picked < installs.len) {
            frame.state.detail_picker_install_id = installs[picked].id;
        }

        // ⋯ menu — rename / delete / show in files. Chevron-style
        // submenu anchored against a small dots icon, same shape as
        // the download-source split button below.
        var manage_bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xCAFE });
        defer manage_bar.deinit();
        if (dvui.menuItemIcon(@src(), "install-manage", entypo.dots_three_horizontal, .{ .submenu = true }, .{
            .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
            .min_size_content = .{ .w = 18, .h = 18 },
            .id_extra = game.f95_thread_id,
        })) |anchor| {
            var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "Rename\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
                const inst = &installs[picked];
                frame.state.manage_action = .rename;
                frame.state.manage_install_id = inst.id;
                // Pre-fill the rename buffer with the current name
                // so a no-op confirm just keeps the existing label.
                @memset(&frame.state.manage_rename_buf, 0);
                if (inst.name) |nm| {
                    const len = @min(nm.len, frame.state.manage_rename_buf.len - 1);
                    @memcpy(frame.state.manage_rename_buf[0..len], nm[0..len]);
                }
                manage_bar.close();
            }
            if (dvui.menuItemLabel(@src(), "Delete install", .{}, .{ .expand = .horizontal }) != null) {
                frame.state.manage_action = .delete;
                frame.state.manage_install_id = installs[picked].id;
                manage_bar.close();
            }
            // "Show in files" lived here too — dropped as a duplicate
            // of the toolbar Folder button, which now honours the
            // install picker selection.
        }
    }

    // (Sync moved to the facts grid's "Last synced" row — the
    // `Sync now` mini-button there is the per-game sync action.)
    // (Thread moved to the F95 #<id> ribbon button under the title —
    // the toolbar duplicate was dropped.)

    if (iconButton(@src(), "Folder", entypo.folder, .{})) {
        actions.doOpenGameFolder(frame, game);
    }
    if (iconButton(@src(), "Saves", entypo.home, .{})) {
        actions.doOpenSaves(frame, game);
    }
    if (iconButton(@src(), "Backup", entypo.archive, .{})) {
        actions.doBackupSaves(frame, game);
    }
    // Download — routes through Tier 2 (RPDL torrent + aria2 seed)
    // by default, with a chevron menu offering Tier 1 (donor DDL via
    // F95's /sam/dddl.php) when the user has an F95 cookie. The
    // chevron isn't shown when no F95 session is logged in — there's
    // no second choice to surface.
    //
    // Button states:
    //   - "View download" — single click jumps to the Downloads
    //     screen when this game already has a job in flight.
    //   - "Searching…" / "Requesting…" — greyed while either worker
    //     is handing off.
    //   - "Download" — normal idle.
    renderDetailDownloadButton(frame, game);

    // Manual Install — shown when there's at least one downloaded
    // archive whose version isn't already installed. Single button
    // when one candidate; split button with a chevron dropdown when
    // multiple downloaded versions are available so the user can pick
    // which build to extract.
    renderDetailInstallButton(frame, game);

    // (Standalone "Install from file…" removed — it lives in the
    // Download chevron submenu now so the action row has one fewer
    // top-level slot. Toggling the manual-install panel happens via
    // `state.manual_install_open` either way; the inline panel below
    // still renders when that flag is true.)

    // Convert + Help (toggles inline explanation). Help is icon-only
    // so it doesn't compete with primary actions for space in the
    // toolbar row.
    if (iconButton(@src(), "Convert", entypo.cycle, .{})) {
        actions.doConvertGame(frame, game);
    }
    if (iconOnly(@src(), "Help", entypo.help, .{
        .style = if (state.convert_help_open) .highlight else .control,
        .min_size_content = .{ .w = style.button_h, .h = style.button_h },
    })) {
        state.convert_help_open = !state.convert_help_open;
    }

    // Mods — navigation entry to the full-page Mods screen for this
    // game. Sits at the end of the action row so it doesn't compete
    // for attention with Launch / Download / Install primaries.
    if (iconButton(@src(), "Mods", entypo.tools, .{})) {
        state.screen = .mods_for_game;
    }

    // Compat — scan + auto-apply any matched recipes for the
    // currently-selected install. One-shot button: clicking it
    // runs `scanCompatForInstall` against the install root, then
    // `applyCompatFix` for every `.unfixed` issue, surfacing the
    // outcome via the launch message line.
    if (iconButton(@src(), "Fix Compat", entypo.tools, .{})) {
        doCompatFixForActiveInstall(frame, game);
    }
}

/// Resolve the active install (same picker logic as doLaunchGame)
/// and run a scan + auto-apply for every blocker/warn issue. The
/// result is surfaced via `state.setLaunchMsg`.
fn doCompatFixForActiveInstall(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const installs = frame.lib.listInstalls(game.f95_thread_id) catch {
        state.setLaunchMsg("Compat fix: can't list installs.");
        return;
    };
    defer frame.lib.freeInstalls(installs);
    if (installs.len == 0) {
        state.setLaunchMsg("Compat fix: no installs for this game.");
        return;
    }
    const picked: *const library.Install = blk: {
        if (state.detail_picker_install_id) |sel| {
            for (installs) |*inst| if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
        }
        break :blk &installs[0];
    };

    const issues = actions.scanCompatForInstall(frame, &picked.id, picked.install_path) catch |e| {
        var buf: [200]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Compat scan failed: {s}", .{@errorName(e)}) catch "Compat scan failed";
        state.setLaunchMsg(msg);
        return;
    };
    defer actions.freeCompatIssues(frame, issues);

    var applied: usize = 0;
    var failed: usize = 0;
    var last_err_buf: [128]u8 = undefined;
    var last_err: []const u8 = "";
    for (issues) |is| {
        if (is.status != .unfixed) continue;
        // Recipe id is owned by the issues alloc; dupe it briefly so
        // the action call signature (which expects a stable slice) is
        // happy even though scan's slice is stable for the duration.
        actions.applyCompatFix(frame, &picked.id, picked.install_path, is.recipe_id) catch |e| {
            failed += 1;
            last_err = std.fmt.bufPrint(&last_err_buf, "{s}: {s}", .{ is.recipe_id, @errorName(e) }) catch "apply failed";
            continue;
        };
        applied += 1;
    }
    _ = alloc;

    var msg_buf: [256]u8 = undefined;
    const msg = if (failed > 0)
        std.fmt.bufPrint(&msg_buf, "Compat: {d} fix(es) applied, {d} failed ({s}).", .{ applied, failed, last_err }) catch "Compat: partial."
    else if (applied > 0)
        std.fmt.bufPrint(&msg_buf, "Compat: {d} fix(es) applied. Re-launch the game.", .{applied}) catch "Compat applied."
    else
        std.fmt.bufPrint(&msg_buf, "Compat: nothing to fix on this install.", .{}) catch "Compat: nothing to fix.";
    state.setLaunchMsg(msg);
}

/// Detail-page Download button. Single-action when the user is
/// only logged into one provider; split-button (primary + chevron
/// menu) when both F95 (donor DDL) AND RPDL credentials are
/// available so the user can pick per-game.
fn renderDetailDownloadButton(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const rpdl_busy = state.pending_rpdl_download != null;
    const donor_busy = state.pending_donor_download != null;
    const job_active = actions.hasActiveDownloadForGame(frame, game.f95_thread_id);

    // We used to early-return with a single "View download" button
    // when a job for this game was already in flight. That locked the
    // user out of trying a different source — e.g. when an RPDL
    // search picked a 0-seed torrent, there was no way to fall back
    // to donor DDL without canceling the stalled job. Now the primary
    // button + chevron stay visible, and the chevron grows a
    // "View current download" entry when something is in flight.
    _ = job_active;

    const have_rpdl = state.rpdl_token != null and (state.rpdl_token.?.len > 0);
    const have_f95 = state.login_status == .logged_in;
    const busy = rpdl_busy or donor_busy;

    // Pick the primary action. Order of preference:
    //   1. RPDL — auto-seeds, better citizenship; default when
    //      available.
    //   2. Donor DDL — fast HTTP, no seeding overhead.
    //   3. None — show a disabled button with a hint.
    const primary_label: []const u8 = blk: {
        if (rpdl_busy) break :blk "Searching…";
        if (donor_busy) break :blk "Requesting…";
        break :blk "Download";
    };
    const primary_opts: dvui.Options = if (busy)
        .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } }
    else
        .{};

    // Single shape regardless of credentials: primary button + chevron
    // submenu. Primary action varies by what's available; chevron
    // always carries "Install from file…" so users without any
    // F95/RPDL credentials still have an obvious add-a-build path.
    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xACCE });
    defer bar.deinit();

    if (have_rpdl) {
        const clicked = iconButton(@src(), primary_label, entypo.download, primary_opts);
        if (clicked) {
            std.log.info(
                "download primary (RPDL): clicked tid={d} busy={any} (rpdl_busy={any} donor_busy={any}) job_active={any}",
                .{ game.f95_thread_id, busy, rpdl_busy, donor_busy, actions.hasActiveDownloadForGame(frame, game.f95_thread_id) },
            );
            if (!busy) {
                std.log.info("download primary (RPDL): dispatching startRpdlDownload tid={d}", .{game.f95_thread_id});
                actions.startRpdlDownload(frame, game);
            } else {
                std.log.warn("download primary (RPDL): click gated — busy", .{});
            }
        }
    } else if (have_f95) {
        const clicked = iconButton(@src(), primary_label, entypo.download, primary_opts);
        if (clicked) {
            std.log.info(
                "download primary (donor): clicked tid={d} busy={any} (rpdl_busy={any} donor_busy={any}) job_active={any}",
                .{ game.f95_thread_id, busy, rpdl_busy, donor_busy, actions.hasActiveDownloadForGame(frame, game.f95_thread_id) },
            );
            if (!busy) {
                std.log.info("download primary (donor): dispatching startDonorDownload tid={d}", .{game.f95_thread_id});
                actions.startDonorDownload(frame, game);
            } else {
                std.log.warn("download primary (donor): click gated — busy", .{});
            }
        }
    } else {
        const dim_opts: dvui.Options = .{
            .style = .control,
            .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
        };
        if (iconButton(@src(), "Download (sign in first)", entypo.download, dim_opts)) {
            std.log.info("download primary: clicked while signed out — jumping to Accounts", .{});
            state.screen = .settings;
            state.settings_tab = .accounts;
        }
    }

    if (dvui.menuItemIcon(@src(), "download-source", entypo.chevron_down, .{ .submenu = true }, .{
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .min_size_content = .{ .w = 16, .h = 16 },
        .id_extra = game.f95_thread_id,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        // When a job is already in flight (could be stalled — 0-seed
        // torrent, slow donor mirror, etc.), surface a shortcut to
        // the Downloads tab at the top of the menu so the user still
        // has both: jump to status, AND start a fresh attempt below.
        if (actions.hasActiveDownloadForGame(frame, game.f95_thread_id)) {
            if (dvui.menuItemLabel(@src(), "View current download", .{}, .{ .expand = .horizontal }) != null) {
                state.screen = .downloads;
                bar.close();
            }
        }

        if (have_rpdl) {
            if (dvui.menuItemLabel(@src(), "Download via RPDL (torrent + seed)", .{}, .{ .expand = .horizontal }) != null) {
                std.log.info("download chevron (RPDL): clicked tid={d} busy={any} rpdl_busy={any} donor_busy={any}", .{ game.f95_thread_id, busy, state.pending_rpdl_download != null, state.pending_donor_download != null });
                bar.close();
                if (!busy) {
                    std.log.info("download chevron (RPDL): dispatching startRpdlDownload tid={d}", .{game.f95_thread_id});
                    actions.startRpdlDownload(frame, game);
                } else {
                    std.log.warn("download chevron (RPDL): click gated — busy", .{});
                }
            }
        }
        if (have_f95) {
            if (dvui.menuItemLabel(@src(), "Download via donor DDL (HTTP)", .{}, .{ .expand = .horizontal }) != null) {
                std.log.info("download chevron (donor): clicked tid={d} busy={any} rpdl_busy={any} donor_busy={any}", .{ game.f95_thread_id, busy, state.pending_rpdl_download != null, state.pending_donor_download != null });
                bar.close();
                if (!busy) {
                    std.log.info("download chevron (donor): dispatching startDonorDownload tid={d}", .{game.f95_thread_id});
                    actions.startDonorDownload(frame, game);
                } else {
                    std.log.warn("download chevron (donor): click gated — busy", .{});
                }
            }
        }
        // Always present — local-archive path doesn't need any
        // credentials and works even on games with no recipe yet.
        if (dvui.menuItemLabel(@src(), "Install from file\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
            state.manual_install_open = true;
            bar.close();
        }
    }
}

/// Detail-page Install button — single primary action when exactly
/// one downloaded archive is ready, split button with a chevron menu
/// listing all downloaded versions when more than one is on hand.
/// Skips entirely when nothing's installable (no terminal-with-archive
/// job for this thread, OR every downloaded version already has an
/// `installs` row).
fn renderDetailInstallButton(frame: *Frame, game: *const library.Game) void {
    var buf: [16]actions.DownloadedEntry = undefined;
    const entries = actions.listDownloadedNotInstalled(frame, game.f95_thread_id, &buf);
    if (entries.len == 0) return;

    // One candidate → single button. Two+ → primary triggers the
    // first (most-recent-id) and the chevron exposes the full list.
    if (entries.len == 1) {
        if (iconButton(@src(), "Install", entypo.tools, .{ .style = .highlight })) {
            actions.startInstallFromDownloadJob(
                frame,
                game.f95_thread_id,
                entries[0].job_id,
                entries[0].expected_sha256,
            );
        }
        return;
    }

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xB1 });
    defer bar.deinit();

    if (iconButton(@src(), "Install", entypo.tools, .{ .style = .highlight })) {
        // Primary click installs the highest-id (most recent) entry —
        // arbitrary but predictable. Power users use the chevron.
        var best = entries[0];
        for (entries[1..]) |e| if (e.job_id > best.job_id) {
            best = e;
        };
        actions.startInstallFromDownloadJob(
            frame,
            game.f95_thread_id,
            best.job_id,
            best.expected_sha256,
        );
    }

    if (dvui.menuItemIcon(@src(), "install-version", entypo.chevron_down, .{ .submenu = true }, .{
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .min_size_content = .{ .w = 16, .h = 16 },
        .id_extra = game.f95_thread_id ^ 0xB2,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        for (entries, 0..) |e, i| {
            var lbl_buf: [96]u8 = undefined;
            const label: []const u8 = if (e.version.len > 0)
                std.fmt.bufPrint(&lbl_buf, "Install version {s}", .{e.version}) catch "Install (unknown version)"
            else
                "Install (unknown version)";
            if (dvui.menuItemLabel(@src(), label, .{}, .{
                .expand = .horizontal,
                .id_extra = @intCast(i),
            }) != null) {
                actions.startInstallFromDownloadJob(
                    frame,
                    game.f95_thread_id,
                    e.job_id,
                    e.expected_sha256,
                );
                bar.close();
            }
        }
    }
}

/// Single inline status line for the detail page — replaces the
/// previous boxed "Downloading…" + "Installing…" + Notifications
/// strips. Picks one signal in priority order:
///
///   1. Download in flight (this game) → progress + percent.
///   2. Install in flight (this game) → "Installing… extracting".
///   3. Any of the three notification slots is non-empty → most
///      recent message with a ✕ dismiss.
///
/// Returns silently when there's nothing to show. Style: a thin
/// pill-shaped strip, no box border — when nothing's happening the
/// detail page just doesn't have this row, which is the cleanest
/// "everything is fine" signal we can give.
fn renderDetailStatusLine(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    // 0. RPDL / donor handoff in flight — no aria2 job exists yet
    // so the leeching probe returns null, but the user still needs a
    // visible cue that work is happening between the click and the
    // aria2 enqueue.
    if (state.pending_rpdl_download != null) {
        renderStatusStrip(frame, .{
            .id = @intCast(game.f95_thread_id ^ 0xA0),
            .text = "Searching RPDL for a matching torrent…",
            .accent = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
            .progress = null,
            .view_link = false,
        });
        return;
    }
    if (state.pending_donor_download != null) {
        renderStatusStrip(frame, .{
            .id = @intCast(game.f95_thread_id ^ 0xA1),
            .text = "Requesting signed URL from F95 donor DDL…",
            .accent = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
            .progress = null,
            .view_link = false,
        });
        return;
    }

    // 1. Download progress.
    if (actions.findLeechingJobForGame(frame, game.f95_thread_id)) |job| {
        renderStatusStrip(frame, .{
            .id = @intCast(job.id),
            .text = downloadStatusText(job),
            .accent = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
            .progress = downloadProgressPct(job),
            .view_link = true,
        });
        return;
    }

    // 2. Install in flight.
    if (actions.isInstallingForGame(frame, game.f95_thread_id)) {
        const pct_opt = actions.extractProgressForGame(frame, game.f95_thread_id);
        var msg_buf: [96]u8 = undefined;
        const msg: []const u8 = if (pct_opt) |p|
            (std.fmt.bufPrint(&msg_buf, "Installing — extracting archive ({d}%).", .{p}) catch "Installing — extracting archive.")
        else
            "Installing — extracting archive in the background.";
        renderStatusStrip(frame, .{
            .id = @intCast(game.f95_thread_id),
            .text = msg,
            .accent = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
            .progress = if (pct_opt) |p| @as(u32, p) else null,
            .view_link = false,
        });
        return;
    }

    // (priority 3 — per-game notification fallback — removed. Action
    // confirmations, error reports etc. now flow through the global
    // toast overlay in `renderToasts` so they don't fight one slot
    // and can be dismissed individually.)

    // 4. Outdated badge — fall-through state when nothing's in flight
    // and there's no fresher notification to show. Tells the user
    // *why* the Update button is up + which path the click will take.
    // 5. Auto-updates-on hint — idle state when installed + current
    // and the user has opted into auto-updates for this game. Lets
    // them spot at a glance that "sync will fetch updates for me."
    // Both rendered as plain text (no boxed border) — these are idle
    // hints, not active operations; the bordered strip is reserved
    // for in-flight progress.
    const dot = actions.installDotState(frame, game);
    const auto_on = blk: {
        if (dot == .none) break :blk false; // no install → no auto-update either
        break :blk actions.shouldAutoUpdate(state, game);
    };
    if (dot == .outdated) {
        const newer = game.latest_version orelse "latest";
        const has_auto = actions.hasAutoFetchableSource(frame, game.f95_thread_id);
        var msg_buf: [240]u8 = undefined;
        // Four combos (auto-fetch path × auto-update-on flag).
        // Format strings have to be comptime, so just unroll —
        // shorter than building the suffix in two passes.
        const msg = blk: {
            if (has_auto and auto_on) {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — click Update to fetch. \u{00B7} auto-updates on", .{newer}) catch "Update available.";
            } else if (has_auto) {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — click Update to fetch.", .{newer}) catch "Update available.";
            } else if (auto_on) {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — pick the new archive via Update. \u{00B7} auto-updates on", .{newer}) catch "Update available.";
            } else {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — pick the new archive via Update.", .{newer}) catch "Update available.";
            }
        };
        renderIdleHint(game.f95_thread_id ^ 0xB1, msg);
    } else if (auto_on) {
        // Installed + current + auto-update enabled — small reassurance.
        renderIdleHint(game.f95_thread_id ^ 0xB2, "auto-updates on");
    }
}

/// One-line muted-pink inline label used for idle hints under the
/// action row (outdated badge + "auto-updates on"). Mirrors the
/// notification path's shape but lives in its own helper so we
/// don't duplicate the box scaffolding at each call site.
fn renderIdleHint(id: u64, text: []const u8) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intCast(id),
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
    });
    defer row.deinit();
    dvui.label(@src(), "{s}", .{text}, .{
        .gravity_y = 0.5,
        .color_text = HELP_TEXT_COLOR,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 20 },
    });
}

const StatusStripArgs = struct {
    id: u32,
    text: []const u8,
    accent: dvui.Color,
    /// 0..100; null = indeterminate (no bar rendered).
    progress: ?u32,
    /// When true, append a "View" link that jumps to the Downloads
    /// screen — used by the active-download case.
    view_link: bool,
};

fn renderStatusStrip(frame: *Frame, args: StatusStripArgs) void {
    var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = args.id,
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.card_fill,
        .color_border = style.border_color,
    });
    defer wrap.deinit();

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = args.id,
            .expand = .horizontal,
        });
        defer line.deinit();
        dvui.label(@src(), "{s}", .{args.text}, .{
            .gravity_y = 0.5,
            .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
        });
        if (args.view_link) {
            if (iconButton(@src(), "View", entypo.list, .{
                .id_extra = args.id,
                .style = .control,
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            })) {
                frame.state.screen = .downloads;
            }
        }
    }

    // Progress bar — solid fill for determinate, indeterminate slug
    // (animated against wall-clock seconds) for unknown progress.
    if (args.progress) |pct| {
        const frac: f32 = @as(f32, @floatFromInt(@min(pct, 100))) / 100.0;
        dvui.progress(@src(), .{ .percent = frac, .color = args.accent }, .{
            .id_extra = args.id,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = 10 },
            .border = style.border_thin,
            .corner_radius = .all(2),
            .color_border = style.border_color,
            .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
            .padding = .all(0),
        });
        return;
    }

    var bar_outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = args.id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = 10 },
        .border = style.border_thin,
        .corner_radius = .all(2),
        .color_border = style.border_color,
        .background = true,
        .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
    });
    defer bar_outer.deinit();

    {
        // Indeterminate sweep: quarter-width slug slides L→R every
        // 2 seconds, anchored to wall-clock so the animation reads
        // as "actively working" without a real progress signal.
        const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
        const period_s: i64 = 2;
        const phase = @rem(now_s, period_s);
        const sweep_frac: f32 = @as(f32, @floatFromInt(phase)) / @as(f32, @floatFromInt(period_s));
        const slug_w_frac: f32 = 0.25;
        const left_pad_frac: f32 = sweep_frac * (1.0 - slug_w_frac);
        if (left_pad_frac > 0) {
            var pad = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = args.id ^ 0x9001,
                .min_size_content = .{ .w = @max(0.0, left_pad_frac * 400.0), .h = 8 },
            });
            pad.deinit();
        }
        var slug = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = args.id ^ 0x9002,
            .min_size_content = .{ .w = @max(8.0, slug_w_frac * 400.0), .h = 8 },
            .background = true,
            .color_fill = args.accent,
            .corner_radius = .all(1),
        });
        slug.deinit();
    }
}

fn downloadProgressPct(job: downloads.Job) ?u32 {
    const total = job.bytes_total orelse 0;
    if (total == 0) return null;
    return @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
}

fn downloadStatusText(job: downloads.Job) []const u8 {
    const tmp = struct {
        var buf: [192]u8 = undefined;
    };
    var dl_buf: [24]u8 = undefined;
    var done_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    const total = job.bytes_total orelse 0;
    const dl_s = humanRate(&dl_buf, job.download_speed);
    const done_s = humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) humanBytes(&total_buf, total) else "?";
    if (total > 0) {
        const pct: u32 = @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
        return std.fmt.bufPrint(&tmp.buf, "Downloading {d}% · ↓ {s} · {s} / {s}", .{ pct, dl_s, done_s, total_s }) catch "Downloading";
    }
    return std.fmt.bufPrint(&tmp.buf, "Downloading · ↓ {s} · {s}", .{ dl_s, done_s }) catch "Downloading";
}

/// Clickable thumbnail strip below the carousel. One thumb per slide
/// (cover + screenshots). Click jumps the carousel to that slide. The
/// active slide gets a rose-pink border so the user can see "you are
/// here" at a glance. Strip is wrapped in a horizontal scroll area
/// so games with many screenshots still fit.
fn renderRibbon(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const total: usize = 1 + game.screenshots.len;
    if (total < 2) return;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // `dvui.flexbox` flows children left-to-right and wraps to a new
    // row when the line is full — perfect for the ribbon since games
    // can have up to 21 slides (cover + 20 screenshots).
    var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
    });
    defer flex.deinit();

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const bytes = actions.thumbBytes(frame, game.f95_thread_id, i);
        const is_active = (state.carousel_index == i);
        if (renderRibbonThumb(bytes, i, is_active, game.f95_thread_id)) {
            state.carousel_index = i;
        }
    }
}

/// Render one ribbon thumbnail. Returns `true` when clicked.
fn renderRibbonThumb(bytes_opt: ?[]const u8, idx: usize, is_active: bool, thread_id: u64) bool {
    const id_extra: usize = (@as(usize, @intCast(thread_id)) << 8) | (idx & 0xff) | 0x10000000_0000_0000;
    const border = if (is_active)
        dvui.Color{ .r = 0xE9, .g = 0x4B, .b = 0x7A } // rose accent
    else
        dvui.Color{ .r = 0x5C, .g = 0x2A, .b = 0x3D };

    if (bytes_opt) |bytes| {
        const source: dvui.ImageSource = .{ .imageFile = .{ .bytes = bytes, .name = "ribbon-thumb" } };
        const natural = dvui.imageSize(source) catch dvui.Size{ .w = 16, .h = 9 };
        const aspect_min = scaleToAspectMin(natural);
        const wd = dvui.image(@src(), .{
            .source = source,
            .shrink = .ratio,
        }, .{
            .id_extra = id_extra,
            .min_size_content = aspect_min,
            .max_size_content = .{ .w = RIBBON_THUMB_W, .h = RIBBON_THUMB_H },
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
            .border = .all(if (is_active) 2 else 1),
            .corner_radius = .all(3),
            .color_border = border,
        });
        return dvui.clicked(&wd, .{});
    }
    // Placeholder thumb — same footprint so the strip layout doesn't
    // shift when a slide hasn't been synced yet.
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = RIBBON_THUMB_W, .h = RIBBON_THUMB_H },
        .max_size_content = .{ .w = RIBBON_THUMB_W, .h = RIBBON_THUMB_H },
        .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
        .background = true,
        .border = .all(if (is_active) 2 else 1),
        .corner_radius = .all(3),
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = border,
    });
    defer slot.deinit();
    return dvui.clicked(slot.data(), .{});
}

fn renderCarousel(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    // Reset the index + drop slide cache when the user navigates to a
    // different game. Stale slide bytes from a previous game would
    // hold onto a buffer we no longer reference. The thumb strip
    // cache is keyed by thread internally and self-flushes via
    // `thumbBytes` when the thread changes.
    if (state.carousel_for_thread != game.f95_thread_id) {
        state.carousel_index = 0;
        state.carousel_for_thread = game.f95_thread_id;
        actions.freeSlideCache(state, frame.lib.alloc);
    }

    const total: usize = 1 + game.screenshots.len; // cover + screenshots
    const idx = @min(state.carousel_index, total - 1);

    // Layout: [ prev_col | image_area | next_col ] horizontal row
    // inside a fixed-height vertical slot. This mirrors XLibrary's
    // carousel: chevrons live in dedicated margin columns OUTSIDE the
    // image, vertically centered. The image area takes the remaining
    // width. No more overlay-on-image gravity gymnastics.
    var slot_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = game.f95_thread_id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = CAROUSEL_H },
        .max_size_content = .height(CAROUSEL_H),
    });
    defer slot_box.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer row.deinit();

    const NAV_COL_W: f32 = 72;
    // Chevron buttons span the full carousel height — easier to click,
    // visually anchors them to the slide instead of floating mid-row.
    const NAV_BTN_H: f32 = CAROUSEL_H;

    // Left chevron column. Reserve the space even on single-slide
    // games so the image area's width stays stable.
    var prev_clicked = false;
    if (total > 1) {
        prev_clicked = tallChevronButton(@src(), "prev", entypo.chevron_left, NAV_COL_W, NAV_BTN_H);
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = NAV_COL_W, .h = 1 } });
    }

    // Image area — bounded by an overlay so we can stack the counter
    // on top of the image without affecting its centering. The
    // carousel always shows the FULL-size image; the library screen's
    // cover thumbs (`coverBytes`) intentionally point at the smaller
    // `.t` thumbnail file for fast grid/list rendering.
    const bytes_opt: ?[]const u8 = if (idx == 0)
        actions.coverFullBytes(frame, game.f95_thread_id)
    else
        actions.slideBytes(frame, game.f95_thread_id, idx);

    var img_ov = dvui.overlay(@src(), .{ .expand = .both });
    {
        defer img_ov.deinit();

        const slide_wd = renderSlideImage(frame, bytes_opt, idx, game.f95_thread_id);

        // "N / Total" counter, bottom-center over the image. Faint
        // background so it stays readable on bright slides.
        {
            var ctr_buf: [32]u8 = undefined;
            const ctr = std.fmt.bufPrint(&ctr_buf, "{d} / {d}", .{ idx + 1, total }) catch "?";
            dvui.label(@src(), "{s}", .{ctr}, .{
                .gravity_x = 0.5,
                .gravity_y = 1.0,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
                .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                .corner_radius = style.corner_radius,
                .background = true,
                .color_fill = .{ .r = 0x14, .g = 0x0A, .b = 0x10 },
                .color_text = dvui.Color.white,
            });
        }

        // Image click is checked here, AFTER the chevron buttons
        // already had a chance to consume their events in their
        // own columns — so clicking a chevron never bleeds into a
        // popup-open. (And since the chevrons live OUTSIDE the
        // image now, they can't overlap visually either.)
        if (slide_wd) |wd| {
            if (dvui.clicked(&wd, .{})) {
                state.image_popup_open = true;
            }
        }
    }

    // Right chevron column.
    var next_clicked = false;
    if (total > 1) {
        next_clicked = tallChevronButton(@src(), "next", entypo.chevron_right, NAV_COL_W, NAV_BTN_H);
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = NAV_COL_W, .h = 1 } });
    }

    if (prev_clicked) state.carousel_index = (idx + total - 1) % total;
    if (next_clicked) state.carousel_index = (idx + 1) % total;
}

/// Render a single slide and return its WidgetData (so the caller can
/// check `dvui.clicked()` LATER, after the chevron buttons have had
/// a chance to consume events in their region). Returns null for the
/// placeholder branch (no clickable image to open in a popup).
/// Down-scale a natural image size to a small aspect-preserving min
/// suitable for `min_size_content` on a `.ratio`-expanding image.
/// We just need the WIDTH/HEIGHT ratio, not the absolute pixel size
/// — so we cap the larger side at 32. For a 1920×1080 screenshot
/// this yields {32, 18}; for a 1600×400 banner, {32, 8}.
fn scaleToAspectMin(natural: dvui.Size) dvui.Size {
    const big: f32 = @max(natural.w, natural.h);
    if (big <= 0) return .{ .w = 16, .h = 9 };
    const k: f32 = 32.0 / big;
    return .{ .w = natural.w * k, .h = natural.h * k };
}

fn renderSlideImage(frame: *Frame, bytes_opt: ?[]const u8, idx: usize, thread_id: u64) ?dvui.WidgetData {
    _ = frame;
    const id_extra: usize = (@as(usize, @intCast(thread_id)) << 8) | (idx & 0xff);
    if (bytes_opt) |bytes| {
        // To make the image aspect-fit inside a fixed-size slot
        // without ever inflating the slot, we:
        //   1. Peek the image's natural size via `dvui.imageSize`
        //   2. Pass a SMALL `min_size_content` that has the SAME
        //      aspect ratio as the source — not the absolute pixel
        //      dimensions, otherwise the parent layout demands
        //      "at least N px wide" and the carousel collapses to
        //      image-natural width (left-aligned with whitespace
        //      after).
        //   3. Use `expand = .ratio` so dvui's `placeIn` runs the
        //      aspect-preserving fit in the EXPANDING case too —
        //      `expand = .both, shrink = .ratio` only shrinks when
        //      contracting and STRETCHES when expanding.
        //
        // Result: wide banners fill width with vertical letterbox;
        // narrow/tall screenshots fill height with horizontal
        // letterbox. Image always centered, never distorted, slot
        // keeps its container-driven dimensions.
        const source: dvui.ImageSource = .{ .imageFile = .{ .bytes = bytes, .name = "carousel" } };
        const natural = dvui.imageSize(source) catch dvui.Size{ .w = 16, .h = 9 };
        const aspect_min = scaleToAspectMin(natural);
        const wd = dvui.image(@src(), .{
            .source = source,
            .shrink = .ratio,
        }, .{
            .id_extra = id_extra,
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = aspect_min,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_border = style.border_color,
        });
        return wd;
    }
    // Placeholder slide — happens for screenshots that haven't been
    // synced yet (or failed to fetch). Fills the carousel slot.
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .both,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.border_color,
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
    });
    defer slot.deinit();
    const txt: []const u8 = if (idx == 0) "(no cover)" else "(screenshot not yet synced)";
    dvui.label(@src(), "{s}", .{txt}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    return null;
}

pub fn renderCover(bytes_opt: ?[]const u8) void {
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = "cover" } },
            .shrink = .ratio,
        }, .{
            .min_size_content = .{ .w = 220, .h = 320 },
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_border = style.border_color,
        });
        return;
    }
    var cover = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 220, .h = 320 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.border_color,
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
    });
    defer cover.deinit();
    dvui.label(@src(), "(no cover)", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
}

/// Small thumbnail for the grid card's leading slot. F95 covers are
/// portrait so 60×85 keeps the natural aspect.
pub fn renderCoverThumb(bytes_opt: ?[]const u8, thread_id: u64) void {
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = "thumb" } },
            .shrink = .ratio,
        }, .{
            .id_extra = thread_id,
            .min_size_content = .{ .w = 60, .h = 85 },
            .border = style.border_thin,
            .corner_radius = .all(3),
            .color_border = style.border_color,
        });
        return;
    }
    var thumb = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = thread_id,
        .min_size_content = .{ .w = 60, .h = 85 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .all(3),
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.border_color,
    });
    defer thumb.deinit();
}

fn renderTagChips(tags: []const []const u8) void {
    // dvui.flexbox flows left-to-right and wraps to the next row when
    // it runs out of horizontal space — perfect for the dense F95 tag
    // sets (commonly 30+ tags per game).
    var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
    });
    defer flex.deinit();

    const body = dvui.Font.theme(.body);
    const small = body.withSize(body.size * 0.75);
    for (tags, 0..) |tag, i| {
        // dvui's label format path validates each glyph's UTF-8
        // decoding via `unreachable` branches in render.zig. A scraped
        // tag with stray non-UTF-8 bytes or invalid codepoints (e.g.
        // truncated entity sequences, raw windows-1252 from a hacked
        // skin) can panic the renderer. Cheap defense: skip tags that
        // don't round-trip through `utf8ValidateSlice`, and bound the
        // length so a runaway tag can't blow the upload buffer.
        if (!isPrintableTag(tag)) continue;
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
            .color_fill = .{ .r = 0x3A, .g = 0x1A, .b = 0x28 },
            .color_border = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
        });
        defer chip.deinit();
        dvui.label(@src(), "{s}", .{tag}, .{ .font = small });
    }
}

/// True when `tag` is short enough to draw without strain AND its
/// bytes are valid UTF-8. Used to keep malformed scraped data from
/// reaching dvui's render path, which `unreachable`-asserts on
/// invalid UTF-8 inside `renderText`.
fn isPrintableTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 128) return false;
    return std.unicode.utf8ValidateSlice(tag);
}

// ============================================================
//  downloads screen — paste-URL prototype + active jobs list
// ============================================================

/// Seed-ratio target the running aria2 daemon was configured with.
/// The UI's seed-ratio bar fills toward this number so the user sees
/// the finish line. Falls back to the daemon-wide default (5.0) when
/// the daemon hasn't been spawned yet (e.g. first frame of the app).
fn seedRatioTarget(frame: *Frame) f32 {
    if (frame.dl_mgr.daemon) |d| return d.seed_ratio;
    return 5.0;
}

pub fn downloadsScreen(frame: *Frame) !bool {
    const state = frame.state;

    // Top bar.
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Downloads & Seeding", .{}, .{ .gravity_y = 0.5, .style = .highlight });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Compute live totals across all jobs — gives the user a
        // single glanceable "what's happening" number even before
        // they scroll.
        var live = LiveTotals{};
        var it = frame.dl_mgr.jobs.iterator();
        while (it.next()) |entry| live.fold(entry.value_ptr.*);

        var dl_buf: [24]u8 = undefined;
        var up_buf: [24]u8 = undefined;
        var totals_buf: [192]u8 = undefined;
        const dl_s = humanRate(&dl_buf, live.dl_speed);
        const up_s = humanRate(&up_buf, live.up_speed);
        const totals_s = std.fmt.bufPrint(
            &totals_buf,
            "↓ {s}  ↑ {s}  · {d} dl · {d} seed · {d} done",
            .{ dl_s, up_s, live.n_downloading, live.n_seeding, live.n_done },
        ) catch "";
        dvui.label(@src(), "{s}", .{totals_s}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        // Pause all / Resume all — global controls. The buttons are
        // greyed when there's nothing for them to act on (e.g.
        // "Resume all" with no paused jobs); we keep them rendered
        // so the row layout stays stable.
        const has_paused = frame.dl_mgr.anyPaused();
        const has_resumable = frame.dl_mgr.anyResumable();
        const pause_opts: dvui.Options = if (has_resumable)
            .{}
        else
            .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } };
        if (style.button(@src(), "Pause all", .{}, pause_opts) and has_resumable) {
            frame.dl_mgr.pauseAll();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const resume_opts: dvui.Options = if (has_paused)
            .{ .style = .highlight }
        else
            .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } };
        if (style.button(@src(), "Resume all", .{}, resume_opts) and has_paused) {
            frame.dl_mgr.resumeAll();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        if (style.button(@src(), "Clear completed", .{}, .{})) {
            _ = frame.dl_mgr.clearCompleted();
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    // URL paste row + Download button.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer row.deinit();
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.dl_url_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 600, .h = 28 },
        });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Download", .{}, .{ .style = .highlight })) {
            const url = std.mem.trim(u8, state.dlUrlSlice(), " \t\n\r");
            if (url.len > 0) {
                _ = frame.dl_mgr.enqueueUrl(url, .game, 0, null, null, null, .{}) catch |e| {
                    std.log.scoped(.ui).warn("enqueue failed: {s}", .{@errorName(e)});
                };
                @memset(&state.dl_url_buf, 0);
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    var dst_buf: [256]u8 = undefined;
    const dst_msg = std.fmt.bufPrint(&dst_buf, "Files land in {s}. Torrents seed to a {d:.1}× ratio.", .{
        frame.info.library_root, seedRatioTarget(frame),
    }) catch "Files land in the library root.";
    dvui.label(@src(), "{s}", .{dst_msg}, .{
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    if (frame.dl_mgr.jobCount() == 0) {
        dvui.label(@src(), "No downloads yet — paste a URL above or start one from a game's Download button.", .{}, .{});
        return true;
    }

    var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer list.deinit();

    // Buttons inside the rows can't mutate the jobs map mid-iteration
    // (HashMap iterator gets invalidated). Collect the click + apply
    // after the loop.
    var pending: RowAction = .none;

    // Render in three sections. Per-section count is computed up
    // front so we can skip the header entirely for empty groups (a
    // lone "Seeding" header with nothing under it just adds noise).
    const groups = [_]struct { name: []const u8, group: JobGroup }{
        .{ .name = "Downloading", .group = .downloading },
        .{ .name = "Seeding",     .group = .seeding },
        .{ .name = "Completed",   .group = .done },
    };
    for (groups) |section| {
        var section_n: u32 = 0;
        var iter = frame.dl_mgr.jobs.iterator();
        while (iter.next()) |entry| {
            if (classifyJob(entry.value_ptr.*) == section.group) section_n += 1;
        }
        if (section_n == 0) continue;

        downloadsSectionHeader(section.name, section_n, @intFromEnum(section.group));
        var it = frame.dl_mgr.jobs.iterator();
        while (it.next()) |entry| {
            const job = entry.value_ptr.*;
            if (classifyJob(job) != section.group) continue;
            const title = resolveJobTitle(frame.games, job);
            // .done jobs that are mid-extract get a separate render
            // path so the user sees "[extracting]" instead of a stale
            // "done" pill on the row. The check is read-only and
            // O(active workers) — typically 0–2.
            const extracting = actions.isExtracting(frame, job.id);
            const is_donor = actions.isDonorJob(frame, job.id);
            const action = renderJobRow(job, title, extracting, seedRatioTarget(frame), is_donor);
            switch (action) {
                .none => {},
                else => pending = action,
            }
        }
    }

    switch (pending) {
        .none => {},
        .cancel => |id| frame.dl_mgr.cancel(id),
        .remove => |id| frame.dl_mgr.removeJob(id),
        .retry => |id| actions.retryDownload(frame, id),
    }

    return true;
}

const LiveTotals = struct {
    dl_speed: u64 = 0,
    up_speed: u64 = 0,
    n_downloading: u32 = 0,
    n_seeding: u32 = 0,
    n_done: u32 = 0,

    fn fold(self: *LiveTotals, j: downloads.Job) void {
        switch (classifyJob(j)) {
            .downloading => {
                self.n_downloading += 1;
                self.dl_speed += j.download_speed;
                self.up_speed += j.upload_speed;
            },
            .seeding => {
                self.n_seeding += 1;
                self.up_speed += j.upload_speed;
            },
            .done => self.n_done += 1,
        }
    }
};

/// 3-way bucket for the downloads-screen sections. `downloading`
/// includes anything still pulling bytes; `seeding` is post-payload
/// upload-only; `done` is everything terminal (success / failure /
/// cancel) plus pending HTTP jobs that complete fast enough we don't
/// want a separate "queued" header. Keep the int repr stable —
/// downloadsSectionHeader uses it as the dvui id_extra key.
const JobGroup = enum(u8) { downloading = 1, seeding = 2, done = 3 };

fn classifyJob(j: downloads.Job) JobGroup {
    return switch (j.status) {
        .seeding => .seeding,
        .done, .failed, .cancelled => .done,
        else => .downloading,
    };
}

fn downloadsSectionHeader(label_text: []const u8, count: u32, key: u8) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = key,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 4 },
    });
    defer box.deinit();
    dvui.label(@src(), "{s}", .{label_text}, .{
        .id_extra = key,
        .style = .highlight,
        .gravity_y = 0.5,
    });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 8, .h = 1 } });
    var n_buf: [16]u8 = undefined;
    const n_s = std.fmt.bufPrint(&n_buf, "({d})", .{count}) catch "(?)";
    dvui.label(@src(), "{s}", .{n_s}, .{
        .id_extra = key,
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });
}

const RowAction = union(enum) { none, cancel: u64, remove: u64, retry: u64 };

/// True iff this torrent's upload count has met the configured
/// seed-ratio target. Used to gate the "Remove" button — without
/// this you can stop seeding manually, which goes against the
/// "give back what you took" RPDL contract.
fn ratioMet(job: downloads.Job, ratio_target: f32) bool {
    if (!job.is_torrent) return true; // HTTP downloads have no obligation
    const total = job.bytes_total orelse return false;
    if (total == 0) return false;
    const target: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * ratio_target);
    return job.bytes_uploaded >= target;
}

/// Look up the library row tied to this job's `game_id` (an
/// `f95_thread_id`) and return its `Game.name`. Falls back to the
/// job's source label when the row isn't loaded — manual URL pastes
/// have `game_id = 0` and never match.
fn resolveJobTitle(games: []const library.Game, job: downloads.Job) []const u8 {
    if (job.game_id != 0) {
        for (games) |*g| {
            if (g.f95_thread_id == job.game_id) return g.name;
        }
    }
    return job.source_url;
}

fn renderJobRow(job: downloads.Job, title: []const u8, extracting: bool, ratio_target: f32, is_donor: bool) RowAction {
    var action: RowAction = .none;
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = job.id,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        .color_fill = style.card_fill,
        .color_border = style.border_color,
    });
    defer row.deinit();

    // Header line: status pill + game title + action button.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        var status_buf: [32]u8 = undefined;
        const status_s = if (extracting)
            std.fmt.bufPrint(&status_buf, "[extracting]", .{}) catch "[extracting]"
        else
            std.fmt.bufPrint(&status_buf, "[{s}{s}]", .{
                @tagName(job.status),
                if (job.is_torrent) " · BT" else "",
            }) catch "[?]";
        const status_opts: dvui.Options = switch (job.status) {
            .done => .{ .style = .highlight, .gravity_y = 0.5 },
            .seeding => .{ .style = .highlight, .gravity_y = 0.5 },
            .failed => .{ .style = .err, .gravity_y = 0.5 },
            else => .{ .gravity_y = 0.5 },
        };
        dvui.label(@src(), "{s}", .{status_s}, status_opts);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        // Truncate so the row stays one line — game names can be very
        // long (e.g. light-novel-style titles).
        const truncated = if (title.len > 80) title[0..80] else title;
        dvui.label(@src(), "{s}{s}", .{ truncated, if (title.len > 80) "…" else "" }, .{
            .gravity_y = 0.5,
            .style = .highlight,
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Per-row action policy:
        //   - Failed → Retry + Remove (the only place ✕ Remove
        //     appears on a job we ourselves consider unsuccessful).
        //   - Cancelled → Remove only.
        //   - Done (HTTP non-torrent) → Remove.
        //   - Done (torrent, ratio met) → Remove.
        //   - Done (torrent, still pre-target) → no button — aria2
        //     is still seeding for us.
        //   - Seeding → no button (cannot stop seeding manually
        //     unless the ratio target has been met).
        //   - Downloading donor DDL → Cancel allowed (URLs are
        //     plain HTTP, no community obligation).
        //   - Anything else mid-flight → no button.
        const ratio_met = ratioMet(job, ratio_target);
        const removable = switch (job.status) {
            .failed, .cancelled => true,
            .done => !job.is_torrent or ratio_met,
            .seeding => ratio_met,
            // Donor DDL has no community seeding obligation, so Remove
            // is always safe on those — and necessary, because a job
            // resumed from disk with an expired signed URL sits in
            // `.queued` / `.paused` forever and Cancel→Remove was a
            // two-step the user shouldn't have to discover.
            else => is_donor,
        };
        if (job.status == .failed) {
            if (iconButton(@src(), "Retry", entypo.cycle, .{ .id_extra = job.id, .style = .highlight })) {
                action = .{ .retry = job.id };
            }
        }
        // Cancel button for non-terminal donor jobs — still useful when
        // the user wants to stop a download mid-flight without dropping
        // the row. Coexists with the always-visible Remove (below) so
        // the user has both "stop, keep history" and "stop, forget it".
        if (is_donor) {
            switch (job.status) {
                .queued, .fetching_metadata, .downloading, .verifying, .paused => {
                    if (iconButton(@src(), "Cancel", entypo.cross, .{ .id_extra = job.id, .style = .err })) {
                        action = .{ .cancel = job.id };
                    }
                },
                else => {},
            }
        }
        if (removable) {
            if (iconButton(@src(), "Remove", entypo.trash, .{ .id_extra = job.id })) {
                action = .{ .remove = job.id };
            }
        }
    }

    // Source label subline — `rpdl:<id>` / pasted URL / etc. Skip
    // when the title fell back to the source (we'd be repeating it).
    if (!std.mem.eql(u8, title, job.source_url)) {
        const src_truncated = if (job.source_url.len > 96) job.source_url[0..96] else job.source_url;
        dvui.label(@src(), "{s}{s}", .{ src_truncated, if (job.source_url.len > 96) "…" else "" }, .{
            .color_text = .{ .r = 0x90, .g = 0x70, .b = 0x80 },
        });
    }

    // Download-progress bar — shown for jobs that haven't finished
    // pulling bytes yet. Seeding rows skip this since the payload is
    // already complete.
    if (job.status != .seeding) {
        renderProgressBar(.download, job, ratio_target);
    }

    // Seed-ratio bar — shown for torrents (any status). Lets the user
    // see how close we are to the 2.0× target both while leeching
    // (early progress) and while seeding (the finish line).
    if (job.is_torrent) {
        renderProgressBar(.ratio, job, ratio_target);
    }

    // Live counters line — peers, speeds, ETA. Compact, single line.
    {
        var info = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer info.deinit();
        var line_buf: [256]u8 = undefined;
        const line = composeStatsLine(&line_buf, job, ratio_target) catch "";
        if (line.len > 0) {
            dvui.label(@src(), "{s}", .{line}, .{
                .gravity_y = 0.5,
                .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
            });
        }
    }

    if (job.error_msg) |em| {
        dvui.label(@src(), "error: {s}", .{em}, .{ .style = .err });
    }
    return action;
}

const BarKind = enum { download, ratio };

/// Render one labelled progress bar. `kind = .download` fills against
/// `bytes_done / bytes_total`; `kind = .ratio` fills against
/// `bytes_uploaded / (target * bytes_total)`.
///
/// Uses dvui's built-in `progress` widget so the fill follows the
/// parent's actual width (the prior hand-rolled bar fixed inner width
/// at `pct * 4px`, which capped visually at ~400px wide — so on a
/// wider Downloads pane the bar appeared to "stop at half" even when
/// the job was past 50%).
fn renderProgressBar(kind: BarKind, job: downloads.Job, ratio_target: f32) void {
    const total = job.bytes_total orelse 0;
    const frac: f32 = blk: switch (kind) {
        .download => {
            if (total == 0) break :blk 0.0;
            const done_f: f64 = @floatFromInt(job.bytes_done);
            const total_f: f64 = @floatFromInt(total);
            break :blk @floatCast(@min(done_f / total_f, 1.0));
        },
        .ratio => {
            if (total == 0) break :blk 0.0;
            const denom: f64 = @as(f64, @floatFromInt(total)) * ratio_target;
            if (denom == 0) break :blk 0.0;
            const up_f: f64 = @floatFromInt(job.bytes_uploaded);
            break :blk @floatCast(@min(up_f / denom, 1.0));
        },
    };

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intFromEnum(kind),
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
    });
    defer row.deinit();

    const tag_text: []const u8 = switch (kind) {
        .download => "DL ",
        .ratio => "UP ",
    };
    dvui.label(@src(), "{s}", .{tag_text}, .{
        .id_extra = @intFromEnum(kind),
        .min_size_content = .{ .w = 30, .h = 14 },
        .gravity_y = 0.5,
        .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 },
    });

    const fill_color: dvui.Color = switch (kind) {
        .download => .{ .r = 0xE9, .g = 0x4B, .b = 0x7A },
        .ratio => .{ .r = 0x6D, .g = 0xC0, .b = 0x8B }, // green — "giving back"
    };
    dvui.progress(@src(), .{ .percent = frac, .color = fill_color }, .{
        .id_extra = @intFromEnum(kind),
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = 10 },
        .gravity_y = 0.5,
        .border = style.border_thin,
        .corner_radius = .all(2),
        .color_border = style.border_color,
        .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
        .padding = .all(0),
    });
}

/// Format a one-line stats summary for a job. Adapts to plain HTTP vs
/// torrent and to active vs idle.
fn composeStatsLine(buf: []u8, job: downloads.Job, ratio_target: f32) ![]const u8 {
    const total = job.bytes_total orelse 0;
    var dl_buf: [24]u8 = undefined;
    var up_buf: [24]u8 = undefined;
    var done_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    var up_total_buf: [24]u8 = undefined;
    const dl_s = humanRate(&dl_buf, job.download_speed);
    const up_s = humanRate(&up_buf, job.upload_speed);
    const done_s = humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) humanBytes(&total_buf, total) else "?";
    const up_total_s = humanBytes(&up_total_buf, job.bytes_uploaded);

    if (job.is_torrent) {
        const ratio: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(job.bytes_uploaded)) / @as(f32, @floatFromInt(total));
        if (job.status == .seeding) {
            // ETA to ratio target: remaining bytes / current up speed.
            const target_bytes: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * ratio_target);
            const remaining: u64 = if (job.bytes_uploaded >= target_bytes) 0 else target_bytes - job.bytes_uploaded;
            var eta_buf: [32]u8 = undefined;
            const eta_s: []const u8 = if (job.upload_speed > 0 and remaining > 0)
                humanEta(&eta_buf, remaining / @max(job.upload_speed, 1))
            else if (remaining == 0)
                "target reached"
            else
                "idle";
            return std.fmt.bufPrint(
                buf,
                "↑ {s} · uploaded {s} · ratio {d:.2}× / {d:.1}× · peers {d} · {s}",
                .{ up_s, up_total_s, ratio, ratio_target, job.connections, eta_s },
            );
        }
        return std.fmt.bufPrint(
            buf,
            "↓ {s}  ↑ {s} · {s} / {s} · ratio {d:.2}× · seeders {d}/{d}",
            .{ dl_s, up_s, done_s, total_s, ratio, job.num_seeders, job.connections },
        );
    }
    // Plain HTTP.
    const pct: u32 = if (total == 0) 0 else @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
    if (total > 0) {
        return std.fmt.bufPrint(buf, "↓ {s} · {s} / {s} ({d}%)", .{ dl_s, done_s, total_s, pct });
    }
    return std.fmt.bufPrint(buf, "↓ {s} · {s}", .{ dl_s, done_s });
}

/// Format a byte count to "12.3 MB" / "456 KB" / "789 B". Pure
/// formatter, no allocation — works on a caller-provided buffer.
fn humanBytes(buf: []u8, n: u64) []const u8 {
    const KB: f32 = 1024.0;
    const MB: f32 = 1024.0 * 1024.0;
    const GB: f32 = 1024.0 * 1024.0 * 1024.0;
    const f: f32 = @floatFromInt(n);
    if (f >= GB) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / GB}) catch "?";
    if (f >= MB) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / MB}) catch "?";
    if (f >= KB) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / KB}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

fn humanRate(buf: []u8, bytes_per_sec: u64) []const u8 {
    if (bytes_per_sec == 0) return "—";
    var inner_buf: [24]u8 = undefined;
    const human = humanBytes(&inner_buf, bytes_per_sec);
    return std.fmt.bufPrint(buf, "{s}/s", .{human}) catch "?";
}

/// Format an ETA in seconds → "3m 42s" / "1h 7m" / "2d 14h".
fn humanEta(buf: []u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
    if (seconds < 3600) {
        const m = seconds / 60;
        const s = seconds % 60;
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s }) catch "?";
    }
    if (seconds < 86400) {
        const h = seconds / 3600;
        const m = (seconds % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "?";
    }
    const d = seconds / 86400;
    const h = (seconds % 86400) / 3600;
    return std.fmt.bufPrint(buf, "{d}d {d}h", .{ d, h }) catch "?";
}

// ============================================================
//  sorting
// ============================================================

const SortCtx = struct {
    column: state_mod.SortColumn,
    dir: state_mod.SortDir,
    /// Library-wide mean rating, used by the `.weighted` column.
    /// Computed once per sort.
    library_mean: f32,
};

/// Prior weight for the Bayesian-shrinkage weighted rating. A higher
/// number means low-vote games get pulled harder toward the library
/// mean (good — fewer "perfect 5.0 with 2 votes" outliers). 10 is the
/// F95-ish balance between honoring genuine niche gems and damping
/// noise.
const WEIGHTED_PRIOR: f32 = 10.0;

fn sortGames(games: []library.Game, column: state_mod.SortColumn, dir: state_mod.SortDir) void {
    // For weighted sort we need the library mean. Cheap one-pass scan.
    var sum: f32 = 0;
    var n: u32 = 0;
    for (games) |*g| {
        if (g.rating) |r| {
            sum += r;
            n += 1;
        }
    }
    const mean: f32 = if (n > 0) sum / @as(f32, @floatFromInt(n)) else 0;

    std.mem.sort(library.Game, games, SortCtx{ .column = column, .dir = dir, .library_mean = mean }, gameLessThan);
}

fn gameLessThan(ctx: SortCtx, a: library.Game, b: library.Game) bool {
    const asc: bool = ctx.dir == .asc;
    return switch (ctx.column) {
        .sync_state => {
            // Synced rows first when ascending; unsynced first when
            // descending. Tie-break alphabetically so the secondary
            // order stays readable.
            const a_synced = a.last_scraped_at != null;
            const b_synced = b.last_scraped_at != null;
            if (a_synced != b_synced) return if (asc) a_synced else b_synced;
            const al = std.ascii.lessThanIgnoreCase(a.name, b.name);
            const bl = std.ascii.lessThanIgnoreCase(b.name, a.name);
            if (al == bl) return a.f95_thread_id < b.f95_thread_id;
            return al;
        },
        .name => {
            const al = std.ascii.lessThanIgnoreCase(a.name, b.name);
            const bl = std.ascii.lessThanIgnoreCase(b.name, a.name);
            // al/bl can both be false on case-insensitive equality;
            // tie-break on f95_thread_id so the sort is stable across
            // frames.
            if (al == bl) return if (asc) a.f95_thread_id < b.f95_thread_id else a.f95_thread_id > b.f95_thread_id;
            return if (asc) al else bl;
        },
        .rating => {
            const ra = a.rating orelse -1.0;
            const rb = b.rating orelse -1.0;
            if (ra == rb) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) ra < rb else ra > rb;
        },
        .weighted => {
            // Bayesian shrinkage: (v / (v + prior)) * R + (prior / (v + prior)) * library_mean.
            // Games with no rating sort to the bottom by using -1.
            const wa = a.weightedRating(ctx.library_mean, WEIGHTED_PRIOR) orelse -1.0;
            const wb = b.weightedRating(ctx.library_mean, WEIGHTED_PRIOR) orelse -1.0;
            if (wa == wb) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) wa < wb else wa > wb;
        },
        .votes => {
            const va = a.vote_count orelse 0;
            const vb = b.vote_count orelse 0;
            if (va == vb) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) va < vb else va > vb;
        },
        .last_updated => {
            // Null sorts to the bottom in both directions — entries
            // where we couldn't parse a "Thread Updated" line
            // shouldn't crowd out games with real timestamps.
            const ua: i64 = a.last_updated_at orelse std.math.minInt(i64);
            const ub: i64 = b.last_updated_at orelse std.math.minInt(i64);
            if (ua == ub) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) ua < ub else ua > ub;
        },
    };
}

// ============================================================
//  Diagnostics screen — read-only state dump for bug reports
// ============================================================

pub fn diagnosticsScreen(frame: *Frame) !bool {
    const state = frame.state;
    const info = frame.info;

    // Top bar — back button to library.
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (iconOnly(@src(), "back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Diagnostics", .{}, .{ .gravity_y = 0.5, .style = .highlight });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        .expand = .horizontal,
    });
    defer body.deinit();

    // --- build ---
    diagSection(@src(), "Build");
    diagRow(@src(), "f69 version", build_options.version);

    diagSep();

    // --- paths ---
    diagSection(@src(), "Paths");
    diagRow(@src(), "data_root (portable)", info.data_root);
    diagRow(@src(), "db_path", info.db_path);
    diagRow(@src(), "library_root", info.library_root);
    diagRow(@src(), "covers_dir", info.covers_dir);
    diagRow(@src(), "recipes_dir", info.recipes_dir);
    diagRow(@src(), "cookie_path", info.cookie_path);
    diagRow(@src(), "rpdl_token_path", info.rpdl_token_path);
    diagRow(@src(), "browser_path_file", info.browser_path_file);

    diagSep();

    // --- sandbox ---
    diagSection(@src(), "Sandbox");
    diagRow(@src(), "backend", frame.sandbox.backendName());

    // --- host env snapshot ---
    diagSep();
    diagSection(@src(), "Host env (captured at startup)");
    diagRow(@src(), "$HOME", info.host.home orelse "(unset)");
    diagRow(@src(), "$XDG_RUNTIME_DIR", info.host.xdg_runtime_dir orelse "(unset)");
    diagRow(@src(), "$WAYLAND_DISPLAY", info.host.wayland_display orelse "(unset)");
    diagRow(@src(), "$DISPLAY", info.host.x11_display orelse "(unset)");

    diagSep();

    // --- accounts / tokens ---
    diagSection(@src(), "Accounts");
    diagRow(@src(), "F95 login", switch (state.login_status) {
        .logged_in => "logged in",
        .logged_out => "logged out",
        .logging_in => "logging in…",
        .err => "error",
        .unknown => "unknown",
    });
    diagRow(@src(), "RPDL", switch (state.rpdl_status) {
        .logged_in => "logged in (token set)",
        .logged_out => "logged out (no token)",
        .logging_in => "logging in…",
        .err => "error",
        .unknown => "unknown",
    });

    diagSep();

    // --- downloads ---
    {
        diagSection(@src(), "Downloads");
        var jobs_buf: [64]u8 = undefined;
        const jobs_msg = std.fmt.bufPrint(&jobs_buf, "{d} job(s) in Manager", .{frame.dl_mgr.jobs.count()}) catch "?";
        dvui.label(@src(), "{s}", .{jobs_msg}, .{});

        var it = frame.dl_mgr.jobs.iterator();
        while (it.next()) |entry| {
            const j = entry.value_ptr;
            var row_buf: [256]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "  #{d} [{s}/{s}] game={d} mod={?d} src={s}", .{
                j.id,
                @tagName(j.kind),
                @tagName(j.status),
                j.game_id,
                j.mod_id,
                j.source_url,
            }) catch continue;
            dvui.label(@src(), "{s}", .{row}, .{});
        }
    }

    diagSep();

    // --- installs from DB ---
    {
        diagSection(@src(), "Installs (SQLite)");
        // Walk every game; for each, list its installs.
        for (frame.games) |g| {
            const installs = frame.lib.listInstalls(g.f95_thread_id) catch continue;
            defer frame.lib.freeInstalls(installs);
            if (installs.len == 0) continue;

            var header_buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "  {d}  {s}", .{ g.f95_thread_id, g.name }) catch continue;
            dvui.label(@src(), "{s}", .{header}, .{ .style = .highlight });
            for (installs) |i| {
                var ib: [320]u8 = undefined;
                const line = std.fmt.bufPrint(&ib, "    v{s} at {s} (installed_at={d})", .{ i.version, i.install_path, i.installed_at }) catch continue;
                dvui.label(@src(), "{s}", .{line}, .{});
            }
        }
    }

    diagSep();

    // --- selected game tracker ---
    if (state.selected_thread) |tid| {
        diagSection(@src(), "Tracker (selected game)");
        const inst_opt = frame.lib.latestInstallForGame(tid) catch null;
        defer if (inst_opt) |i| frame.lib.freeInstall(i);
        if (inst_opt) |inst| {
            var tracker_path_buf: [768]u8 = undefined;
            const tracker_path = std.fmt.bufPrint(&tracker_path_buf, "{s}/.f69-mods.json", .{inst.install_path}) catch return false;
            var log_obj = installer_for_diag.Tracker.load(frame.lib.alloc, frame.io, tracker_path) catch installer_for_diag.InstallLog{ .entries = &.{} };
            defer log_obj.deinit(frame.lib.alloc);

            var hb: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hb, "  {d} entries at {s}", .{ log_obj.entries.len, tracker_path }) catch return false;
            dvui.label(@src(), "{s}", .{hdr}, .{});
            for (log_obj.entries) |e| {
                var eb: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&eb, "    [{s}] mod={s} path={s}", .{ @tagName(e.kind), e.mod_id, e.path }) catch continue;
                dvui.label(@src(), "{s}", .{line}, .{});
            }
        } else {
            dvui.label(@src(), "  (no installs DB row for selected game)", .{}, .{});
        }
    }

    return true;
}

const installer_for_diag = @import("installer");

fn diagSection(src: anytype, name: []const u8) void {
    dvui.label(src, "{s}", .{name}, .{ .style = .highlight });
}

fn diagRow(src: anytype, key: []const u8, value: []const u8) void {
    var buf: [768]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}: {s}", .{ key, value }) catch return;
    dvui.label(src, "{s}", .{line}, .{});
}

fn diagSep() void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
}
