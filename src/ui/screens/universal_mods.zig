//! Universal (engine-wide) mods management screen (feature C). Add a modfile
//! for an engine; list/delete registered universal mods. Per-game opt-out
//! lives on the game's detail page. Reached from the library top bar.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");

const types = @import("../types.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");
const comp = @import("ui_comp");

const Frame = types.Frame;

const ENGINE_LABELS: [actions.universalModEngines.len][]const u8 = blk: {
    var arr: [actions.universalModEngines.len][]const u8 = undefined;
    for (actions.universalModEngines, 0..) |e, i| arr[i] = components.engineShortLabel(e);
    break :blk arr;
};

pub fn universalModsScreen(frame: *Frame) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Universal Mods", .{}, .{ .gravity_y = 0.5, .style = .highlight });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    components.settingsHelpText("Mods added here apply to every game of the chosen engine. Turn one off for a specific game from that game's detail page.");
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    // ----- add form -----
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Name", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 50, .h = 1 } });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.universal_mod_name_buf },
            .placeholder = "(optional — defaults to filename)",
        }, .{ .min_size_content = .{ .w = 240, .h = 28 }, .gravity_y = 0.5 });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        dvui.label(@src(), "Engine", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        _ = style.dropdown(@src(), &ENGINE_LABELS, .{ .choice = &state.universal_mod_engine_idx }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 140, .h = 26 },
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        if (components.iconButton(@src(), "Add modfile…", entypo.plus, .{ .style = .highlight, .gravity_y = 0.5 })) {
            actions.doAddUniversalMod(frame, actions.universalModEngineForIndex(state.universal_mod_engine_idx));
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 14 } });

    // ----- list -----
    const mods_opt: ?[]library.UniversalMod = frame.lib.listUniversalMods(null) catch null;
    defer if (mods_opt) |m| frame.lib.freeUniversalMods(m);
    const mods = mods_opt orelse &.{};
    if (mods.len == 0) {
        components.emptyState(entypo.tools, "No universal mods yet", "Add a mod above to apply it to every game of an engine.");
        return true;
    }

    var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer list.deinit();

    var pending_delete: ?struct { id: i64, path: []const u8 } = null;
    for (mods) |m| {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @as(u64, @bitCast(m.id)),
            .expand = .horizontal,
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
            .color_fill = style.cardFill(),
            .color_border = style.borderColor(),
        });
        defer r.deinit();

        const fill = components.engineBadgeColor(m.engine);
        comp.chip(@src(), .{
            .label = components.engineShortLabel(m.engine),
            .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
            .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
            .scale = 0.75,
        }, .{
            .id_extra = @as(u64, @bitCast(m.id)),
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 80, .h = 1 },
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .corner_radius = .all(3),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        dvui.label(@src(), "{s}", .{m.name}, .{ .gravity_y = 0.5, .style = .highlight });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Apply to games", entypo.cycle, .{ .id_extra = @as(u64, @bitCast(m.id)), .style = .highlight })) {
            actions.applyUniversalMod(frame, m.id, m.engine, m.modfile_path);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (components.iconButton(@src(), "Delete", entypo.trash, .{ .id_extra = @as(u64, @bitCast(m.id)), .style = .err })) {
            pending_delete = .{ .id = m.id, .path = m.modfile_path };
        }
    }
    if (pending_delete) |d| actions.doDeleteUniversalMod(frame, d.id, d.path);

    return true;
}
