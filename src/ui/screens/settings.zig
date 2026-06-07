// Settings screen — tabs for general / sync / accounts / library /
// downloads / mod-presets / convert-presets / about.

const std = @import("std");
const build_options = @import("build_options");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");

const tokens = @import("ui_tokens");
const comp = @import("ui_comp");
const theme_store = @import("ui_theme_store");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const import_job_mod = @import("../import_job.zig");
const components = @import("../components.zig");

const Frame = types.Frame;
const State = types.State;
const helpTextColor = components.helpTextColor;

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
        if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
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

        if (components.tabButton("General", state.settings_tab == .general)) state.settings_tab = .general;
        if (components.tabButton("Sync", state.settings_tab == .sync)) state.settings_tab = .sync;
        if (components.tabButton("Accounts", state.settings_tab == .accounts)) state.settings_tab = .accounts;
        if (components.tabButton("Library", state.settings_tab == .library)) state.settings_tab = .library;
        if (components.tabButton("Downloads", state.settings_tab == .downloads)) state.settings_tab = .downloads;
        if (components.tabButton("Mod presets", state.settings_tab == .mod_presets)) state.settings_tab = .mod_presets;
        if (components.tabButton("Convert presets", state.settings_tab == .convert_presets)) state.settings_tab = .convert_presets;
        if (components.tabButton("Appearance", state.settings_tab == .appearance)) state.settings_tab = .appearance;
        if (components.tabButton("About", state.settings_tab == .about)) state.settings_tab = .about;
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
        .appearance => renderSettingsAppearance(frame),
        .about => renderSettingsAbout(frame),
    }

    return true;
}

