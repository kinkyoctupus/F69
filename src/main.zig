// f69 entry point. Resolves `data_root` (portable layout — `<exe_dir>/data/`
// by default, override via `F69_DATA_DIR`), opens the Library SQLite DB,
// wires services and the aria2 RPC daemon, then runs the UI loop.
//
// `pub fn main(init: std.process.Init)` is Zig 0.16's main signature when
// you want access to the process Init context (allocator, io, args, env).

const std = @import("std");
const builtin = @import("builtin");

const library = @import("library");
const f95 = @import("f95");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox_mod = @import("sandbox");
const convert_mod = @import("convert");
const compat_mod = @import("compat");
const ui = @import("ui");

/// Override the stdlib's default log level so `log.debug(...)` actually
/// reaches stderr. While we're still in phase-1 alpha, debug-level
/// chatter is the easier bug-finding path; ratcheted down to .info
/// once everything stabilizes.
///
/// `logFn` is the per-call filter — `log_scope_levels` would be the
/// idiomatic knob, but dvui's sdl3gpu backend iterates that slice in
/// a way that requires every element to be comptime-known, so adding
/// even one entry trips a Zig comptime error in the backend. The
/// custom logFn does the same job at runtime without touching dvui.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = customLogFn,
};

/// Filter `dvui`-scope debug noise (e.g. its per-frame
/// `borderAndBackground … forcing background` trace) while keeping
/// everything else at the level configured above. Other scopes
/// (including dvui at .info/.warn/.err) fall through to the default
/// log implementation.
fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .dvui and level == .debug) return;
    std.log.defaultLog(level, scope, format, args);
}

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // **Portable data layout.** Everything lives under a single
    // `data_root`. Default: `<dir-of-this-exe>/data/`. Override with
    // the `F69_DATA_DIR` env var. Drop the f69 folder anywhere on disk
    // and it carries DB + recipes + library + caches + saves all
    // together.
    const data_root = try resolveDataRoot(gpa, init.io, init.minimal.environ);
    defer gpa.free(data_root);
    try std.Io.Dir.cwd().createDirPath(init.io, data_root);
    log.info("data root {s}", .{data_root});

    // DB at `<data_root>/f69.db`.
    const db_path = try std.fmt.allocPrint(gpa, "{s}/f69.db", .{data_root});
    defer gpa.free(db_path);

    // Cover-image cache at `<data_root>/covers/`.
    const covers_dir = try std.fmt.allocPrint(gpa, "{s}/covers", .{data_root});
    defer gpa.free(covers_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, covers_dir);
    sweepTmpCovers(init.io, covers_dir) catch {};

    // Per-game installs at `<data_root>/library/<thread_id>/<version>/`.
    const library_root = try std.fmt.allocPrint(gpa, "{s}/library", .{data_root});
    defer gpa.free(library_root);
    try std.Io.Dir.cwd().createDirPath(init.io, library_root);

    log.info("db        {s}", .{db_path});
    log.info("covers    {s}", .{covers_dir});
    log.info("library   {s}", .{library_root});

    var lib = try library.Library.open(gpa, db_path);
    defer lib.close();


    const rate_limit_ms: u64 = 1500;
    var f95_client = f95.Client.init(gpa, init.io, rate_limit_ms);
    defer f95_client.deinit();
    var f95_service = f95.Service.init(gpa, &f95_client);

    // Cookie persistence at `<data_root>/f95_cookie`.
    const cookie_path = try std.fmt.allocPrint(gpa, "{s}/f95_cookie", .{data_root});
    defer gpa.free(cookie_path);
    log.info("cookie    {s}", .{cookie_path});

    const recipes_dir = try std.fmt.allocPrint(gpa, "{s}/recipes", .{data_root});
    defer gpa.free(recipes_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, recipes_dir);
    log.info("recipes   {s}", .{recipes_dir});

    const mod_archives_dir = try std.fmt.allocPrint(gpa, "{s}/mod-archives", .{data_root});
    defer gpa.free(mod_archives_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, mod_archives_dir);
    log.info("mods      {s}", .{mod_archives_dir});

    // User-authored mod-install presets at `<data_root>/mod-presets/`.
    // Built-in presets ship embedded in the binary; this dir is for
    // user additions / overrides. Discovered + merged at preset
    // detection time.
    const mod_presets_dir = try std.fmt.allocPrint(gpa, "{s}/mod-presets", .{data_root});
    defer gpa.free(mod_presets_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, mod_presets_dir);
    log.info("presets   {s}", .{mod_presets_dir});

    // User-authored convert-strategy presets at
    // `<data_root>/convert-presets/`. Built-ins ship embedded; this
    // dir lets users add custom Win→Linux conversion variants.
    const convert_presets_dir = try std.fmt.allocPrint(gpa, "{s}/convert-presets", .{data_root});
    defer gpa.free(convert_presets_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, convert_presets_dir);
    log.info("convert   {s}", .{convert_presets_dir});
    if (loadCookie(init.io, gpa, cookie_path)) |cookie_opt| {
        if (cookie_opt) |cookie| {
            defer gpa.free(cookie);
            log.info("loaded stored F95 cookie ({d} bytes)", .{cookie.len});
            f95_client.setCookie(cookie) catch |e| {
                log.warn("failed to apply stored cookie: {s}", .{@errorName(e)});
            };
        } else {
            log.debug("no stored cookie", .{});
        }
    } else |e| {
        log.warn("cookie load failed: {s}", .{@errorName(e)});
    }

    // aria2 RPC port — `<data_root>/aria2_port`, default 0 (random
    // ephemeral). Settings → Downloads exposes a textEntry that writes
    // here; changes take effect on the next launch (the daemon binds
    // at spawn).
    const aria2_port_path = try std.fmt.allocPrint(gpa, "{s}/aria2_port", .{data_root});
    defer gpa.free(aria2_port_path);
    const initial_aria2_port: u16 = loadU16(init.io, gpa, aria2_port_path) catch 0;
    log.info("aria2 port {d} ({s})", .{ initial_aria2_port, if (initial_aria2_port == 0) "random" else "user-configured" });

    // aria2 seed ratio — `<data_root>/aria2_seed_ratio`. Floor 2.0,
    // default 5.0. Daemon-wide --seed-ratio flag wires from here.
    // Changes take effect on the next launch.
    const aria2_seed_ratio_path = try std.fmt.allocPrint(gpa, "{s}/aria2_seed_ratio", .{data_root});
    defer gpa.free(aria2_seed_ratio_path);
    const initial_aria2_seed_ratio: f32 = loadSeedRatio(init.io, gpa, aria2_seed_ratio_path) catch 5.0;
    log.info("aria2 seed_ratio {d:.2}", .{initial_aria2_seed_ratio});

    // Downloads layout — split between `direct/` (plain HTTP) and
    // `torrents/` (BitTorrent). aria2's daemon-wide `--dir=` points at
    // `direct/`; `enqueueTorrent` overrides per-call to `torrents/`.
    // Kept under `<data_root>/downloads/` so the user can wipe both
    // categories with one rm -rf and never collides with installed
    // games under `<data_root>/library/`.
    const downloads_root = try std.fmt.allocPrint(gpa, "{s}/downloads", .{data_root});
    defer gpa.free(downloads_root);
    const downloads_direct_root = try std.fmt.allocPrint(gpa, "{s}/direct", .{downloads_root});
    defer gpa.free(downloads_direct_root);
    const downloads_torrents_root = try std.fmt.allocPrint(gpa, "{s}/torrents", .{downloads_root});
    defer gpa.free(downloads_torrents_root);
    try std.Io.Dir.cwd().createDirPath(init.io, downloads_direct_root);
    try std.Io.Dir.cwd().createDirPath(init.io, downloads_torrents_root);
    log.info("downloads direct={s} torrents={s}", .{ downloads_direct_root, downloads_torrents_root });

    var dl_mgr = downloads.Manager.init(
        gpa,
        init.io,
        library_root,
        library_root,
        downloads_direct_root,
        downloads_torrents_root,
        "aria2c",
        initial_aria2_port,
        initial_aria2_seed_ratio,
    );
    defer dl_mgr.deinit();

    // Cross-restart persistence for in-flight downloads. Two files in
    // `<data_root>/cache/downloads/`:
    //   - aria2.session           — aria2's own session file.
    //   - manager_jobs.json       — our id ↔ gid ↔ url mapping.
    // SIGKILL-safe: aria2 checkpoints every 60s, manager_jobs writes
    // atomically on every enqueue/remove.
    const dl_cache_dir = try std.fmt.allocPrint(gpa, "{s}/cache/downloads", .{data_root});
    defer gpa.free(dl_cache_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dl_cache_dir);
    const aria2_session_path = try std.fmt.allocPrint(gpa, "{s}/aria2.session", .{dl_cache_dir});
    defer gpa.free(aria2_session_path);
    const manager_jobs_path = try std.fmt.allocPrint(gpa, "{s}/manager_jobs.json", .{dl_cache_dir});
    defer gpa.free(manager_jobs_path);
    log.info("dl cache  {s}", .{dl_cache_dir});
    dl_mgr.enablePersistence(manager_jobs_path, aria2_session_path);
    // Eagerly spawn aria2 if we have anything to resume. Aria2's own
    // --input-file=<session> reads the persisted BT/HTTP state at
    // launch, so downloads that were mid-leech and torrents that
    // were mid-seed pick right back up. First-run users skip the
    // spawn — `resumeFromDisk` sees no jobs / no session and bails.
    dl_mgr.resumeFromDisk() catch |e| {
        log.warn("download manager resume failed: {s}", .{@errorName(e)});
    };

    // Recipe repository — points at `<config>/f69/recipes/`. UI's
    // per-game Download button calls `findGameByThread` against this.
    var recipe_repo = recipe.Repo.init(gpa, init.io, recipes_dir);
    defer recipe_repo.deinit();

    // Sandbox backend — bwrap on Linux, sandboxie on Windows, none
    // otherwise. Failures fall through to `.none` (Launch then surfaces
    // a clear backend-unavailable error). HostInfo carries the display
    // / audio / fontconfig env snapshot.
    var sandbox = sandbox_mod.pickBackend(gpa, init.io, init.minimal.environ);
    defer sandbox.deinit();
    log.info("sandbox   backend={s}", .{sandbox.backendName()});

    // Permanent `NoSandbox` instance used when the user has opted out
    // of sandboxing (per-game `.never`, or `.use_default` with the
    // global toggle off). Constructed once so the Launch button can
    // route either through the primary backend or this without any
    // per-launch allocation.
    var host_launcher = sandbox_mod.NoSandbox.init(init.io, init.minimal.environ);

    // Convert service — Ren'Py / RPGM Win→Linux. SDK cache lands at
    // <data_root>/cache/convert/sdks/. Distro detection runs once
    // at startup.
    const convert_cache_root = try std.fmt.allocPrint(gpa, "{s}/cache", .{data_root});
    defer gpa.free(convert_cache_root);
    var convert_svc = try convert_mod.Service.init(gpa, init.io, convert_cache_root);
    defer convert_svc.deinit();
    log.info("convert   distro={s} cache={s}/convert/sdks", .{ @tagName(convert_svc.distro), convert_cache_root });

    // Compat service — host-compatibility recipes (e.g. Ren'Py SDL
    // FHS-libs on NixOS). Bundled recipes are `@embedFile`d at
    // compile time; user overrides live in
    // `<data_root>/compat-recipes/`. Resources (the FHS lib bundles
    // we ship for compat fixes) land at
    // `<data_root>/compat-resources/<id>/`. Backups go to
    // `<data_root>/compat-backups/<install_id>/`.
    const compat_recipes_dir = try std.fmt.allocPrint(gpa, "{s}/compat-recipes", .{data_root});
    defer gpa.free(compat_recipes_dir);
    std.Io.Dir.cwd().createDirPath(init.io, compat_recipes_dir) catch {};
    const compat_resources_dir = try std.fmt.allocPrint(gpa, "{s}/compat-resources", .{data_root});
    defer gpa.free(compat_resources_dir);
    std.Io.Dir.cwd().createDirPath(init.io, compat_resources_dir) catch {};
    const compat_backups_dir = try std.fmt.allocPrint(gpa, "{s}/compat-backups", .{data_root});
    defer gpa.free(compat_backups_dir);
    std.Io.Dir.cwd().createDirPath(init.io, compat_backups_dir) catch {};

    var compat_host = compat_mod.probeHost(gpa, init.io) catch |e| {
        log.err("compat host probe failed: {s}", .{@errorName(e)});
        return e;
    };
    defer compat_host.deinit();
    log.info(
        "compat    pm={s} nixos={} sonames={s}",
        .{ @tagName(compat_host.package_manager), compat_host.is_nixos, compat_host.soname_search },
    );

    var compat_repo = compat_mod.Repo.init(gpa, init.io, compat_recipes_dir);
    defer compat_repo.deinit();
    compat_repo.load() catch |e| {
        log.warn("compat repo load failed: {s}", .{@errorName(e)});
    };

    var compat_resolver = compat_mod.Resolver.init(gpa, init.io, compat_resources_dir);
    var compat_backups = compat_mod.BackupStore.init(gpa, init.io, compat_backups_dir);
    var compat_svc = compat_mod.Service.init(gpa, init.io, &compat_repo, &compat_host, &compat_resolver, &compat_backups);

    const host_xdg_runtime = init.minimal.environ.getAlloc(gpa, "XDG_RUNTIME_DIR") catch null;
    defer if (host_xdg_runtime) |v| gpa.free(v);
    const host_wayland = init.minimal.environ.getAlloc(gpa, "WAYLAND_DISPLAY") catch null;
    defer if (host_wayland) |v| gpa.free(v);
    const host_x11 = init.minimal.environ.getAlloc(gpa, "DISPLAY") catch null;
    defer if (host_x11) |v| gpa.free(v);
    const host_home = init.minimal.environ.getAlloc(gpa, "HOME") catch null;
    defer if (host_home) |v| gpa.free(v);
    const host: sandbox_mod.HostInfo = .{
        .xdg_runtime_dir = host_xdg_runtime,
        .wayland_display = host_wayland,
        .x11_display = host_x11,
        .home = host_home,
    };

    // RPDL bearer token, plain-text at `<data_root>/rpdl_token`
    // (mode 0600). Mirrors the f95_cookie pattern. Absent file = null
    // → per-game Download falls back to error message on .rpdl sources.
    const rpdl_token_path = try std.fmt.allocPrint(gpa, "{s}/rpdl_token", .{data_root});
    defer gpa.free(rpdl_token_path);
    log.info("rpdl tok  {s}", .{rpdl_token_path});
    const rpdl_token: ?[]u8 = loadCookie(init.io, gpa, rpdl_token_path) catch |e| blk: {
        log.warn("rpdl token load failed: {s}", .{@errorName(e)});
        break :blk null;
    };
    defer if (rpdl_token) |t| gpa.free(t);
    if (rpdl_token) |t| log.info("loaded RPDL token ({d} bytes)", .{t.len});

    // Browser picker: detect installed browsers + load the user's
    // saved choice (if any) from `<config>/f69/browser`. The path
    // sent to xdg-open / spawn is whatever the user picked, with
    // `xdg-open` as the implicit fallback.
    const browsers = detectBrowsers(init.io, gpa, init.minimal.environ) catch &.{};
    defer freeBrowsers(gpa, @constCast(browsers));
    log.info("detected {d} browser(s):", .{browsers.len});
    for (browsers) |b| log.info("  {s} ({s})", .{ b.display, b.path });

    const browser_choice_path = try std.fmt.allocPrint(gpa, "{s}/browser", .{data_root});
    defer gpa.free(browser_choice_path);

    var browser_path_buf: [512]u8 = [_]u8{0} ** 512;
    if (loadBrowserChoice(init.io, gpa, browser_choice_path)) |loaded_opt| {
        if (loaded_opt) |loaded| {
            defer gpa.free(loaded);
            const n = @min(loaded.len, browser_path_buf.len - 1);
            @memcpy(browser_path_buf[0..n], loaded[0..n]);
        } else {
            const dflt = "xdg-open";
            @memcpy(browser_path_buf[0..dflt.len], dflt);
        }
    } else |_| {
        const dflt = "xdg-open";
        @memcpy(browser_path_buf[0..dflt.len], dflt);
    }

    // UI scale: loaded from `<data_root>/ui_scale` (default 1.25).
    // Slider in Settings rewrites this file when the user adjusts it.
    const ui_scale_path = try std.fmt.allocPrint(gpa, "{s}/ui_scale", .{data_root});
    defer gpa.free(ui_scale_path);
    const initial_ui_scale: f32 = loadUiScale(init.io, gpa, ui_scale_path) catch 1.25;

    // Last-update-check timestamp — used as the stop-cursor when
    // walking F95's latest-updates pages. 0 (file missing) means the
    // worker will substitute "now - 14 days" so the very first run
    // doesn't scan years of history.
    const last_update_check_path = try std.fmt.allocPrint(gpa, "{s}/last_update_check", .{data_root});
    defer gpa.free(last_update_check_path);
    const initial_last_update_check_ts: i64 = loadInt64(init.io, gpa, last_update_check_path) catch 0;

    // Auto-check preferences (on-startup toggle + recurring interval).
    const auto_check_path = try std.fmt.allocPrint(gpa, "{s}/auto_check", .{data_root});
    defer gpa.free(auto_check_path);
    const initial_auto_check: ui.AutoCheckSettings = loadAutoCheck(init.io, gpa, auto_check_path) catch .{};

    // Auto-convert toggle — `<data_root>/auto_convert` contains a
    // single `true` / `false`. Default false.
    const auto_convert_path = try std.fmt.allocPrint(gpa, "{s}/auto_convert", .{data_root});
    defer gpa.free(auto_convert_path);
    const initial_auto_convert: bool = loadBool(init.io, gpa, auto_convert_path) catch false;

    // Global sandbox-on-launch default — single-line `true` / `false`.
    // Default on (the safer choice). Per-game `SandboxOverride.use_default`
    // consults this value; `.always` / `.never` ignore it.
    const sandbox_default_path = try std.fmt.allocPrint(gpa, "{s}/sandbox_default", .{data_root});
    defer gpa.free(sandbox_default_path);
    const initial_sandbox_default: bool = loadBoolDefault(init.io, gpa, sandbox_default_path, true) catch true;

    // Global auto-update default — single-line `true` / `false`.
    // Default off (auto-downloading in the background = bandwidth +
    // disk surprises; user opts in). Per-game `AutoUpdateOverride.use_default`
    // consults this value; `.always` / `.never` ignore it.
    const auto_update_default_path = try std.fmt.allocPrint(gpa, "{s}/auto_update_default", .{data_root});
    defer gpa.free(auto_update_default_path);
    const initial_auto_update_default: bool = loadBoolDefault(init.io, gpa, auto_update_default_path, false) catch false;

    // Master tag list cache path. `runMainLoop` loads its contents
    // into State on startup so the sidebar's checkbox list is
    // populated even on first paint.
    const tags_master_path = try std.fmt.allocPrint(gpa, "{s}/tags.txt", .{data_root});
    defer gpa.free(tags_master_path);

    try ui.runMainLoop(init, &lib, &f95_service, &dl_mgr, &recipe_repo, &sandbox, &host_launcher, &convert_svc, &compat_svc, rpdl_token, .{
        .data_root = data_root,
        .db_path = db_path,
        .covers_dir = covers_dir,
        .library_root = library_root,
        .cookie_path = cookie_path,
        .recipes_dir = recipes_dir,
        .mod_archives_dir = mod_archives_dir,
        .mod_presets_dir = mod_presets_dir,
        .convert_presets_dir = convert_presets_dir,
        .browser_path_file = browser_choice_path,
        .browsers = browsers,
        .initial_browser_path = browser_path_buf[0 .. std.mem.indexOfScalar(u8, &browser_path_buf, 0) orelse browser_path_buf.len],
        .rate_limit_ms = rate_limit_ms,
        .rpdl_token_path = rpdl_token_path,
        .ui_scale_path = ui_scale_path,
        .initial_ui_scale = initial_ui_scale,
        .last_update_check_path = last_update_check_path,
        .initial_last_update_check_ts = initial_last_update_check_ts,
        .auto_check_path = auto_check_path,
        .initial_auto_check = initial_auto_check,
        .tags_master_path = tags_master_path,
        .aria2_port_path = aria2_port_path,
        .initial_aria2_port = initial_aria2_port,
        .aria2_seed_ratio_path = aria2_seed_ratio_path,
        .initial_aria2_seed_ratio = initial_aria2_seed_ratio,
        .auto_convert_path = auto_convert_path,
        .initial_auto_convert = initial_auto_convert,
        .sandbox_default_path = sandbox_default_path,
        .initial_sandbox_default = initial_sandbox_default,
        .auto_update_default_path = auto_update_default_path,
        .initial_auto_update_default = initial_auto_update_default,
        .host = host,
    });
}

