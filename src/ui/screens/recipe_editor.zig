// Recipe editor screen — full-page replacement for the modal wizard.
// Stacked panels for metadata / install steps / relations / save.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");
const recipe = @import("recipe");
const installer_mod = @import("installer");

const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");

const Frame = types.Frame;
const HELP_TEXT_COLOR = components.HELP_TEXT_COLOR;

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
    const game_opt = components.gameByThreadId(frame, w_ptr.game_thread_id);
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
        dvui.labelNoFmt(@src(), title, .{}, .{ .style = .highlight, .gravity_y = 0.5 });
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
    dvui.labelNoFmt(@src(), title, .{}, .{
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

fn renderWizardMeta(w: *state_mod.WizardState) void {
    dvui.label(@src(), "Mod metadata. Required: Name, Version, Targets game version.", .{}, .{ .color_text = HELP_TEXT_COLOR });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    wizardTextRow(@src(), "Name", &w.name_buf);
    wizardTextRow(@src(), "Version", &w.version_buf);
    wizardTextRow(@src(), "F95 post URL", &w.post_url_buf);

    // Target-game-version: dropdown over installed builds. The wizard
    // refuses to open when there are no installs (in actions/mods.zig), so
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
    dvui.labelNoFmt(@src(), label, .{}, .{ .min_size_content = .{ .w = 160, .h = 24 }, .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
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
    dvui.labelNoFmt(@src(), label, .{}, .{ .min_size_content = .{ .w = 160, .h = 24 }, .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });
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
        const size_txt = components.humanBytes(&size_buf, total_bytes);
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "+ Adds {d} new file(s)  ({s})", .{ add_n, size_txt }) catch "+ Adds files";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0x4F, .g = 0xC3, .b = 0x6F } });
    }
    if (ow_van > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "~ Overwrites {d} vanilla file(s)", .{ow_van}) catch "~ Overwrites vanilla";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0xE0, .g = 0xC0, .b = 0x70 } });
    }
    if (ow_mod > 0) {
        var buf: [160]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "\u{26A0} Conflicts: {d} file(s) already owned by another mod", .{ow_mod}) catch "Conflicts with another mod";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0xFF, .g = 0x80, .b = 0x80 } });
    }
    if (mode_n > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "* Marks {d} file(s) as runnable", .{mode_n}) catch "Marks file(s) runnable";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = HELP_TEXT_COLOR });
    }
    if (del_n > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "- Removes {d} file(s)", .{del_n}) catch "Removes file(s)";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0xE0, .g = 0xC0, .b = 0x70 } });
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
            dvui.labelNoFmt(@src(), d.msg, .{}, .{ .color_text = color, .id_extra = std.hash.Wyhash.hash(0, d.msg) });
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
        dvui.labelNoFmt(@src(), hdr, .{}, .{ .style = .highlight, .font = .theme(.mono) });
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
        dvui.labelNoFmt(@src(), line, .{}, .{
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
    dvui.labelNoFmt(@src(), line, .{}, .{
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
    return components.humanBytes(&Static.buf, n);
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
        dvui.labelNoFmt(@src(), idx_txt, .{}, .{ .gravity_y = 0.5, .color_text = HELP_TEXT_COLOR });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Remove", .{}, .{ .style = .err })) {
            actions.wizardRemoveBlock(frame, idx);
            return;
        }
    }

    // ---- one-line help text ----
    dvui.labelNoFmt(@src(), blockKindHelp(b.kind), .{}, .{ .color_text = HELP_TEXT_COLOR });

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
            dvui.labelNoFmt(@src(), d.msg, .{}, .{
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
            const size_txt = components.humanBytes(&size_buf, imp.bytes_written);
            var buf: [128]u8 = undefined;
            const mod_part: []const u8 = if (imp.files_modified > 0) blk: {
                var mb: [48]u8 = undefined;
                break :blk std.fmt.bufPrint(&mb, "  ({d} overwrite existing)", .{imp.files_modified}) catch "";
            } else "";
            const line = std.fmt.bufPrint(&buf, "Will write {d} file(s), {s}{s}", .{
                imp.files_written, size_txt, mod_part,
            }) catch "";
            dvui.labelNoFmt(@src(), line, .{}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
        .move => {
            if (imp.files_written == 0) return;
            dvui.label(@src(), "Will relocate 1 file.", .{}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
        .delete => {
            if (imp.deletions == 0) return;
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "Will remove {d} path(s).", .{imp.deletions}) catch "";
            dvui.labelNoFmt(@src(), line, .{}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
        },
        .chmod_x => {
            if (imp.mode_changes == 0) return;
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "Will mark {d} file(s) runnable.", .{imp.mode_changes}) catch "";
            dvui.labelNoFmt(@src(), line, .{}, .{ .color_text = .{ .r = 0xC0, .g = 0x90, .b = 0xA8 } });
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
    dvui.labelNoFmt(@src(), help, .{}, .{ .color_text = HELP_TEXT_COLOR });
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
