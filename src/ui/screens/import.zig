// Import screens — three separate dialogs:
//
//   - `importUrlsScreen`       paste F95 thread URLs/IDs
//   - `importF95CheckerScreen` scan an F95Checker / xLibrary games dir
//   - `importFolderScreen`     scan any flat games directory
//
// The two folder-scan screens share the same scan/resolve backend but
// carry different intro copy so the user can pick the path that
// matches what they actually have on disk. All three wrap their body
// in `dvui.scrollArea` so cramped windows scroll instead of clipping.

const std = @import("std");
const dvui = @import("dvui");
const library = @import("library");
const f95 = @import("f95");

const types = @import("../types.zig");
const style = @import("../style.zig");
const actions = @import("../actions.zig");
const state_mod = @import("../state.zig");

const Frame = types.Frame;
const State = state_mod.State;

// ============================================================
//  Screen 1 — paste F95 thread URLs / IDs
// ============================================================

pub fn importUrlsScreen(frame: *Frame) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (style.button(@src(), "← Back", .{}, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Import by F95 URL / ID", .{}, .{ .gravity_y = 0.5, .style = .highlight });
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

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    dvui.label(@src(), "Paste F95Zone thread URLs or numeric IDs (one per line):", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.import_buf },
        .multiline = true,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 600, .h = 300 },
    });
    te.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    if (!state.import_msg.isEmpty()) {
        dvui.labelNoFmt(@src(), state.importMsg(), .{}, .{ .style = .highlight });
    } else {
        dvui.label(@src(), "Imported games show up as \"(unsynced)\". Click Sync on each to populate.", .{}, .{});
    }

    return true;
}

// ============================================================
//  Screen 2 — F95Checker / xLibrary folder scan
// ============================================================

pub fn importF95CheckerScreen(frame: *Frame) !bool {
    return renderFolderScanScreen(frame, .{
        .title = "Import from F95Checker / xLibrary",
        .intro =
        "Point at an F95Checker or xLibrary games directory. These tools store " ++
            "each game as a subfolder using the F95Zone thread naming convention " ++
            "(\"Name vX.Y\", \"Name [vX.Y]\", or \"Name-version-pc-final\"). " ++
            "f69 parses each folder for a name + version, then asks you to confirm " ++
            "the F95 thread for any entry it couldn't link automatically.",
        .placeholder = "/path/to/F95Checker/games  or  /path/to/xLibrary",
    });
}

// ============================================================
//  Screen 3 — generic folder scan
// ============================================================

pub fn importFolderScreen(frame: *Frame) !bool {
    return renderFolderScanScreen(frame, .{
        .title = "Import from a folder",
        .intro =
        "Point at any directory of installed games. Each subfolder is parsed for " ++
            "a name + version using common patterns. For each entry you'll then " ++
            "paste an F95Zone URL or add it as a custom row.",
        .placeholder = "/path/to/games",
    });
}

// ============================================================
//  shared folder-scan rendering
// ============================================================

const FolderScanCopy = struct {
    title: []const u8,
    intro: []const u8,
    placeholder: []const u8,
};

fn renderFolderScanScreen(frame: *Frame, copy: FolderScanCopy) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (style.button(@src(), "← Back", .{}, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.labelNoFmt(@src(), copy.title, .{}, .{ .gravity_y = 0.5, .style = .highlight });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    dvui.labelNoFmt(@src(), copy.intro, .{}, .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const tip_text: []const u8 = switch (state.folder_scan_mode) {
        .move =>
        "Tip — Move mode: each imported game's folder is cut+pasted into f69's library root. " ++
            "Same-filesystem moves are a near-instant rename; cross-filesystem moves fall back " ++
            "to copy-verify-delete (peaks at 2x disk during the copy, then frees the source).",
        .copy =>
        "Warning — Copy mode: each imported game's folder is duplicated into f69's library root. " ++
            "Final disk use is 2x. Pick Move below unless you really need to keep the originals.",
    };
    dvui.labelNoFmt(
        @src(),
        tip_text,
        .{},
        .{ .expand = .horizontal, .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 } },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.folder_scan_path_buf },
            .placeholder = copy.placeholder,
        }, .{ .expand = .horizontal, .min_size_content = .{ .w = 400, .h = 24 } });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Scan", .{}, .{ .style = .highlight })) {
            actions.doFolderScan(frame, state.folderScanPathSlice());
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        if (style.button(@src(), "Clear", .{}, .{})) {
            actions.freeFolderScan(state, frame.lib.alloc);
            state.setFolderScanMsg("");
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    renderFolderScanModeToggle(state);

    if (!state.folder_scan_msg.isEmpty()) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        dvui.labelNoFmt(@src(), state.folderScanMsg(), .{}, .{});
    }

    if (actions.folderScanBundle(state)) |bundle| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        renderScanResults(frame, bundle);
    }

    renderResolvePopup(frame);

    return true;
}