/// Read a single-line bool from a file, returning `default` when the
/// file is missing. Recognises `true`, `1`, `on`, `yes` as true;
/// anything else as false.
fn loadBoolDefault(io: std.Io, gpa: std.mem.Allocator, path: []const u8, default: bool) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32)) catch |e| {
        if (e == error.FileNotFound) return default;
        return e;
    };
    defer gpa.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return default;
    return std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1") or
        std.mem.eql(u8, trimmed, "on") or std.mem.eql(u8, trimmed, "yes");
}

/// Read a single-line bool from a file. Returns false on missing /
/// unparseable. Recognises `true`, `1`, `on`, `yes` as true; anything
/// else as false.
fn loadBool(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32)) catch |e| {
        if (e == error.FileNotFound) return false;
        return e;
    };
    defer gpa.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1") or
        std.mem.eql(u8, trimmed, "on") or std.mem.eql(u8, trimmed, "yes");
}

/// Read a `f32` seed-ratio target from a single-line file. Returns
/// 5.0 (the default) on missing/malformed values. Clamped to ≥ 2.0
/// because anything below is below the RPDL community floor.
fn loadSeedRatio(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !f32 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32)) catch |e| {
        if (e == error.FileNotFound) return 5.0;
        return e;
    };
    defer gpa.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return 5.0;
    return @max(parsed, 2.0);
}

