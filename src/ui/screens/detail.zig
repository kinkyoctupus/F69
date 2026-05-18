// Detail screen — per-game page with carousel, action toolbar,
// facts grid, tabs (Description / Changelog / Notes / Downloads),
// install picker / management popups, image popup, clash modal.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");
const downloads = @import("downloads");
const file_picker = @import("util_file_picker");
const version_mod = @import("util_version");

const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");

const Frame = types.Frame;
const HELP_TEXT_COLOR = components.HELP_TEXT_COLOR;

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
        state.screen = .library;
        return true;
    };

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

        if (components.iconOnly(@src(), "back", entypo.chevron_left, .{})) {
            state.screen = .library;
            state.selected_thread = null;
            state.clearTransientToasts();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "{s}", .{game.name}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (components.iconButton(@src(), "Delete", entypo.trash, .{ .style = .err })) {
            state.confirm_delete = true;
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

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
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) state.confirm_delete = false;
        if (components.iconButton(@src(), "Delete", entypo.trash, .{ .style = .err })) {
            actions.deleteGameAndReturn(frame, game.f95_thread_id);
            return true;
        }
    }

    var page_scroll = dvui.scrollArea(@src(), .{ .scroll_info = &state.detail_scroll }, .{ .expand = .both });

    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        });
        defer hdr.deinit();

        renderCarousel(frame, game);

        renderRibbon(frame, game);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

        renderIdentityPillRow(frame, game);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

        renderActionRow(frame, game);

        renderDetailStatusLine(frame, game);

        if (state.convert_help_open) renderConvertHelp();
        if (state.manual_install_open) renderManualInstallPanel(frame, game);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

        renderDetailFactsGrid(frame, game);
    }

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

    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
        });
        defer tabs.deinit();

        if (components.tabButton("Description", state.detail_tab == .overview)) state.detail_tab = .overview;
        if (components.tabButton("Changelog", state.detail_tab == .changelog)) state.detail_tab = .changelog;
        if (components.tabButton("Notes", state.detail_tab == .notes)) state.detail_tab = .notes;
        if (components.tabButton("Downloads", state.detail_tab == .downloads)) state.detail_tab = .downloads;
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
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

    page_scroll.deinit();

    renderImagePopup(frame, game);

    renderInstallManagePopups(frame, game);

    renderClashModal(frame, game);

    return true;
}

// ============================================================
//  Detail-screen meta layout helpers
// ============================================================

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

fn renderIdentityPillRow(frame: *Frame, game: *const library.Game) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    defer row.deinit();

    if (game.engine != .unknown) {
        const fill = components.engineBadgeColor(game.engine);
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
        dvui.label(@src(), "{s}", .{components.engineShortLabel(game.engine)}, .{
            .gravity_y = 0.5,
            .color_text = dvui.Color.white,
        });
    }

    if (game.dev_status != .unknown) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const fill = components.devStatusColor(game.dev_status);
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
        dvui.label(@src(), "{s}", .{components.devStatusShortLabel(game.dev_status)}, .{
            .gravity_y = 0.5,
            .color_text = dvui.Color.white,
        });
    }

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

fn renderDetailFactsGrid(frame: *Frame, game: *library.Game) void {
    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = game.f95_thread_id ^ 0xF9,
        .expand = .horizontal,
    });
    defer grid.deinit();

    var row_id: u32 = 1;

    if (game.latest_version) |v| {
        factsRow(&row_id, "Version", .{ .text = v });
    }
    if (game.developer) |d| {
        factsRow(&row_id, "Developer", .{ .text = d });
    }
    if (game.last_updated_at) |ts| {
        var buf: [32]u8 = undefined;
        const dt = components.formatUtcDateTime(&buf, ts) catch "—";
        factsRow(&row_id, "Last updated", .{ .text = dt });
    }

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
            components.formatUtcDateTime(&dt_buf, ts) catch "—"
        else
            "never";
        dvui.label(@src(), "{s}", .{dt}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (components.iconButton(@src(), "Sync now", entypo.cycle, .{
            .style = .control,
            .gravity_y = 0.5,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        })) {
            actions.syncGame(frame, game);
        }
    }

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

const FactsValue = union(enum) {
    text: []const u8,
};

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

/// Human-friendly labels for `library.CompletionStatus`.
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

/// Short ASCII source-of-install tag prepended to install picker
/// entries. Recipe entries get no prefix.
fn sourceTag(s: library.InstallSource) []const u8 {
    return switch (s) {
        .recipe => "",
        .manual => "[file] ",
        .rpdl => "[rpdl] ",
        .imported => "[imported] ",
    };
}

