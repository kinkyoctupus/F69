// Import screen — paste F95 thread URLs / IDs, bulk-create rows.

const std = @import("std");
const dvui = @import("dvui");
const library = @import("library");
const f95 = @import("f95");

const types = @import("../types.zig");
const style = @import("../style.zig");
const actions = @import("../actions.zig");

const Frame = types.Frame;

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
        dvui.labelNoFmt(@src(), state.importMsg(), .{}, .{ .style = .highlight });
    } else {
        dvui.label(@src(), "Imported games show up as \"(unsynced)\". Click Sync on each to populate.", .{}, .{});
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 24 } });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    renderFolderScanSection(frame);

    // Per-entry resolution popup — opens when the user clicks "F95
    // URL…" on a row. Sits on top of the scan list so the user can
    // see the parsed name + version while pasting.
    renderResolvePopup(frame);

    return true;
}

// ============================================================
//  folder-scan import section — scan a games folder, review parsed
//  entries, commit each as either a real F95 thread or a "custom"
//  (synthetic-id) row.
// ============================================================

fn renderFolderScanSection(frame: *Frame) void {
    const state = frame.state;

    dvui.label(@src(), "Or import from an existing games folder", .{}, .{ .style = .highlight });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    dvui.label(
        @src(),
        "Point at a directory of installed games (subfolders like \"AHouseInTheRift-0.8.09r1-pc\"). " ++
            "f69 parses each folder name for a game name + version. For each entry you'll then paste " ++
            "an F95Zone URL or add it as a custom row.",
        .{},
        .{ .expand = .horizontal },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    dvui.label(
        @src(),
        "Tip: each imported game's folder is MOVED into f69's library root. " ++
            "If the source folder lives on the same filesystem as the library, " ++
            "the move is a near-instant rename. Cross-filesystem moves fall back " ++
            "to a copy-verify-delete pass (much slower for large games).",
        .{},
        .{ .expand = .horizontal, .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 } },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.folder_scan_path_buf },
            .placeholder = "/path/to/games",
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

    if (!state.folder_scan_msg.isEmpty()) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        dvui.labelNoFmt(@src(), state.folderScanMsg(), .{}, .{});
    }

    const bundle = actions.folderScanBundle(state) orelse return;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

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

        // Name + version block. Expands to fill row width.
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
