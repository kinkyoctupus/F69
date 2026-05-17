// Diagnostics screen — read-only state dump for bug reports.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const build_options = @import("build_options");
const installer_mod = @import("installer");

const types = @import("../types.zig");
const components = @import("../components.zig");

const Frame = types.Frame;

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
        if (components.iconOnly(@src(), "back", entypo.chevron_left, .{})) state.screen = .library;
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
            var log_obj = installer_mod.Tracker.load(frame.lib.alloc, frame.io, tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
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