fn renderManualInstallPanel(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    {
        const path = state.manualInstallPathSlice();
        const version = state.manualInstallVersionSlice();
        if (path.len > 0 and version.len == 0) {
            const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
            const base_with_ext = if (slash == 0) path else path[slash + 1 ..];
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
    components.settingsHelpText(
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
    if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
        state.manual_install_open = false;
    }
    if (components.iconButton(@src(), "Install", entypo.upload, .{ .style = .highlight })) {
        actions.startManualInstall(
            frame,
            game.f95_thread_id,
            state.manualInstallPathSlice(),
            state.manualInstallVersionSlice(),
            state.manualInstallNameSlice(),
        );
        if (frame.state.manual_install_jobs) |list_ptr| {
            if (list_ptr.items.len > 0) {
                state.resetManualInstallFields();
                state.manual_install_open = false;
            }
        }
    }
}

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
    if (components.iconButton(@src(), "Browse\u{2026}", entypo.folder, .{
        .gravity_y = 0.5,
    })) {
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

// ============================================================
//  Image popup + install management popups
// ============================================================

fn renderImagePopup(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (!state.image_popup_open) return;
    if (state.carousel_for_thread != game.f95_thread_id) {
        state.image_popup_open = false;
        return;
    }

    const idx = state.carousel_index;

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
    dvui.label(@src(), "(image not available)", .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .both,
    });
}

fn renderInstallManagePopups(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (state.manage_action == .none) return;
    const sel_id = state.manage_install_id orelse {
        state.manage_action = .none;
        return;
    };

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
    components.settingsHelpText(
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
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
            open = false;
        }
        if (components.iconButton(@src(), "Save", entypo.check, .{ .style = .highlight })) {
            actions.doRenameInstall(frame, inst.id, state.manageRenameSlice());
            open = false;
        }
    }

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
    components.settingsHelpText(
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
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
            open = false;
        }
        if (components.iconButton(@src(), "Delete from disk", entypo.trash, .{ .style = .err })) {
            actions.doDeleteInstall(frame, inst.id, inst.install_path);
            open = false;
        }
    }

    if (!open) {
        state.manage_action = .none;
        state.manage_install_id = null;
    }
}

// ============================================================
//  Tab bodies — Description / Changelog / Notes / Downloads
// ============================================================

fn renderOverview(frame: *Frame, game: *const library.Game) void {
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

fn renderWrappedText(text: ?[]const u8, placeholder: []const u8) void {
    // cache_layout: text is immutable between frames (description /
    // reviews payload only changes on re-sync). Without the cache,
    // dvui re-runs line-break + glyph layout every frame — that's
    // what put `addTextEx` at 70 ms on `render detail` in the
    // earlier latency log.
    var tl = dvui.textLayout(@src(), .{ .cache_layout = true }, .{ .expand = .horizontal, .background = false });
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
        const line_id: u64 = base_id +% (@as(u64, iter_idx) << @intCast(@min(depth * 4, 56)));
        iter_idx += 1;
        i = nl + 1;

        if (trimmed.len == 0) {
            _ = dvui.spacer(@src(), .{ .id_extra = line_id, .min_size_content = .{ .w = 1, .h = 4 } });
            continue;
        }

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

        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const body = trimmed[3..];
            dvui.label(@src(), "{s}", .{body}, .{
                .id_extra = line_id,
                .style = .highlight,
                .expand = .horizontal,
            });
            continue;
        }

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

        renderInlineLineWithLinks(frame, trimmed, line_id);
    }
}

