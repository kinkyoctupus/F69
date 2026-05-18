// dvui main loop and screen dispatcher.
//
// File layout for the ui module:
//
//   ui/state.zig    persistent UI state (Filters, View, Sort, etc.)
//   ui/types.zig    Frame, RuntimeInfo, theme, ascii/time helpers
//   ui/actions.zig  sync engine, cover cache, browser, delete
//   ui/screens.zig  4 screens + render helpers + sorting
//   ui/ui.zig       this file: runMainLoop + guiFrame dispatcher
//
// `state.zig` and `types.zig` are leaves; `actions.zig` imports
// `types.zig`; `screens.zig` imports `types.zig` + `actions.zig`;
// `ui.zig` imports everything. No cycles.

const std = @import("std");
const library = @import("library");
const f95 = @import("f95");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox = @import("sandbox");
const convert = @import("convert");
const compat = @import("compat");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3gpu-backend");

const state_mod = @import("state.zig");
const types = @import("types.zig");
const actions = @import("actions.zig");
const screens = @import("screens.zig");
const mod_job_queue = @import("mod_job_queue.zig");

// Test discovery — pull in nested files' test {} blocks (Zig 0.16
// doesn't walk transitive imports for tests).
test {
    _ = actions;
    _ = types;
    _ = state_mod;
}

pub const State = state_mod.State;
pub const AutoCheckSettings = state_mod.AutoCheckSettings;
pub const AutoCheckUnit = state_mod.AutoCheckUnit;
pub const Frame = types.Frame;
pub const RuntimeInfo = types.RuntimeInfo;
pub const Browser = types.Browser;