/// Read an unsigned 16-bit integer from a single-line file. Returns
/// 0 (= "random port") on missing/malformed, with the calling site
/// treating 0 as the "let aria2 pick" sentinel.
fn loadU16(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !u16 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16)) catch |e| {
        if (e == error.FileNotFound) return 0;
        return e;
    };
    defer gpa.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.fmt.parseInt(u16, trimmed, 10) catch 0;
}

/// Parse `<data_root>/auto_check`. Format is `key=value` per line.
/// Recognized keys: `on_startup`, `interval_enabled` (both
/// `true`/`false`), `interval_count` (integer 1..999),
/// `interval_unit` (`minutes`/`hours`/`days`). Unknown keys ignored;
/// missing file or unparseable values fall back to defaults.
fn loadAutoCheck(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !ui.AutoCheckSettings {
    var out: ui.AutoCheckSettings = .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512)) catch |e| {
        if (e == error.FileNotFound) return out;
        return e;
    };
    defer gpa.free(bytes);
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "on_startup")) {
            out.on_startup = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "interval_enabled")) {
            out.interval_enabled = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "interval_count")) {
            const n = std.fmt.parseInt(u32, val, 10) catch continue;
            out.interval_count = std.math.clamp(n, 1, 999);
        } else if (std.mem.eql(u8, key, "interval_unit")) {
            if (std.mem.eql(u8, val, "minutes")) out.interval_unit = .minutes;
            if (std.mem.eql(u8, val, "hours")) out.interval_unit = .hours;
            if (std.mem.eql(u8, val, "days")) out.interval_unit = .days;
        }
    }
    return out;
}

