// Per-game Mods screen — install/remove/import mod archives and
// recipes. Reached from the detail page's "Mods" button.

const std = @import("std");
const dvui = @import("dvui");
const library = @import("library");
const recipe = @import("recipe");
const file_picker = @import("util_file_picker");

const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const mod_job_queue = @import("../mod_job_queue.zig");
const components = @import("../components.zig");

const Frame = types.Frame;
const HELP_TEXT_COLOR = components.HELP_TEXT_COLOR;

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
        dvui.labelNoFmt(@src(), title, .{}, .{ .style = .highlight, .gravity_y = 0.5 });

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

        const counts: owned_types.ModsTabCounts = if (actions.modsPageCache(frame, game)) |c| c.counts else .{};
        if (components.tabButton(modsTabLabel(.installed, "Installed", counts.installed), state.mods_tab == .installed)) state.mods_tab = .installed;
        if (components.tabButton(modsTabLabel(.ready, "Ready", counts.ready), state.mods_tab == .ready)) state.mods_tab = .ready;
        if (components.tabButton(modsTabLabel(.needs_archive, "Needs archive", counts.needs_archive), state.mods_tab == .needs_archive)) state.mods_tab = .needs_archive;
        if (components.tabButton(modsTabLabel(.needs_recipe, "Needs recipe", counts.needs_recipe), state.mods_tab == .needs_recipe)) state.mods_tab = .needs_recipe;
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
        dvui.labelNoFmt(@src(), labels_buf[0], .{}, .{ .gravity_y = 0.5, .style = .highlight });
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
    dvui.labelNoFmt(@src(), status, .{}, .{ .gravity_y = 0.5, .style = .highlight });

    if (h.depth > 1) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        var dbuf: [64]u8 = undefined;
        const dtxt = std.fmt.bufPrint(&dbuf, "(+{d} queued)", .{h.depth - 1}) catch "";
        dvui.labelNoFmt(@src(), dtxt, .{}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
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
    return components.gameByThreadId(frame, tid);
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
    const cache = actions.modsPageCache(frame, game) orelse {
        renderTabEmptyHint(filter);
        return;
    };

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
            dvui.labelNoFmt(@src(), idx_txt, .{}, .{ .style = .highlight, .gravity_y = 0.5 });
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
        dvui.labelNoFmt(@src(), txt, .{}, .{ .gravity_y = 0.5 });
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

        dvui.labelNoFmt(@src(), m.filename, .{}, .{ .style = .highlight });

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
        dvui.labelNoFmt(@src(), meta_txt, .{}, .{ .color_text = HELP_TEXT_COLOR });
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

/// Open the NFDe picker for "add to mod library" — same filter set as
/// `pickAndRegisterModArchive` but without a target recipe; the file
/// lands as an orphan modfile and the user creates a recipe from there.
fn pickAndAddModfile(frame: *Frame, game: *const library.Game) void {
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
    actions.doAddModfile(frame, game, picked);
}