pub fn runMainLoop(
    init: std.process.Init,
    lib: *library.Library,
    f95_svc: *f95.Service,
    dl_mgr: *downloads.Manager,
    recipe_repo: *recipe.Repo,
    sandbox_backend: *sandbox.Sandbox,
    host_launcher: *sandbox.NoSandbox,
    convert_svc: *convert.Service,
    compat_svc: *compat.Service,
    initial_rpdl_token: ?[]const u8,
    info: RuntimeInfo,
) !void {
    const io = init.io;
    const gpa = init.gpa;

    SDLBackend.enableSDLLogging();

    var backend = try SDLBackend.initWindow(.{
        .io = io,
        .allocator = gpa,
        .size = .{ .w = 1280.0, .h = 800.0 },
        .min_size = .{ .w = 900.0, .h = 600.0 },
        .vsync = true,
        .title = "f69",
        .icon = null,
    });
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = types.pinkTheme(backend.preferredColorScheme() orelse .dark),
    });
    defer win.deinit();
    // dvui folds `content_scale` into its layout math so scaling here
    // is a single knob for the whole app. The initial value comes from
    // disk (`<data_root>/ui_scale`); the Settings slider updates
    // `state.ui_scale`, which the main loop pushes back into
    // `win.content_scale` every frame so changes take effect live.
    win.content_scale = info.initial_ui_scale;

    // Library snapshot — held by runMainLoop, reloaded when the
    // importer or delete sets `state.reload_requested`.
    var games = try lib.listGames();
    defer lib.freeGames(games);

    // Warm the OS page cache for the first window-worth of covers so
    // the first frame of the library screen doesn't stall on cold
    // file reads. Cap matches `state.cover_cache.len` so we don't
    // bother warming covers we'd evict before drawing.
    actions.spawnCoverPrewarm(gpa, io, info.covers_dir, games, state_mod.COVER_CACHE_CAP);

    // Mod install/uninstall queue + worker. Long-lived: spans the
    // app's lifetime so jobs survive screen navigation and the worker
    // stays warm between clicks.
    var mod_jobs_ctx = actions.RunnerCtx{ .alloc = gpa, .io = io, .lib = lib, .repo = recipe_repo };
    var mod_jobs = mod_job_queue.Queue.init(gpa, io, &win, actions.modJobRunner, &mod_jobs_ctx);
    defer mod_jobs.deinit();

    const mod_queue_path = try std.fmt.allocPrint(gpa, "{s}/mod-queue.json", .{info.data_root});
    defer gpa.free(mod_queue_path);
    try mod_jobs.setPersistPath(mod_queue_path);

    // Recovery: if the app died mid-install, the queue file holds the
    // job descriptions. For each "was running" entry, roll back what
    // the partial tracker recorded, then re-enqueue the install. The
    // periodic flush in ApplyOpts means the tracker has at most
    // `flush_every` orphans the rollback can't see.
    actions.recoverModJobsFromDisk(&mod_jobs, lib, gpa, io) catch |e| {
        std.log.warn("mod queue recovery failed: {s}", .{@errorName(e)});
    };

    try mod_jobs.start();

    var state: State = .{};
    state.login_status = if (f95_svc.client.cookie != null) .logged_in else .logged_out;
    state.setBrowserPath(info.initial_browser_path);
    state.ui_scale = info.initial_ui_scale;
    state.ui_scale_persisted = info.initial_ui_scale;
    state.last_update_check_ts = info.initial_last_update_check_ts;
    state.auto_check = info.initial_auto_check;
    state.auto_check_persisted = info.initial_auto_check;
    state.aria2_port_persisted = info.initial_aria2_port;
    state.auto_convert = info.initial_auto_convert;
    state.auto_convert_persisted = info.initial_auto_convert;
    state.sandbox_default = info.initial_sandbox_default;
    state.sandbox_default_persisted = info.initial_sandbox_default;
    state.auto_update_default = info.initial_auto_update_default;
    state.auto_update_default_persisted = info.initial_auto_update_default;
    // Seed the textEntry buffer with the persisted port (or empty for
    // the "random ephemeral" sentinel). Leaving 0 blank reduces clutter.
    if (info.initial_aria2_port != 0) {
        const port_slice = std.fmt.bufPrint(&state.aria2_port_buf, "{d}", .{info.initial_aria2_port}) catch state.aria2_port_buf[0..0];
        _ = port_slice;
    }
    state.aria2_seed_ratio_persisted = info.initial_aria2_seed_ratio;
    {
        const sr_slice = std.fmt.bufPrint(&state.aria2_seed_ratio_buf, "{d:.1}", .{info.initial_aria2_seed_ratio}) catch state.aria2_seed_ratio_buf[0..0];
        _ = sr_slice;
    }

    // Master tag list — disk first, embedded build-time snapshot as
    // first-run fallback. The user's Refresh button in Settings →
    // Library overwrites the disk copy; after that, disk always wins.
    if (f95.tags.loadOrSeed(lib.alloc, io, info.tags_master_path)) |cached| {
        state.tags_master = cached.tags;
        state.tags_master_fetched_at = cached.fetched_at;
        std.log.info("tags: loaded {d} (fetched_at={d})", .{ cached.tags.len, cached.fetched_at });
    } else |e| {
        std.log.warn("tags load failed: {s}", .{@errorName(e)});
    }
    if (initial_rpdl_token) |t| {
        state.rpdl_token = try lib.alloc.dupe(u8, t);
        state.rpdl_status = .logged_in;
    } else {
        state.rpdl_status = .logged_out;
    }
    defer {
        // Modfile cache + clash modal both own heap state — release
        // them on shutdown so DebugAllocator doesn't flag leaks.
        // Wizard state is inline on State (no heap).
        actions.freeModfileCacheState(&state, lib.alloc);
        actions.freeClashModalState(&state, lib.alloc);
        actions.freeCoverCache(&state, lib.alloc);
        actions.freeSlideCache(&state, lib.alloc);
        actions.invalidatePresetCache(&state);
        actions.freeTestInstallJob(&state, io);
        actions.freeThumbCache(&state, lib.alloc);
        actions.freePostInstalled(&state, lib.alloc);
        actions.freeInstalledSet(&state, lib.alloc);
        actions.freePostInstallJobs(&state, lib.alloc);
        actions.freeManualInstallJobs(&state, lib.alloc);
        // Tear down NFDe if the user ever opened the file picker.
        // No-op when never used.
        @import("util_file_picker").deinit();
        actions.freeSyncRecap(&state, lib.alloc);
        actions.freeDonorTables(&state, lib.alloc);
        actions.freeTagsMaster(lib.alloc, &state);
        if (state.sync_queue) |q| lib.alloc.free(q);
        if (state.rpdl_token) |t| lib.alloc.free(t);
    }

    var interrupted = false;
    main_loop: while (true) {
        if (state.reload_requested) {
            lib.freeGames(games);
            games = try lib.listGames();
            state.reload_requested = false;
            // Force re-sort after reload — clear both halves.
            state.sort_applied_column = null;
            state.sort_applied_dir = null;
            // Reload after import/delete — re-warm in case the new
            // games already have covers on disk from a previous sync.
            actions.spawnCoverPrewarm(gpa, io, info.covers_dir, games, state_mod.COVER_CACHE_CAP);
        }

        // Live UI scale: state.ui_scale is the source of truth; push
        // it into the dvui window each frame so the Settings slider
        // takes effect immediately. The persist step (writing the new
        // value to disk) runs from `actions.persistUiScaleIfDirty`
        // once the user pauses on a value.
        win.content_scale = state.ui_scale;
        actions.persistUiScaleIfDirty(&state, info.ui_scale_path, io);
        actions.persistAutoCheckIfDirty(&state, info.auto_check_path, io);
        actions.persistAutoConvertIfDirty(&state, info.auto_convert_path, io);
        actions.persistSandboxDefaultIfDirty(&state, info.sandbox_default_path, io);
        actions.persistAutoUpdateDefaultIfDirty(&state, info.auto_update_default_path, io);
        // Age + evict expired toasts each frame. info/success fade
        // around 3s, warn around 6s, err sticks until clicked.
        state.ageToasts();

        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        // `addAllEvents` returns true on SDL_QUIT or window-close-
        // requested. SDL3 converts SIGINT and SIGTERM into SDL_QUIT
        // automatically, so this is also the path Ctrl+C and the
        // compositor's "kill window" signal (e.g. niri's Super-Q)
        // come through.
        const should_quit = try backend.addAllEvents(&win);
        if (should_quit) {
            std.log.info("quit signal received, shutting down", .{});
            // End this frame cleanly first.
            _ = try win.end(.{});

            // Graceful shutdown: signal cancel on every detached
            // worker, then spin a small drain loop so they hit a
            // phase boundary and report back. Without this, an
            // in-flight HTTP fetch leaves a connection in
            // `http.Client.connection_pool.used`, which makes
            // `f95.Client.deinit` skip its http teardown and leak.
            actions.cancelAllWorkers(&state);
            var shutdown_frame: Frame = .{
                .state = &state,
                .games = games,
                .lib = lib,
                .f95_svc = f95_svc,
                .dl_mgr = dl_mgr,
                .recipe_repo = recipe_repo,
                .sandbox = sandbox_backend,
                .host_launcher = host_launcher,
                .convert_svc = convert_svc,
                .compat_svc = compat_svc,
                .win = &win,
                .io = io,
                .mod_jobs = &mod_jobs,
                .info = info,
            };
            // Wait up to ~6 seconds. The forum rate-limit is 1.5 s
            // per request, so a worker that's mid-sleep needs at
            // least one full rate-limit cycle to come out and notice
            // the cancel. 5–6 s comfortably covers a couple cycles.
            var spin: u32 = 0;
            const SHUTDOWN_DRAIN_TICKS: u32 = 120; // × 50ms = 6 s
            while (actions.workersBusy(&state) and spin < SHUTDOWN_DRAIN_TICKS) : (spin += 1) {
                actions.drainSync(&shutdown_frame);
                actions.drainImageQueue(&shutdown_frame);
                actions.drainBookmarks(&shutdown_frame);
                actions.drainUpdateCheck(&shutdown_frame);
                actions.drainPostInstall(&shutdown_frame);
                actions.drainManualInstall(&shutdown_frame);
                actions.drainTestInstall(&shutdown_frame);
                io.sleep(std.Io.Duration.fromMilliseconds(50), .real) catch {};
            }
            if (actions.workersBusy(&state)) {
                // A worker is still running and we've run out of patience.
                // Letting `main`'s defers run from here would tear down
                // `init.io` / `f95_client.http` / `gpa` while the worker
                // thread is still touching them → segfault and a flood
                // of DebugAllocator leak reports. Hard-exit instead: the
                // OS reclaims every resource the worker holds, no
                // defers run, no use-after-free is possible.
                std.log.warn(
                    "shutdown timeout: workers still busy after {d}s, hard-exiting (skipping deinits)",
                    .{SHUTDOWN_DRAIN_TICKS / 20},
                );
                std.process.exit(0);
            }
            std.log.info("all workers drained cleanly", .{});
            break :main_loop;
        }

        var frame: Frame = .{
            .state = &state,
            .games = games,
            .lib = lib,
            .f95_svc = f95_svc,
            .dl_mgr = dl_mgr,
            .recipe_repo = recipe_repo,
            .sandbox = sandbox_backend,
            .host_launcher = host_launcher,
            .convert_svc = convert_svc,
            .compat_svc = compat_svc,
            .win = &win,
            .io = io,
            .mod_jobs = &mod_jobs,
            .info = info,
        };
        // Auto-update-check: fires once at startup (if enabled) and
        // on a recurring interval. Gated on workers being idle so we
        // don't race a bookmark import.
        actions.maybeAutoUpdateCheck(&frame);
        if (!try guiFrame(&frame)) break :main_loop;

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn guiFrame(frame: *Frame) !bool {
    // Build per-frame snapshots. Both sit in dvui's per-frame arena
    // so the storage disappears at frame end; `frame.install_versions`
    // and `frame.games_by_thread` are only valid for the current
    // frame. Failure is non-fatal — callers fall back to the
    // legacy per-game SQL / linear-scan paths via `orelse`.
    var install_versions = frame.lib.latestInstallVersionMap(dvui.currentWindow().arena()) catch null;
    if (install_versions) |*m| {
        frame.install_versions = m;
    }

    var games_by_thread = std.AutoHashMap(u64, *library.Game).init(dvui.currentWindow().arena());
    games_by_thread.ensureTotalCapacity(@intCast(frame.games.len)) catch {};
    for (frame.games) |*g| games_by_thread.put(g.f95_thread_id, g) catch {};
    frame.games_by_thread = &games_by_thread;

    actions.drainSync(frame);
    actions.drainImageQueue(frame);
    actions.drainBookmarks(frame);
    actions.drainUpdateCheck(frame);
    actions.drainRpdlDownload(frame);
    actions.drainDonorDownload(frame);
    actions.drainRefreshTags(frame);
    // Refresh aria2-driven download progress. Cheap on localhost
    // (sub-ms RPC) and only walks non-terminal jobs. Skip the call
    // entirely when there are no jobs — pure dead work for idle
    // sessions that never touched a download.
    if (frame.dl_mgr.jobs.count() > 0) frame.dl_mgr.tick();
    // Aria2 progress + the detail-page "Installing…" sweep both
    // arrive/animate between input events. Without an explicit
    // re-render request, the main loop's `waitEventTimeout` would
    // sit idle and neither would move until the user touched the
    // mouse. Whenever any download job is non-terminal OR an
    // extract worker is in flight, ask dvui to schedule another
    // frame. vsync caps the cost at ~60 fps; idle libraries with
    // no activity incur zero wakeups.
    if (anyDownloadActive(frame.dl_mgr) or anyPostInstallActive(frame.state)) {
        dvui.refresh(frame.win, @src(), null);
    }
    // Toasts need wall-clock ticks to fade out. Without an explicit
    // refresh request, the main loop blocks on input and toasts
    // appear to hang on screen forever. Cheap — capped at vsync.
    if (frame.state.toast_count > 0) {
        dvui.refresh(frame.win, @src(), null);
    }

    // Verbose telemetry for donor-DDL downloads. Throttled to ~once
    // per 3 s per job, with instant flushes on stall/recovery and
    // aria2 errorMessage changes. Cheap when no donor jobs exist
    // (early-out on empty `donor_jobs` map).
    actions.drainDonorTelemetry(frame);
    // Any newly-.done downloads with a known game_id get handed to
    // a detached extract worker. `drainCompletedDownloads` just
    // kicks off workers; `drainPostInstall` collects the finished
    // ones and writes the install DB row on the UI thread (SQLite
    // isn't multi-thread-write-safe at the app layer).
    actions.drainCompletedDownloads(frame);
    actions.drainPostInstall(frame);
    actions.drainManualInstall(frame);
    actions.drainTestInstall(frame);
    actions.drainModJobs(frame);
    actions.drainImport(frame);
    // Prune the running-games map for processes that have exited so
    // the detail screen's Launch ↔ Stop swap stays honest.
    actions.drainRunningGames(frame);

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .style = .window,
        .background = true,
        .expand = .both,
        .name = "root",
    });
    defer root.deinit();

    // Global sync banner — visible on every screen while a sync-all
    // batch is in flight (or for a beat after a single sync completes).
    screens.renderSyncBanner(frame);

    const t0 = types.startLatency(frame.io);
    const result = switch (frame.state.screen) {
        .library => screens.libraryScreen(frame),
        .detail => screens.detailScreen(frame),
        .settings => screens.settingsScreen(frame),
        .import => screens.importScreen(frame),
        .downloads => screens.downloadsScreen(frame),
        .diagnostics => screens.diagnosticsScreen(frame),
        .recipe_editor => screens.recipeEditorScreen(frame),
        .mods_for_game => screens.modsScreen(frame),
    };
    // End-of-batch sync recap popup. Sits on top of whichever screen
    // is active so the user always sees the "what changed" list,
    // even if they navigated mid-sync.
    if (frame.state.sync_recap_show) {
        screens.renderSyncRecapPopup(frame);
    }

    // Toast overlay — rendered after every other screen widget so it
    // floats above the content. Visible from any screen.
    screens.renderToasts(frame);

    types.endLatency(frame.io, t0, switch (frame.state.screen) {
        .library => "render library",
        .detail => "render detail",
        .settings => "render settings",
        .import => "render import",
        .downloads => "render downloads",
        .diagnostics => "render diagnostics",
        .recipe_editor => "render recipe editor",
        .mods_for_game => "render mods page",
    });
    return result;
}

/// True iff the download manager has any job that is still
/// changing (downloading, seeding, queued, mid-extract, etc.).
/// Drives the `dvui.refresh` call in `guiFrame` so progress bars
/// keep moving between input events.
fn anyDownloadActive(dl_mgr: *downloads.Manager) bool {
    if (dl_mgr.jobs.count() == 0) return false;
    var it = dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.status) {
            // Terminal + paused + seeding states don't animate
            // anything the user cares about per frame, so skip them
            // when deciding whether to schedule another redraw.
            // (Paused still re-polls via tick(), but the numbers
            // don't move. Seeding ticks an upload counter the UI
            // shows on the Downloads tab only; not worth a 60Hz
            // refresh on every screen.)
            .done, .failed, .cancelled, .paused, .seeding => continue,
            else => return true,
        }
    }
    return false;
}

/// True iff any post-install (extract) worker is in flight. Used
/// alongside `anyDownloadActive` to keep the main loop redrawing
/// while the detail-page "Installing…" sweep animation needs frames.
fn anyPostInstallActive(state: *const State) bool {
    return actions.anyPostInstallActive(state);
}