/// Read a signed 64-bit integer from a single-line file. Returns 0
/// if the file is missing or contains anything unparseable; never
/// fatal — callers treat 0 as "never set".
fn loadInt64(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !i64 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch |e| {
        if (e == error.FileNotFound) return 0;
        return e;
    };
    defer gpa.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch 0;
}

/// Read a `f32` from the ui_scale file. Returns 1.25 on missing /
/// malformed values, clamped to a sane range so a bad file can't
/// render the UI unreadable.
fn loadUiScale(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !f32 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32)) catch |e| {
        if (e == error.FileNotFound) return 1.25;
        return e;
    };
    defer gpa.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return 1.25;
    return std.math.clamp(parsed, 0.75, 3.0);
}

/// One entry in the "Browser:" dropdown. We mirror `ui.Browser`'s
/// shape (display + path) but path is mutable here because we own it.
const BrowserCandidate = struct {
    display: []const u8,
    exe: []const u8,
};

/// Common Linux browsers we know how to launch URLs through. `xdg-open`
/// always lands first if present so the system default works without
/// any configuration.
const BROWSER_CANDIDATES = [_]BrowserCandidate{
    .{ .display = "System default (xdg-open)", .exe = "xdg-open" },
    .{ .display = "Firefox", .exe = "firefox" },
    .{ .display = "LibreWolf", .exe = "librewolf" },
    .{ .display = "Waterfox", .exe = "waterfox" },
    .{ .display = "Chromium", .exe = "chromium" },
    .{ .display = "Google Chrome", .exe = "google-chrome-stable" },
    .{ .display = "Google Chrome", .exe = "google-chrome" },
    .{ .display = "Brave", .exe = "brave" },
    .{ .display = "Brave", .exe = "brave-browser" },
    .{ .display = "Vivaldi", .exe = "vivaldi-stable" },
    .{ .display = "Vivaldi", .exe = "vivaldi" },
    .{ .display = "Opera", .exe = "opera" },
    .{ .display = "Microsoft Edge", .exe = "microsoft-edge-stable" },
    .{ .display = "Microsoft Edge", .exe = "microsoft-edge" },
};