/// Appearance tab — live theme picker (Design B). Preset buttons + accent
/// swatches mutate `tokens.active`; the main loop re-applies the theme each
/// frame so changes show instantly.
fn renderSettingsAppearance(frame: *Frame) void {
    var changed = false;
    dvui.labelNoFmt(@src(), "Theme preset", .{}, .{});
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 0, .y = 6, .w = 0, .h = 10 } });
        defer row.deinit();
        if (style.button(@src(), "Console", .{}, .{})) {
            tokens.active = tokens.presets.console;
            changed = true;
        }
        if (style.button(@src(), "Obsidian", .{}, .{})) {
            tokens.active = tokens.presets.obsidian;
            changed = true;
        }
        if (style.button(@src(), "Midnight", .{}, .{})) {
            tokens.active = tokens.presets.midnight;
            changed = true;
        }
        if (style.button(@src(), "Paper (light)", .{}, .{})) {
            tokens.active = tokens.presets.paper;
            changed = true;
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), "Accent", .{}, .{ .padding = .{ .x = 0, .y = 10, .w = 0, .h = 6 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        const swatches = [_]tokens.Color{
            .{ .r = 0x34, .g = 0xd0, .b = 0xc4 }, // teal
            .{ .r = 0xe8, .g = 0xa1, .b = 0x3c }, // amber
            .{ .r = 0xe0, .g = 0x56, .b = 0x7f }, // rose
            .{ .r = 0x6c, .g = 0x8c, .b = 0xff }, // indigo
            .{ .r = 0x8b, .g = 0xe9, .b = 0xfd }, // cyan
            .{ .r = 0xb8, .g = 0xe3, .b = 0x4a }, // lime
        };
        inline for (swatches, 0..) |sw, i| {
            const opts: dvui.Options = .{
                .id_extra = i,
                .min_size_content = .{ .w = 28, .h = 28 },
                .background = true,
                .color_fill = tokens.toDvui(sw, dvui.Color),
                .corner_radius = dvui.Rect.all(tokens.r),
                .border = dvui.Rect.all(1),
                .color_border = tokens.toDvui(tokens.active.line, dvui.Color),
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            };
            if (dvui.button(@src(), "", .{}, opts)) {
                tokens.active = tokens.fromBase(.{
                    .bg = tokens.active.bg0,
                    .accent = sw,
                    .ink = tokens.active.ink,
                    .accent2 = tokens.active.accent2,
                });
                changed = true;
            }
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), "Preview", .{}, .{ .padding = .{ .x = 0, .y = 10, .w = 0, .h = 6 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        _ = comp.button(@src(), "Play", .primary, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        comp.engineChip(@src(), "Ren'Py", .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        comp.statusChip(@src(), "Ongoing", .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        comp.newChip(@src(), .{ .gravity_y = 0.5 });
    }
    {
        var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 0, .y = 10, .w = 0, .h = 0 } });
        defer row2.deinit();
        comp.progressBar(@src(), 0.62, 220, .{ .gravity_y = 0.5 });
    }

    if (changed) theme_store.save(frame.io);
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
    settingsSectionDivider(11);
    renderMinSessionSecondsSection(frame);
}

/// "Auto-download updates" checkbox. When on, the batch sync /
/// scheduled update-check kicks off a Download for any game whose
/// version moved AND has an auto-fetchable recipe source. Each game's
/// detail-page dropdown can override this.
fn renderAutoUpdateDefaultSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Auto-download updates", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "When sync finds a newer version, automatically download + install it. " ++
            "Only fires from batch sync (Sync All / scheduled update-check), never from a single-game sync. " ++
            "Manual installs without a recipe are skipped — they need a fresh archive to update.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    _ = dvui.checkbox(@src(), &state.auto_update_default, "Auto-download updates on batch sync", .{});
}

/// Minimum session duration (seconds) that counts as a "played" session.
/// 0 = every successful launch counts, regardless of how briefly the
/// game ran. Max 1800 (30 minutes). Evaluated at session close; already-
/// recorded counts_as_played values are not retroactively recalculated.
fn renderMinSessionSecondsSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Minimum play session length", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "A launch only counts as 'played' if the game ran for at least this many seconds. " ++
            "Range: 0 (every launch counts) to 1800 (30 minutes). Default: 60.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Minimum session length to count as 'played' (seconds)", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.min_session_seconds_buf },
        }, .{
            .min_size_content = .{ .w = 60, .h = 24 },
            .gravity_y = 0.5,
        });
        te.deinit();
        const typed = std.mem.sliceTo(&state.min_session_seconds_buf, 0);
        if (std.fmt.parseInt(u32, typed, 10)) |n| {
            const clamped: u32 = std.math.clamp(n, @as(u32, 0), @as(u32, 1800));
            state.min_session_seconds = clamped;
        } else |_| {}
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    dvui.label(@src(), "0 = every successful launch counts as played.", .{}, .{ .color_text = helpTextColor() });
}

/// "Sandbox on launch by default" checkbox. Each game's per-game
/// SandboxOverride wins over this — only `.use_default` consults it.
fn renderSandboxDefaultSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Sandbox on launch", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
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
    components.settingsHelpText(
        "When a download finishes and extracts, automatically run Convert (Ren'Py / RPGM Win→Linux). " ++
            "Requires a recipe with a `convert_linux` block — games without one need manual Convert.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    _ = dvui.checkbox(@src(), &state.auto_convert, "Convert new installs automatically", .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    components.settingsHelpText(
        "After Convert, scan compat recipes and apply any blockers automatically. Re-applies recipes whose bundled version has changed. All compat fixes are reversible via the Fix Compat / Undo UI.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    _ = dvui.checkbox(@src(), &state.auto_apply_compat, "Apply compat fixes automatically after Convert", .{});
}

