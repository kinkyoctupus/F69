// spike-04: dvui scale test on the busiest screen.
// Throwaway PoC. Architect's required-before-phase-1 check: prove dvui
// can render the busiest UI surface (1500-game library grid + detail
// modal with 50-mod list + reorder controls) at usable framerate.
//
// If this falls over, we know to swap GUI before sinking weeks. If it
// works, dvui carries the project.
//
// Built against Zig 0.16 + dvui main (commit fa3ce4f).
//
// Usage:
//   zig build spike-dvui -Dgui=true

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3gpu-backend");

const N_GAMES = 1500;
const N_MODS = 50;

const Game = struct {
    id: u64,
    name: []const u8,
    rating: f32, // 0–5
};

const Mod = struct {
    id: u64,
    name: []const u8,
    enabled: bool,
};

var games_buf: [N_GAMES]Game = undefined;
var mods_buf: [N_MODS]Mod = undefined;
var name_storage: [N_GAMES * 32]u8 = undefined;
var mod_name_storage: [N_MODS * 32]u8 = undefined;

var open_game: ?usize = null;
var search_buf = [_]u8{0} ** 64;

pub fn main(main_init: std.process.Init) !void {
    seedFixtures();

    SDLBackend.enableSDLLogging();

    var backend = try SDLBackend.initWindow(.{
        .io = main_init.io,
        .allocator = main_init.gpa,
        .size = .{ .w = 1280.0, .h = 800.0 },
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .vsync = true,
        .title = "f69 spike-04 — dvui busy screen",
        .icon = null,
    });
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), main_init.gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    var interrupted = false;

    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        _ = try backend.addAllEvents(&win);

        const keep = guiFrame();
        if (!keep) break :main_loop;

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn guiFrame() bool {
    // Top-level window scaffolding.
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .style = .window,
        .background = true,
        .expand = .both,
        .name = "root",
    });
    defer root.deinit();

    // Top bar: search + FPS.
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();

        dvui.label(@src(), "Search:", .{}, .{ .gravity_y = 0.5 });
        const te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &search_buf } }, .{
            .min_size_content = .{ .w = 200, .h = 24 },
        });
        te.deinit();

        // Spacer
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (dvui.button(@src(), "Quit", .{}, .{})) return false;
    }

    // Main grid.
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    // 4 cards per row, ~300x100 each. dvui layout via `box` rows.
    const cols: usize = 4;
    var row: usize = 0;
    while (row < N_GAMES) {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        });
        defer hbox.deinit();

        var c: usize = 0;
        while (c < cols and row + c < N_GAMES) : (c += 1) {
            const idx = row + c;
            const g = &games_buf[idx];
            renderGameCard(idx, g);
        }
        row += cols;
    }

    // Detail modal — opened by card click.
    if (open_game) |gi| {
        renderDetailModal(gi);
    }

    return true;
}

fn renderGameCard(idx: usize, g: *const Game) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = g.id,
        .background = true,
        .border = .all(1),
        .corner_radius = .all(4),
        .min_size_content = .{ .w = 280, .h = 90 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .margin = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
    });
    defer card.deinit();

    dvui.label(@src(), "{s}", .{g.name}, .{});

    var rate_buf: [32]u8 = undefined;
    const rate_str = std.fmt.bufPrint(&rate_buf, "★ {d:.1}", .{g.rating}) catch "★ ?";
    dvui.label(@src(), "{s}", .{rate_str}, .{});

    if (dvui.button(@src(), "Open", .{}, .{ .id_extra = g.id })) {
        open_game = idx;
    }
}

fn renderDetailModal(game_idx: usize) void {
    const g = &games_buf[game_idx];

    var fw = dvui.floatingWindow(@src(), .{}, .{
        .min_size_content = .{ .w = 600, .h = 500 },
    });
    defer fw.deinit();

    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer hdr.deinit();

        dvui.label(@src(), "{s}", .{g.name}, .{});
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dvui.button(@src(), "Close", .{}, .{})) {
            open_game = null;
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var rb = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        });
        defer rb.deinit();

        var rate_buf: [32]u8 = undefined;
        const rate_str = std.fmt.bufPrint(&rate_buf, "rating: ★ {d:.1}", .{g.rating}) catch "rating: ?";
        dvui.label(@src(), "{s}", .{rate_str}, .{});
    }

    dvui.label(@src(), "Mods (drag-style reorder via ↑/↓):", .{}, .{
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 4 },
    });

    var mod_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer mod_scroll.deinit();

    for (mods_buf[0..], 0..) |*m, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = m.id,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        });
        defer row.deinit();

        // up
        if (dvui.button(@src(), "↑", .{}, .{ .id_extra = m.id })) {
            if (i > 0) std.mem.swap(Mod, &mods_buf[i], &mods_buf[i - 1]);
        }
        // down
        if (dvui.button(@src(), "↓", .{}, .{ .id_extra = m.id })) {
            if (i + 1 < N_MODS) std.mem.swap(Mod, &mods_buf[i], &mods_buf[i + 1]);
        }

        // enabled checkbox
        _ = dvui.checkbox(@src(), &m.enabled, "", .{ .id_extra = m.id });

        dvui.label(@src(), "{s}", .{m.name}, .{ .gravity_y = 0.5 });
    }
}

// ============================================================
//  fixtures
// ============================================================

fn seedFixtures() void {
    // Seed a deterministic PRNG so games / mods look stable across frames.
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const r = prng.random();

    var name_off: usize = 0;
    for (games_buf[0..], 0..) |*g, i| {
        const slice = name_storage[name_off..][0..32];
        const written = std.fmt.bufPrint(slice, "Game #{d:0>4} {x}", .{ i, r.int(u16) }) catch "?";
        g.* = .{
            .id = i,
            .name = written,
            .rating = r.float(f32) * 5.0,
        };
        name_off += written.len + 1;
    }

    var mn_off: usize = 0;
    for (mods_buf[0..], 0..) |*m, i| {
        const slice = mod_name_storage[mn_off..][0..32];
        const written = std.fmt.bufPrint(slice, "Mod #{d:0>2} {x}", .{ i, r.int(u16) }) catch "?";
        m.* = .{
            .id = @as(u64, i) + 1_000_000,
            .name = written,
            .enabled = r.boolean(),
        };
        mn_off += written.len + 1;
    }

}