/// Walk `$PATH` looking for known browser executables. Returns a slice
/// of the ones present, deduplicated by canonical path. Caller frees
/// via `freeBrowsers`.
fn detectBrowsers(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) ![]ui.Browser {
    const path_env = environ.getAlloc(gpa, "PATH") catch return &.{};
    defer gpa.free(path_env);

    var out: std.ArrayList(ui.Browser) = .empty;
    errdefer freeBrowsers(gpa, out.toOwnedSlice(gpa) catch unreachable);

    candidates: for (BROWSER_CANDIDATES) |c| {
        var dir_iter = std.mem.tokenizeScalar(u8, path_env, ':');
        while (dir_iter.next()) |dir| {
            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, c.exe }) catch continue;
            std.Io.Dir.cwd().access(io, full, .{ .execute = true }) catch continue;
            // Dedupe — `/usr/bin/firefox` and `/usr/local/bin/firefox` etc.
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.path, full)) continue :candidates;
            }
            const path_owned = try gpa.dupe(u8, full);
            try out.append(gpa, .{ .display = c.display, .path = path_owned });
            continue :candidates; // first hit per candidate is good enough
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freeBrowsers(gpa: std.mem.Allocator, browsers: []ui.Browser) void {
    for (browsers) |b| gpa.free(@constCast(b.path));
    if (browsers.len > 0) gpa.free(browsers);
}