fn renderInlineLineWithLinks(frame: *Frame, line: []const u8, id: u64) void {
    // cache_layout: line content is keyed by `id` (per-paragraph hash)
    // and only changes when scraped text changes. The structured-text
    // walker rebuilds one textLayout per line of changelog / downloads
    // / overview — 30-200 textLayouts per Detail render. Without the
    // cache every one re-runs line-break + glyph layout each frame.
    var tl = dvui.textLayout(@src(), .{ .cache_layout = true }, .{
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

fn renderNotesTab(frame: *Frame, game: *library.Game) void {
    const state = frame.state;

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

// ============================================================
//  Clash modal (file-conflict warning)
// ============================================================

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
            return;
        }
    }

    if (!open) actions.closeClashModal(frame);
}

// ============================================================
//  Action toolbar + status strip + idle hints
// ============================================================

fn renderActionRow(frame: *Frame, game: *library.Game) void {
    const state = frame.state;

    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    defer row.deinit();

    const launch_fill: dvui.Color = .{ .r = 0xFF, .g = 0x33, .b = 0x77 };
    const launch_hover: dvui.Color = .{ .r = 0xFF, .g = 0x66, .b = 0xA0 };
    const launch_press: dvui.Color = .{ .r = 0xCC, .g = 0x29, .b = 0x5E };
    const launch_fill_off: dvui.Color = .{ .r = 0x3A, .g = 0x22, .b = 0x2A };
    const launch_text_off: dvui.Color = .{ .r = 0x80, .g = 0x60, .b = 0x70 };

    if (actions.isGameRunning(frame, game.f95_thread_id)) {
        if (components.iconButton(@src(), "Stop", entypo.cross, .{ .style = .err })) {
            actions.doStopGame(frame, game);
        }
    } else {
        const enabled = actions.installDotState(frame, game) != .none;
        const click = components.iconButton(@src(), "Launch", entypo.forward, if (enabled) .{
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

    if (!actions.isGameRunning(frame, game.f95_thread_id) and
        !actions.hasActiveDownloadForGame(frame, game.f95_thread_id) and
        !actions.isInstallingForGame(frame, game.f95_thread_id) and
        actions.installDotState(frame, game) == .outdated)
    {
        const newer = game.latest_version orelse "latest";
        var btn_buf: [48]u8 = undefined;
        const btn_label = std.fmt.bufPrint(&btn_buf, "Update to {s}", .{newer}) catch "Update";
        if (components.iconButton(@src(), btn_label, entypo.cloud, .{
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
        if (picked < installs.len) {
            frame.state.detail_picker_install_id = installs[picked].id;
        }

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
        }
    }

    if (components.iconButton(@src(), "Folder", entypo.folder, .{})) {
        actions.doOpenGameFolder(frame, game);
    }
    if (components.iconButton(@src(), "Saves", entypo.home, .{})) {
        actions.doOpenSaves(frame, game);
    }
    if (components.iconButton(@src(), "Backup", entypo.archive, .{})) {
        actions.doBackupSaves(frame, game);
    }
    renderDetailDownloadButton(frame, game);

    renderDetailInstallButton(frame, game);

    if (components.iconButton(@src(), "Convert", entypo.cycle, .{})) {
        actions.doConvertGame(frame, game);
    }
    if (components.iconOnly(@src(), "Help", entypo.help, .{
        .style = if (state.convert_help_open) .highlight else .control,
        .min_size_content = .{ .w = style.button_h, .h = style.button_h },
    })) {
        state.convert_help_open = !state.convert_help_open;
    }

    if (components.iconButton(@src(), "Mods", entypo.tools, .{})) {
        state.screen = .mods_for_game;
    }

    if (components.iconButton(@src(), "Fix Compat", entypo.tools, .{})) {
        doCompatFixForActiveInstall(frame, game);
    }
}

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

fn renderDetailDownloadButton(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const rpdl_busy = state.pending_rpdl_download != null;
    const donor_busy = state.pending_donor_download != null;
    const job_active = actions.hasActiveDownloadForGame(frame, game.f95_thread_id);

    _ = job_active;

    const have_rpdl = state.rpdl_token != null and (state.rpdl_token.?.len > 0);
    const have_f95 = state.login_status == .logged_in;
    const busy = rpdl_busy or donor_busy;

    const primary_label: []const u8 = blk: {
        if (rpdl_busy) break :blk "Searching…";
        if (donor_busy) break :blk "Requesting…";
        break :blk "Download";
    };
    const primary_opts: dvui.Options = if (busy)
        .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } }
    else
        .{};

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xACCE });
    defer bar.deinit();

    if (have_rpdl) {
        const clicked = components.iconButton(@src(), primary_label, entypo.download, primary_opts);
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
        const clicked = components.iconButton(@src(), primary_label, entypo.download, primary_opts);
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
        if (components.iconButton(@src(), "Download (sign in first)", entypo.download, dim_opts)) {
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
        if (dvui.menuItemLabel(@src(), "Install from file\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
            state.manual_install_open = true;
            bar.close();
        }
    }
}

fn renderDetailInstallButton(frame: *Frame, game: *const library.Game) void {
    var buf: [16]actions.DownloadedEntry = undefined;
    const entries = actions.listDownloadedNotInstalled(frame, game.f95_thread_id, &buf);
    if (entries.len == 0) return;

    if (entries.len == 1) {
        if (components.iconButton(@src(), "Install", entypo.tools, .{ .style = .highlight })) {
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

    if (components.iconButton(@src(), "Install", entypo.tools, .{ .style = .highlight })) {
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

fn renderDetailStatusLine(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

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

    const dot = actions.installDotState(frame, game);
    const auto_on = blk: {
        if (dot == .none) break :blk false;
        break :blk actions.shouldAutoUpdate(state, game);
    };
    if (dot == .outdated) {
        const newer = game.latest_version orelse "latest";
        const has_auto = actions.hasAutoFetchableSource(frame, game.f95_thread_id);
        var msg_buf: [240]u8 = undefined;
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
        renderIdleHint(game.f95_thread_id ^ 0xB2, "auto-updates on");
    }
}

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
    progress: ?u32,
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
            if (components.iconButton(@src(), "View", entypo.list, .{
                .id_extra = args.id,
                .style = .control,
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            })) {
                frame.state.screen = .downloads;
            }
        }
    }

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
    const dl_s = components.humanRate(&dl_buf, job.download_speed);
    const done_s = components.humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) components.humanBytes(&total_buf, total) else "?";
    if (total > 0) {
        const pct: u32 = @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
        return std.fmt.bufPrint(&tmp.buf, "Downloading {d}% · ↓ {s} · {s} / {s}", .{ pct, dl_s, done_s, total_s }) catch "Downloading";
    }
    return std.fmt.bufPrint(&tmp.buf, "Downloading · ↓ {s} · {s}", .{ dl_s, done_s }) catch "Downloading";
}

// ============================================================
//  Carousel / ribbon / cover renderers
// ============================================================

pub const CAROUSEL_H: f32 = 360;
pub const RIBBON_THUMB_W: f32 = 96;
pub const RIBBON_THUMB_H: f32 = 54;
pub const RIBBON_H: f32 = RIBBON_THUMB_H + 12;

const ICON_SIZE: dvui.Size = style.icon_size;
const ICON_OPTS: dvui.IconRenderOptions = .{};

/// Tall icon button used by the carousel chevrons. Around `iconOnly`
/// because the carousel chevrons explicitly want a larger button.
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

fn renderRibbon(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const total: usize = 1 + game.screenshots.len;
    if (total < 2) return;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

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

fn renderRibbonThumb(bytes_opt: ?[]const u8, idx: usize, is_active: bool, thread_id: u64) bool {
    const id_extra: usize = (@as(usize, @intCast(thread_id)) << 8) | (idx & 0xff) | 0x10000000_0000_0000;
    const border = if (is_active)
        dvui.Color{ .r = 0xE9, .g = 0x4B, .b = 0x7A }
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

    if (state.carousel_for_thread != game.f95_thread_id) {
        state.carousel_index = 0;
        state.carousel_for_thread = game.f95_thread_id;
        actions.freeSlideCache(state, frame.lib.alloc);
    }

    const total: usize = 1 + game.screenshots.len;
    const idx = @min(state.carousel_index, total - 1);

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
    const NAV_BTN_H: f32 = CAROUSEL_H;

    var prev_clicked = false;
    if (total > 1) {
        prev_clicked = tallChevronButton(@src(), "prev", entypo.chevron_left, NAV_COL_W, NAV_BTN_H);
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = NAV_COL_W, .h = 1 } });
    }

    const bytes_opt: ?[]const u8 = if (idx == 0)
        actions.coverFullBytes(frame, game.f95_thread_id)
    else
        actions.slideBytes(frame, game.f95_thread_id, idx);

    var img_ov = dvui.overlay(@src(), .{ .expand = .both });
    {
        defer img_ov.deinit();

        const slide_wd = renderSlideImage(frame, bytes_opt, idx, game.f95_thread_id);

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

        if (slide_wd) |wd| {
            if (dvui.clicked(&wd, .{})) {
                state.image_popup_open = true;
            }
        }
    }

    var next_clicked = false;
    if (total > 1) {
        next_clicked = tallChevronButton(@src(), "next", entypo.chevron_right, NAV_COL_W, NAV_BTN_H);
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = NAV_COL_W, .h = 1 } });
    }

    if (prev_clicked) state.carousel_index = (idx + total - 1) % total;
    if (next_clicked) state.carousel_index = (idx + 1) % total;
}

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
    var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
    });
    defer flex.deinit();

    const body = dvui.Font.theme(.body);
    const small = body.withSize(body.size * 0.75);
    for (tags, 0..) |tag, i| {
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

fn isPrintableTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 128) return false;
    return std.unicode.utf8ValidateSlice(tag);
}