/// Sync tab — auto-check preferences, refresh backend toggle, the
/// parallelism knobs, and the F95 rate-limit info row.
fn renderSettingsSync(frame: *Frame) void {
    renderAutoCheckSection(frame);
    settingsSectionDivider(2);
    renderRefreshBackendSection(frame);
    settingsSectionDivider(3);
    renderParallelismSection(frame);
    settingsSectionDivider(4);
    dvui.label(@src(), "Network", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    var rl_buf: [32]u8 = undefined;
    const rl = std.fmt.bufPrint(&rl_buf, "{d} ms", .{frame.info.rate_limit_ms}) catch "?";
    var row_id: u32 = 0;
    settingsRow(&row_id, "F95 forum rate limit", rl);
    components.settingsHelpText(
        "Throttle between forum HTTP requests. Image fetches against attachments.f95zone.to (CDN) bypass this limit.",
    );
}

/// Two textEntry rows controlling the parallel-slot pools. Live-edited
/// values are clamped to `[1, MAX_PARALLEL_*]` on each frame so an
/// out-of-range integer never reaches the slot-spawn helpers. Mirrors
/// F95Checker's `max_connections` setting; here we expose both pools
/// independently so users with slow disks can hold images back while
/// keeping metadata refreshes fast.
fn renderParallelismSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Parallelism", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "How many refresh workers run at the same time. Sync workers fetch metadata " ++
            "(/full + cover); image workers fetch screenshots in phase-2. Both pools " ++
            "are capped at 16. Default 4 — matches F95Checker. Higher values speed up " ++
            "library-wide refreshes but increase indexer / forum load proportionally. " ++
            "Changes take effect from the next spawn (already-running workers continue).",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Row 1 — /full + scrape pool
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Sync workers (/full + scrape)", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.max_parallel_sync_buf },
        }, .{
            .min_size_content = .{ .w = 60, .h = 24 },
            .gravity_y = 0.5,
        });
        te.deinit();
        const typed = std.mem.sliceTo(&state.max_parallel_sync_buf, 0);
        if (std.fmt.parseInt(u32, typed, 10)) |n| {
            const clamped: u32 = std.math.clamp(
                n,
                @as(u32, 1),
                @as(u32, @intCast(state_mod.MAX_PARALLEL_SYNC)),
            );
            state.max_parallel_sync = clamped;
        } else |_| {}
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Row 2 — screenshot ImageJob pool
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Image workers (screenshots)", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.max_parallel_image_buf },
        }, .{
            .min_size_content = .{ .w = 60, .h = 24 },
            .gravity_y = 0.5,
        });
        te.deinit();
        const typed = std.mem.sliceTo(&state.max_parallel_image_buf, 0);
        if (std.fmt.parseInt(u32, typed, 10)) |n| {
            const clamped: u32 = std.math.clamp(
                n,
                @as(u32, 1),
                @as(u32, @intCast(state_mod.MAX_PARALLEL_IMAGE)),
            );
            state.max_parallel_image = clamped;
        } else |_| {}
    }
}

/// Refresh-backend toggle. Two-mode strict separation:
///   F95Checker indexer — ALL game metadata comes from
///     `api.f95checker.dev`. Cover + screenshot bytes still come from
///     `attachments.f95zone.to` (CDN; same model F95Checker uses).
///     Auto-update walker disabled (indexer monitors latest updates
///     server-side every 5 min).
///   Scraper — direct f95zone.to thread scrapes. Auto-update walker
///     active. Slower, more forum load, no third-party dependency.
/// Forum-account actions (login, donor DDL, bookmark import) hit
/// f95zone.to in BOTH modes — the indexer doesn't proxy them.
///
/// Layout note: dropdown sits directly under the section header so
/// it's the first interactive widget the eye lands on. Help blurb
/// follows — previously the help text came first and a tall
/// `textLayout` (which captures clicks for text-selection) ate
/// pointer events meant for the dropdown.
fn renderRefreshBackendSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Refresh backend", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Dropdown row — label + dropdown side-by-side, clearly above any
    // longer prose so its hit-test box isn't shadowed by a textLayout.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Source:", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        const backend_labels = &[_][]const u8{ "F95Checker indexer (recommended)", "Direct F95 scraper" };
        var picked: usize = @intFromEnum(state.refresh_backend);
        if (style.dropdown(@src(), backend_labels, .{ .choice = &picked }, .{}, .{
            .min_size_content = .{ .w = 280, .h = 28 },
            .gravity_y = 0.5,
        })) {
            state.refresh_backend = @enumFromInt(picked);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });

    // Short summary, indexer first (matches the recommended default).
    components.settingsHelpText(
        "F95Checker indexer: metadata comes from api.f95checker.dev. " ++
            "Covers + screenshots still come from attachments.f95zone.to (CDN). " ++
            "Auto-update walker is disabled here because the indexer monitors " ++
            "latest-updates server-side every 5 minutes.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    components.settingsHelpText(
        "Direct F95 scraper: every refresh hits f95zone.to thread pages directly. " ++
            "The auto-update walker is active. Slower, more load on the forum, but " ++
            "no third-party dependency.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    components.settingsHelpText(
        "Forum-account actions (login, bookmark import, donor DDL) always hit " ++
            "f95zone.to in either mode — the indexer doesn't proxy authenticated endpoints.",
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

    settingsSectionDivider(6);
    renderEngineReanalyseSection(frame);
}