/// **Portable mode** — resolve the directory where the f69 executable
/// lives and put all our data under `<exe_dir>/data/`. Override the
/// whole thing with the `F69_DATA_DIR` env var. Caller frees.
///
/// On Linux we read `/proc/self/exe` which is a symlink to the running
/// binary. If that fails (very unusual on real Linux) we fall back to
/// `./data` (cwd-relative), with a warning logged.
fn resolveDataRoot(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    // Explicit override wins.
    if (environ.getAlloc(gpa, "F69_DATA_DIR")) |x| return x else |_| {}

    // Read /proc/self/exe → take dirname → append /data.
    var link_buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(io, "/proc/self/exe", &link_buf) catch {
        log.warn("resolveDataRoot: /proc/self/exe unreadable; falling back to ./data", .{});
        return gpa.dupe(u8, "./data");
    };
    const exe_path = link_buf[0..n];
    const exe_dir = std.fs.path.dirname(exe_path) orelse return gpa.dupe(u8, "./data");
    return std.fmt.allocPrint(gpa, "{s}/data", .{exe_dir});
}

fn loadBrowserChoice(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2 * 1024)) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(bytes);
        return null;
    }
    if (trimmed.len == bytes.len) return bytes;
    const dup = try gpa.dupe(u8, trimmed);
    gpa.free(bytes);
    return dup;
}

/// Remove orphan `*.tmp` cover files left by a prior run that crashed
/// or was Ctrl+C'd mid-write (see ui.fetchAndWriteCover's atomic
/// tmp+rename). Best-effort.
fn sweepTmpCovers(io: std.Io, covers_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, covers_dir, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
}

/// Read the stored F95 cookie if present. Caller frees the returned
/// slice. Returns `null` (not an error) when the file is absent.
fn loadCookie(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024)) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    // The file may have a trailing newline from a hand-edited save.
    // Strip whitespace before handing to the client.
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(bytes);
        return null;
    }
    if (trimmed.len == bytes.len) return bytes;
    const dup = try gpa.dupe(u8, trimmed);
    gpa.free(bytes);
    return dup;
}