fn renderScanResults(frame: *Frame, bundle: anytype) void {
    const state = frame.state;
    // One row per parsed entry. Two actions per row: "Custom" (commit
    // with the synthetic id) and "F95 URL…" (open the resolve popup).
    for (bundle.games, 0..) |g, idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @intCast(idx),
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

        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = @intCast(idx),
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            defer col.deinit();
            dvui.labelNoFmt(@src(), g.name, .{}, .{ .style = .highlight });
            if (g.version) |v| {
                var vbuf: [80]u8 = undefined;
                const vmsg = std.fmt.bufPrint(&vbuf, "version: {s}", .{v}) catch v;
                dvui.labelNoFmt(@src(), vmsg, .{}, .{});
            } else {
                dvui.label(@src(), "version: (not detected)", .{}, .{});
            }
        }

        if (style.button(@src(), "Custom", .{}, .{ .id_extra = @intCast(idx) })) {
            actions.resolveFolderEntry(frame, idx, null);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        if (style.button(@src(), "F95 URL…", .{}, .{ .id_extra = @intCast(idx), .style = .highlight })) {
            state.folder_resolve_idx = idx;
            @memset(&state.folder_resolve_url_buf, 0);
        }
    }
}

/// Two-button mutually-exclusive toggle. The selected mode renders with
/// `.style = .highlight`; the other is plain. Plain `dvui.checkbox`
/// wouldn't communicate the "either/or" intent and the tip text above
/// already explains the trade-off.
fn renderFolderScanModeToggle(state: *State) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    dvui.label(@src(), "Transfer mode:", .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    const move_style: dvui.Options = if (state.folder_scan_mode == .move) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Move (cut+paste)", .{}, move_style)) {
        state.folder_scan_mode = .move;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
    const copy_style: dvui.Options = if (state.folder_scan_mode == .copy) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Copy (keep originals — 2x disk)", .{}, copy_style)) {
        state.folder_scan_mode = .copy;
    }
}

fn renderResolvePopup(frame: *Frame) void {
    const state = frame.state;
    const idx = state.folder_resolve_idx orelse return;
    const bundle = actions.folderScanBundle(state) orelse {
        state.folder_resolve_idx = null;
        return;
    };
    if (idx >= bundle.games.len) {
        state.folder_resolve_idx = null;
        return;
    }
    const game = bundle.games[idx];

    var open: bool = true;
    var win = dvui.floatingWindow(@src(), .{ .open_flag = &open }, .{
        .min_size_content = .{ .w = 480, .h = 240 },
    });
    defer {
        win.deinit();
        if (!open) state.folder_resolve_idx = null;
    }
    _ = dvui.windowHeader("Link to F95Zone thread", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
    });
    defer body.deinit();

    dvui.labelNoFmt(@src(), game.name, .{}, .{ .style = .highlight });
    if (game.version) |v| {
        var vbuf: [80]u8 = undefined;
        const vmsg = std.fmt.bufPrint(&vbuf, "version: {s}", .{v}) catch v;
        dvui.labelNoFmt(@src(), vmsg, .{}, .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    dvui.label(@src(), "Paste an F95Zone thread URL or numeric id:", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.folder_resolve_url_buf },
        .placeholder = "https://f95zone.to/threads/…/  or  12345",
    }, .{ .expand = .horizontal, .min_size_content = .{ .w = 300, .h = 24 } });
    te.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    dvui.label(
        @src(),
        "(F95 search-by-name coming in a follow-up — for now, look up the thread manually and paste the URL.)",
        .{},
        .{ .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 } },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        if (style.button(@src(), "Save & import", .{}, .{ .style = .highlight })) {
            const url_input = state.folderResolveUrlSlice();
            if (actions.parseF95ThreadInput(url_input)) |tid| {
                actions.resolveFolderEntry(frame, idx, tid);
            } else {
                state.setFolderScanMsg("Couldn't parse that F95 URL / id — try a full thread URL.");
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Add as custom instead", .{}, .{})) {
            actions.resolveFolderEntry(frame, idx, null);
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Cancel", .{}, .{})) {
            state.folder_resolve_idx = null;
        }
    }
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