/// Settings → Library → "Re-detect engines from installs". One-shot
/// button that walks every installed game, peels the wrapper folder,
/// runs the same `detectEngine` + RGSS-marker probe the Convert path
/// uses, and updates `Game.engine` when it differs. Synchronous: cost
/// per game is a handful of `access()` calls, so even a few hundred
/// games stays well under a second on native FS (a few seconds on
/// FUSE NTFS). No background-job machinery needed.
fn renderEngineReanalyseSection(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Engine labels", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "Walks each installed game, probes the on-disk files, and updates the engine label when the bracket-derived guess from F95's title turns out to be wrong. Skips games with no install.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    if (components.iconButton(@src(), "Re-detect engines", entypo.cycle, .{
        .style = .highlight,
        .gravity_y = 0.5,
    })) {
        _ = actions.doReanalyseAllEngines(frame);
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

    if (state.engine_reanalyse_msg_len > 0) {
        const msg = state.engine_reanalyse_msg_buf[0..state.engine_reanalyse_msg_len];
        dvui.labelNoFmt(@src(), msg, .{}, .{
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
    }
}

/// Settings → Library → Import section. Two buttons: F95Checker
/// (SQLite at ~/.config/f95checker/) and xLibrary (JSON at
/// ~/.config/xlibrary/). Each opens a folder picker for the source's
/// games-base-dir, then spawns the worker. A live banner under the
/// buttons surfaces progress while one is running.
/// Same three-button toggle the folder-scan screen uses, surfaced
/// here so the Settings → Library import path can pick its mode
/// too. Shared state via `state.folder_scan_mode` keeps the user's
/// preference consistent across import sources.
fn renderImportModePicker(state: *State) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    dvui.label(@src(), "Transfer mode:", .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    const move_style: dvui.Options = if (state.folder_scan_mode == .move) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Move", .{}, move_style)) {
        state.folder_scan_mode = .move;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
    const copy_style: dvui.Options = if (state.folder_scan_mode == .copy) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Copy (2x disk)", .{}, copy_style)) {
        state.folder_scan_mode = .copy;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
    const link_style: dvui.Options = if (state.folder_scan_mode == .link) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Link in place (safest)", .{}, link_style)) {
        state.folder_scan_mode = .link;
    }
}

fn renderSettingsImport(frame: *Frame) void {
    const state = frame.state;
    dvui.label(@src(), "Import library", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "Bring in games + installs from F95Checker or xLibrary. Existing entries in this library are skipped. " ++
            "Pick a transfer mode below — `Link in place` is safest (no file mutation), `Move` cuts+pastes " ++
            "the games into f69's library_root, `Copy` keeps the originals (2x disk).",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    renderImportModePicker(state);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const running = state.import_job != null;

    {
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
    }

    if (running) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        renderImportBanner(frame);
    }

    // Export — separate row + help text. Surfaced under the import
    // section because it's the natural inverse (and because that's
    // where a user looking for "move my library to F95Checker"
    // would look).
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    components.settingsHelpText(
        "Write f69's library to a F95Checker-shaped db.sqlite3. Game metadata + install paths " ++
            "are exported in F95Checker's modern schema; if a db.sqlite3 already lives at the picked " ++
            "location it's renamed to db.sqlite3.bak-<unix-ts> before the new file is written — never overwritten.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    {
        var export_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer export_row.deinit();
        if (style.button(@src(), "Export to F95Checker DB\u{2026}", .{}, .{
            .min_size_content = .{ .w = 260, .h = style.button_h },
        })) {
            actions.doExportToF95Checker(frame);
        }
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
    dvui.labelNoFmt(@src(), hdr, .{}, .{ .gravity_y = 0.5, .style = .highlight });

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
        dvui.labelNoFmt(@src(), cur_text, .{}, .{
            .color_text = helpTextColor(),
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
    components.settingsHelpText(
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
    dvui.labelNoFmt(@src(), live_msg, .{}, .{
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });

    if (state.aria2_port_msg_len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.labelNoFmt(@src(), state.aria2_port_msg_buf[0..state.aria2_port_msg_len], .{}, .{
            .color_text = style.labelDim(),
        });
    }

    settingsSectionDivider(7);

    // ----- BitTorrent seed-ratio target -----
    dvui.label(@src(), "Seed ratio", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
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
    dvui.labelNoFmt(@src(), live_sr_msg, .{}, .{
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });

    if (state.aria2_seed_ratio_msg_len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.labelNoFmt(@src(), state.aria2_seed_ratio_msg_buf[0..state.aria2_seed_ratio_msg_len], .{}, .{
            .color_text = style.labelDim(),
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
    components.settingsHelpText(
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
    if (components.iconButton(@src(), lbl, entypo.cycle, opts) and !busy) {
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
        const ts = components.formatUtcDateTime(&ts_buf, state.tags_master_fetched_at) catch "—";
        break :blk std.fmt.bufPrint(&info_buf, "{d} tags · last refresh {s}", .{ state.tags_master.len, ts }) catch "cached";
    };
    dvui.labelNoFmt(@src(), info_text, .{}, .{
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });
}

/// Mod-preset management tab. Lists every preset currently loaded
/// (built-ins + user) with id, name, engine hint, source, and a
/// Delete button for user-authored entries. Built-ins are read-only
/// — they ship with the binary and are restored every launch.
fn renderSettingsModPresets(frame: *Frame) void {
    dvui.label(@src(), "Mod-install presets", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
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
        dvui.label(@src(), "User dir:", .{}, .{ .color_text = helpTextColor() });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.labelNoFmt(@src(), frame.info.mod_presets_dir, .{}, .{
            .font = .theme(.mono),
            .color_text = style.labelDim(),
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
                dvui.labelNoFmt(@src(), p.name, .{}, .{ .style = .highlight });
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
                const tag: []const u8 = if (from_user) "[user]" else "[built-in]";
                dvui.labelNoFmt(@src(), tag, .{}, .{
                    .color_text = if (from_user)
                        tokens.toDvui(tokens.active.acc, dvui.Color)
                    else
                        helpTextColor(),
                });
            }

            // Sub-line — id + engine + weight + pattern count.
            var sub_buf: [256]u8 = undefined;
            const engine_txt: []const u8 = if (p.engine_hint) |e| @tagName(e) else "any";
            const sub_txt = std.fmt.bufPrint(&sub_buf, "id: {s}  \u{00B7}  engine: {s}  \u{00B7}  patterns: {d}  \u{00B7}  weight: {d:.1}", .{
                p.id, engine_txt, p.match.requires.len, p.weight,
            }) catch p.id;
            dvui.labelNoFmt(@src(), sub_txt, .{}, .{ .color_text = helpTextColor() });

            if (p.description.len > 0) {
                dvui.labelNoFmt(@src(), p.description, .{}, .{ .color_text = helpTextColor() });
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
    components.settingsHelpText(
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
        dvui.label(@src(), "User dir:", .{}, .{ .color_text = helpTextColor() });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.labelNoFmt(@src(), frame.info.convert_presets_dir, .{}, .{
            .font = .theme(.mono),
            .color_text = style.labelDim(),
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
            dvui.labelNoFmt(@src(), p.name, .{}, .{ .style = .highlight });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
            const tag: []const u8 = if (from_user) "[user]" else "[built-in]";
            dvui.labelNoFmt(@src(), tag, .{}, .{
                .color_text = if (from_user)
                    tokens.toDvui(tokens.active.acc, dvui.Color)
                else
                    helpTextColor(),
            });
        }

        // Sub-line — id + engine + spec variant + weight.
        var sub_buf: [256]u8 = undefined;
        const engine_txt: []const u8 = if (p.engine_hint) |e| @tagName(e) else "any";
        const spec_txt: []const u8 = switch (p.spec) {
            .none => "no-op",
            .renpy => "renpy-sdk-overlay",
            .rpgm => "nwjs-overlay",
            .mkxp_z => "mkxp-z-launcher",
        };
        const sub_txt = std.fmt.bufPrint(&sub_buf, "id: {s}  -  engine: {s}  -  strategy: {s}  -  weight: {d:.1}", .{
            p.id, engine_txt, spec_txt, p.weight,
        }) catch p.id;
        dvui.labelNoFmt(@src(), sub_txt, .{}, .{ .color_text = helpTextColor() });

        if (p.description.len > 0) {
            dvui.labelNoFmt(@src(), p.description, .{}, .{ .color_text = helpTextColor() });
        }
    }
}

/// About tab — diagnostics link + version blurb.
fn renderSettingsAbout(frame: *Frame) void {
    dvui.label(@src(), "Version", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    var row_id: u32 = 0;
    var ver_buf: [48]u8 = undefined;
    const ver = std.fmt.bufPrint(&ver_buf, "f69 v{s}", .{build_options.version}) catch "f69";
    settingsRow(&row_id, "Build", ver);
    components.settingsHelpText("Same string the `--version` flag prints and that ships in the User-Agent.");
    settingsSectionDivider(1);

    renderDiagnosticsLink(frame);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 16 } });
    components.settingsHelpText("f69 — phase 1 alpha. Editable settings land in phase 1.5 (config.toml).");
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
    components.settingsHelpText(
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
    components.settingsHelpText(
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
        const ts = components.formatUtcDateTime(&ts_buf, state.last_update_check_ts) catch "—";
        dvui.label(@src(), "Last check: {s}", .{ts}, .{
            .color_text = style.labelDim(),
        });
    } else {
        dvui.label(@src(), "Last check: never", .{}, .{
            .color_text = style.labelDim(),
        });
    }
}

fn renderDiagnosticsLink(frame: *Frame) void {
    dvui.label(@src(), "Diagnostics", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    dvui.label(@src(), "Engine probes, runtime info, and sandbox state.", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    if (components.iconButton(@src(), "Open diagnostics", entypo.help, .{ .style = .highlight })) {
        frame.state.screen = .diagnostics;
    }
}

fn renderBrowserSection(frame: *Frame) void {
    const state = frame.state;

    dvui.label(@src(), "Browser", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText("Used to open F95 thread links from the detail screen.");
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
        dvui.labelNoFmt(@src(), state.browserMsg(), .{}, .{ .style = .highlight });
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
        dvui.labelNoFmt(@src(), state.loginMsg(), .{}, .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Logged-in: just a logout button. (Pull bookmarks lives on the
    // library top bar — it's a one-click action you do from the main
    // view, not buried under Settings.)
    if (state.login_status == .logged_in) {
        if (components.iconButton(@src(), "Logout", entypo.cross, .{ .style = .err })) {
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
        dvui.labelNoFmt(@src(), state.rpdlMsg(), .{}, .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    if (state.rpdl_status == .logged_in) {
        if (components.iconButton(@src(), "Logout", entypo.cross, .{ .style = .err })) {
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

    dvui.labelNoFmt(@src(), label, .{}, .{
        .min_size_content = .{ .w = 160, .h = 20 },
        .gravity_y = 0.5,
    });
    dvui.labelNoFmt(@src(), value, .{}, .{ .gravity_y = 0.5 });
}
