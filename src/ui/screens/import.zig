// Import screen — paste F95 thread URLs / IDs, bulk-create rows.

const std = @import("std");
const dvui = @import("dvui");
const library = @import("library");
const f95 = @import("f95");

const types = @import("../types.zig");
const style = @import("../style.zig");

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
