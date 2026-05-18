// Cross-domain helpers shared between the per-domain action modules.
// After R9 the original `src/ui/actions.zig` was split into ten
// per-domain files; whatever didn't fit cleanly into one bucket landed
// here. Contents:
//
//   - `cancelAllWorkers` / `workersBusy` — global worker shutdown +
//     liveness probe.
//   - `installedSetPtr` / `refreshInstalledSet` / `isInstalled` /
//     `retryDownload` / `installDotState` / `freeInstalledSet` —
//     installed-set + download-retry glue between installer.zig and
//     downloads.zig.
//   - `attemptsMap` / `resetAttempt` — per-game download-attempt
//     counter, shared by downloads.zig and installer.zig.
//   - Settings persistence + browser launch — every dirty-flag
//     debounced disk write pre-R9 lived here; no single domain owns
//     "settings".
//   - `persistTextFile`, `friendlyError` — file-private helpers used
//     across sync.zig / imports.zig / tags.zig / bookmarks.zig /
//     auth.zig.
//   - `exeExistsUnder` / `freePostInstalled` — orphan tear-down
//     helpers that touch state owned by three domains.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const version_mod = @import("util_version");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");

const Frame = types.Frame;
const State = types.State;

const InstalledSet = owned_types.InstalledSet;
const AttemptsMap = owned_types.AttemptsMap;

// Imports of sibling action modules. Routed through pointers-to-pubs
// so the explicit cross-file calls below resolve.
const sync_mod = @import("sync.zig");
const downloads_mod = @import("downloads.zig");
const installer_mod = @import("installer.zig");
const imports_mod = @import("imports.zig");
const launch_mod = @import("launch.zig");

/// Flip the cancel flag on every in-flight worker. Used by the
/// graceful-shutdown path to nudge detached workers toward their
/// next phase boundary so the HTTP client + DB can be torn down
/// cleanly. Idempotent. Every slot listed in `workersBusy` below
/// MUST also flip its cancel flag here, otherwise the shutdown
/// spin loop will time out on a worker that nobody asked to stop.
pub fn cancelAllWorkers(state: *types.State) void {
    if (state.pending_sync) |j| j.cancel.store(true, .release);
    // Phase-2 image worker: shared cancel flag covers both the active
    // job and any tids still queued.
    state.image_cancel.store(true, .release);
    if (state.pending_bookmarks) |j| j.cancel.store(true, .release);
    if (state.pending_update_check) |j| j.cancel.store(true, .release);
    if (state.pending_rpdl_download) |j| j.cancel.store(true, .release);
    if (state.pending_donor_download) |j| j.cancel.store(true, .release);
    if (state.pending_tags_refresh) |j| j.cancel.store(true, .release);
    if (state.test_install_job) |j| j.cancel.store(true, .release);
    if (state.import_job) |j| j.cancel.store(true, .release);
}

/// True when any async worker is still occupying its state slot.
/// The graceful-shutdown loop spins on this until everything clears
/// (with a 6s budget; if it expires, the process hard-exits and the
/// OS reaps anything left).
///
/// Every long-running worker slot on `State` MUST be listed here.
/// If a slot is missed, `workersBusy` returns false while the worker
/// thread is still mid-syscall → the defer chain in `runMainLoop`
/// races `f95_client.deinit` against the worker's next HTTP call →
/// UAF. The companion `cancelAllWorkers` must cover every slot too.
pub fn workersBusy(state: *const types.State) bool {
    if (state.pending_sync != null) return true;
    if (state.image_active != null) return true;
    if (state.image_queue != null and state.image_queue_head < state.image_queue_len) return true;
    if (state.pending_bookmarks != null) return true;
    if (state.pending_update_check != null) return true;
    if (state.pending_rpdl_download != null) return true;
    if (state.pending_donor_download != null) return true;
    if (state.pending_tags_refresh != null) return true;
    if (state.test_install_job != null) return true;
    if (state.import_job != null) return true;
    if (state.post_install_jobs) |list_ptr| {
        if (list_ptr.items.len > 0) return true;
    }
    if (installer_mod.manualInstallsRunning(state)) return true;
    return false;
}

// ============================================================
//  open thread in system browser — non-blocking
// ============================================================

const BrowserJob = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    exe: []u8,
    url: []u8,
};

pub fn openInBrowser(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    // Resolve the browser executable from the user's saved choice.
    // Falls back to "xdg-open" if the saved path is empty (first run
    // before they touched Settings).
    const chosen = frame.state.browserPathSlice();
    const exe_src: []const u8 = if (chosen.len == 0) "xdg-open" else chosen;

    const job = alloc.create(BrowserJob) catch return;
    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://f95zone.to/threads/{d}/", .{thread_id}) catch {
        alloc.destroy(job);
        return;
    };
    const url_owned = alloc.dupe(u8, url) catch {
        alloc.destroy(job);
        return;
    };
    const exe_owned = alloc.dupe(u8, exe_src) catch {
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .exe = exe_owned, .url = url_owned };

    const thr = std.Thread.spawn(.{}, browserWorker, .{job}) catch {
        alloc.free(exe_owned);
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

/// Open an arbitrary URL in the user's chosen browser. Same fire-and-
/// forget worker as `openInBrowser`, but the URL is provided directly
/// rather than synthesised from a thread id. Used by the Downloads
/// tab's per-link "Open" button.
pub fn openExternalUrl(frame: *Frame, url: []const u8) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const chosen = frame.state.browserPathSlice();
    const exe_src: []const u8 = if (chosen.len == 0) "xdg-open" else chosen;

    const job = alloc.create(BrowserJob) catch return;
    const url_owned = alloc.dupe(u8, url) catch {
        alloc.destroy(job);
        return;
    };
    const exe_owned = alloc.dupe(u8, exe_src) catch {
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .exe = exe_owned, .url = url_owned };

    const thr = std.Thread.spawn(.{}, browserWorker, .{job}) catch {
        alloc.free(exe_owned);
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

fn browserWorker(job: *BrowserJob) void {
    defer {
        job.alloc.free(job.exe);
        job.alloc.free(job.url);
        job.alloc.destroy(job);
    }
    const argv = [_][]const u8{ job.exe, job.url };
    var child = std.process.spawn(job.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(job.io) catch {};
}

/// Persist the browser executable path the user picked in Settings.
/// Atomic tmp+rename. Empty input (after trimming) clears the file
/// so the next launch falls back to xdg-open.
pub fn saveBrowserPath(frame: *Frame, path: []const u8) void {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    const file_path = frame.info.browser_path_file;

    if (trimmed.len == 0) {
        std.Io.Dir.cwd().deleteFile(frame.io, file_path) catch {};
        frame.state.setBrowserPath("xdg-open");
        frame.state.setBrowserMsg("reset to xdg-open");
        return;
    }

    persistTextFile(frame.io, file_path, trimmed) catch |e| {
        var emsg: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "save failed: {s}", .{@errorName(e)}) catch "save failed";
        frame.state.setBrowserMsg(m);
        return;
    };
    frame.state.setBrowserPath(trimmed);
    frame.state.setBrowserMsg("saved");
}

/// Write the current `state.ui_scale` to disk when it differs from
/// the persisted snapshot. Called every frame from the main loop;
/// the comparison short-circuits unless the user actually moved the
/// slider, so disk writes happen at most once per change.
pub fn persistUiScaleIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.ui_scale == state.ui_scale_persisted) return;
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.2}", .{state.ui_scale}) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("ui_scale persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.ui_scale_persisted = state.ui_scale;
}

/// Write the auto-check preferences to disk in the simple `key=value`
/// format `loadAutoCheck` understands. Short-circuits when nothing
/// changed since the last persisted snapshot so a frame-rate persist
/// is essentially free.
pub fn persistAutoCheckIfDirty(state: *State, path: []const u8, io: std.Io) void {
    const cur = state.auto_check;
    const prev = state.auto_check_persisted;
    if (cur.on_startup == prev.on_startup and
        cur.interval_enabled == prev.interval_enabled and
        cur.interval_count == prev.interval_count and
        cur.interval_unit == prev.interval_unit) return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "on_startup={s}\ninterval_enabled={s}\ninterval_count={d}\ninterval_unit={s}\n",
        .{
            if (cur.on_startup) "true" else "false",
            if (cur.interval_enabled) "true" else "false",
            cur.interval_count,
            @tagName(cur.interval_unit),
        },
    ) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_check persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_check_persisted = cur;
}

/// Persist `state.auto_convert` to disk when it diverges from the
/// last-saved value. Called every frame; the comparison short-
/// circuits unless the user actually flipped the toggle.
pub fn persistAutoConvertIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.auto_convert == state.auto_convert_persisted) return;
    const text: []const u8 = if (state.auto_convert) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_convert persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_convert_persisted = state.auto_convert;
}

/// Mirror `state.sandbox_default` to `<data_root>/sandbox_default`
/// when the checkbox in Settings flips. Same debounce trick as
/// `persistAutoConvertIfDirty` — no-op when nothing changed.
pub fn persistSandboxDefaultIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.sandbox_default == state.sandbox_default_persisted) return;
    const text: []const u8 = if (state.sandbox_default) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("sandbox_default persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.sandbox_default_persisted = state.sandbox_default;
}

/// Mirror `state.auto_update_default` to disk on toggle. Same shape
/// as `persistSandboxDefaultIfDirty`.
pub fn persistAutoUpdateDefaultIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.auto_update_default == state.auto_update_default_persisted) return;
    const text: []const u8 = if (state.auto_update_default) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_update_default persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_update_default_persisted = state.auto_update_default;
}

/// Parse the aria2-port textEntry buffer + Save it. Returns the new
/// port on success (0 = "use a random ephemeral port"), or an error
/// when the buffer isn't a valid integer. Persists to `<data_root>/aria2_port`.
/// Effective on next launch — the daemon binds at spawn time.
pub fn saveAria2Port(state: *State, path: []const u8, io: std.Io) !u16 {
    const end = std.mem.indexOfScalar(u8, &state.aria2_port_buf, 0) orelse state.aria2_port_buf.len;
    const trimmed = std.mem.trim(u8, state.aria2_port_buf[0..end], " \t\r\n");
    const new_port: u16 = if (trimmed.len == 0) 0 else try std.fmt.parseInt(u16, trimmed, 10);
    // 1..1023 are privileged ports on POSIX — aria2 won't bind them
    // as a non-root user. Reject early with a clear message instead
    // of letting the next spawn fail mysteriously.
    if (new_port != 0 and new_port < 1024) return error.PrivilegedPort;

    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{new_port}) catch return error.OutOfMemory;
    try persistTextFile(io, path, text);
    state.aria2_port_persisted = new_port;
    return new_port;
}

/// Parse the seed-ratio textEntry buffer + Save it. Floor enforced
/// at 2.0; anything below is rejected so the user gets an explicit
/// "too low" message instead of a silent clamp. Persists to
/// `<data_root>/aria2_seed_ratio`. Effective on next launch (the
/// --seed-ratio flag is daemon-wide and set at spawn).
pub fn saveAria2SeedRatio(state: *State, path: []const u8, io: std.Io) !f32 {
    const end = std.mem.indexOfScalar(u8, &state.aria2_seed_ratio_buf, 0) orelse state.aria2_seed_ratio_buf.len;
    const trimmed = std.mem.trim(u8, state.aria2_seed_ratio_buf[0..end], " \t\r\n");
    if (trimmed.len == 0) return error.Empty;
    const parsed = try std.fmt.parseFloat(f32, trimmed);
    if (!std.math.isFinite(parsed)) return error.NotFinite;
    if (parsed < 2.0) return error.BelowFloor;

    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.2}", .{parsed}) catch return error.OutOfMemory;
    try persistTextFile(io, path, text);
    state.aria2_seed_ratio_persisted = parsed;
    return parsed;
}

/// Fire `startUpdateCheck` automatically based on the user's
/// preferences: once at startup (if `on_startup`) and/or on a
/// recurring interval (if `interval_enabled`). Skipped while any
/// async worker is in flight so we never race a bookmark import or
/// piggy-back on top of an already-running check.
pub fn maybeAutoUpdateCheck(frame: *Frame) void {
    const state = frame.state;
    // Never fire while another worker is mid-flight. The startup
    // path waits for bookmarks to drain, the recurring path waits
    // for whichever previous check finishes.
    if (state.pending_update_check != null) return;
    if (state.pending_bookmarks != null) return;
    if (state.pending_sync != null) return;
    if (state.sync_queue != null) return;

    const settings = state.auto_check;

    // --- one-shot startup trigger ---
    if (settings.on_startup and !state.auto_check_did_startup) {
        state.auto_check_did_startup = true;
        log.info("auto-check: startup trigger firing", .{});
        imports_mod.startUpdateCheck(frame);
        return;
    }

    // --- recurring interval ---
    if (!settings.interval_enabled) return;
    if (settings.interval_count == 0) return;
    const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
    const interval_s: i64 = @as(i64, @intCast(settings.interval_count)) * settings.interval_unit.seconds();
    // No prior check → wait for the user's first manual click, OR
    // fall into the startup trigger above. Don't auto-fire on a
    // brand new install just because the interval is "enabled".
    if (state.last_update_check_ts == 0) return;
    if (now_s - state.last_update_check_ts < interval_s) return;
    log.info(
        "auto-check: interval trigger firing ({d}{s} since last check)",
        .{ settings.interval_count, @tagName(settings.interval_unit) },
    );
    imports_mod.startUpdateCheck(frame);
}

pub fn persistTextFile(io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer f.close(io);
    var fw_buf: [1024]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Map raw error names from `f95.errors.Error` (or the f95.Client) to
/// short human-readable strings for status banners. Falls back to the
/// raw name on unknown values.
pub fn friendlyError(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "AuthRequired")) return "session expired — re-login";
    if (std.mem.eql(u8, name, "ServerError")) return "F95 server error (5xx) — retry later";
    if (std.mem.eql(u8, name, "RateLimited")) return "rate limited by F95 — wait + retry";
    if (std.mem.eql(u8, name, "NetworkError")) return "network error — check connection";
    if (std.mem.eql(u8, name, "NotFound")) return "endpoint not found (404)";
    if (std.mem.eql(u8, name, "HttpStatusError")) return "F95 returned an unexpected status";
    if (std.mem.eql(u8, name, "OutOfMemory")) return "out of memory";
    if (std.mem.eql(u8, name, "DatabaseError")) return "database write failed";
    if (std.mem.eql(u8, name, "Cancelled")) return "cancelled";
    return name;
}

// ============================================================
//  delete game (DB row + cover file + cache eviction)
// ============================================================

pub fn deleteGameAndReturn(frame: *Frame, thread_id: u64) void {
    const state = frame.state;
    frame.lib.deleteGame(thread_id) catch {};

    // Best-effort cover-file removal — silently ignore if missing.
    var path_buf: [256]u8 = undefined;
    if (sync_mod.coverPath(&path_buf, frame.info.covers_dir, thread_id)) |path| {
        std.Io.Dir.cwd().deleteFile(frame.io, path) catch {};
    } else |_| {}

    sync_mod.invalidateCover(state, frame.lib.alloc, thread_id);

    state.confirm_delete = false;
    state.selected_thread = null;
    state.screen = .library;
    state.reload_requested = true;
}

// ============================================================
//  installed-set + per-game install dot + retry-download glue
// ============================================================

/// Lazy-init the installed-set. `refreshInstalledSet` repopulates it
/// from the DB; callers consult `isInstalled` per game.
fn installedSetPtr(frame: *Frame) *InstalledSet {
    if (frame.state.installed_set) |p| return p;
    const set_ptr = frame.lib.alloc.create(InstalledSet) catch unreachable;
    set_ptr.* = InstalledSet.init(frame.lib.alloc);
    frame.state.installed_set = set_ptr;
    return set_ptr;
}

/// Rebuild the installed-set from the `installs` table. Cheap on a
/// reasonable library — a single SELECT DISTINCT. Call once per
/// library-screen render before any `isInstalled` lookups so the
/// indicator + filter reflect a fresh snapshot (post-install
/// completions land in the table between renders).
pub fn refreshInstalledSet(frame: *Frame) void {
    const set = installedSetPtr(frame);
    set.clearRetainingCapacity();
    const ids = frame.lib.fetchInstalledThreadIds() catch |e| {
        log.warn("refreshInstalledSet: fetchInstalledThreadIds failed: {s}", .{@errorName(e)});
        return;
    };
    defer frame.lib.alloc.free(ids);
    for (ids) |tid| set.put(tid, {}) catch {};
}

/// Read-only probe — true iff `thread_id` had at least one install
/// row at the last `refreshInstalledSet` call this frame.
pub fn isInstalled(frame: *Frame, thread_id: u64) bool {
    if (frame.state.installed_set == null) return false;
    return installedSetPtr(frame).contains(thread_id);
}

/// Re-trigger a failed download. Picks the right provider based on
/// the failed job's source: RPDL torrents re-enter the search flow,
/// donor DDL re-POSTs for a fresh signed URL, plain HTTP re-enqueues
/// the URL as-is. Removes the failed row from the manager once the
/// replacement is in flight so the downloads page doesn't show two
/// stacked entries for the same game.
pub fn retryDownload(frame: *Frame, job_id: u64) void {
    const state = frame.state;
    const job = frame.dl_mgr.jobs.get(job_id) orelse {
        log.warn("retryDownload: job {d} no longer in manager", .{job_id});
        return;
    };
    const game_id = job.game_id;
    const source = job.source_url;
    const was_donor = downloads_mod.isDonorJob(frame, job_id);

    // Find the matching library row — needed for the RPDL / donor
    // workers which take a *library.Game.
    var target: ?*library.Game = null;
    if (game_id != 0) {
        for (frame.games) |*g| {
            if (g.f95_thread_id == game_id) {
                target = g;
                break;
            }
        }
    }

    if (was_donor) {
        if (target) |g| {
            log.info("retryDownload: job {d} (tid={d}) was donor DDL — restarting flow", .{ job_id, game_id });
            frame.dl_mgr.removeJob(job_id);
            downloads_mod.startDonorDownload(frame, g);
            return;
        }
    }
    if (std.mem.startsWith(u8, source, "rpdl:")) {
        if (target) |g| {
            log.info("retryDownload: job {d} (tid={d}) was RPDL — restarting search", .{ job_id, game_id });
            frame.dl_mgr.removeJob(job_id);
            downloads_mod.startRpdlDownload(frame, g);
            return;
        }
    }
    // Plain HTTP / unrecognised — just re-enqueue the same URL.
    if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) {
        log.info("retryDownload: job {d} — re-enqueuing URL '{s}'", .{ job_id, source });
        // Duplicate before removing the job so the URL slice isn't
        // freed under us.
        const url_dup = frame.lib.alloc.dupe(u8, source) catch {
            state.setDownloadMsg("Retry failed: out of memory");
            return;
        };
        defer frame.lib.alloc.free(url_dup);
        frame.dl_mgr.removeJob(job_id);
        _ = frame.dl_mgr.enqueueUrl(url_dup, .game, game_id, null, null, null, .{}) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "Retry failed: {s}", .{@errorName(e)}) catch "Retry failed";
            state.setDownloadMsg(m);
        };
        return;
    }
    log.warn("retryDownload: job {d} source '{s}' isn't HTTP/RPDL/donor — cannot retry", .{ job_id, source });
    state.setDownloadMsg("Retry not supported for this source.");
}

/// Three-way state used to drive the install dot on grid/list cards.
pub const InstallDotState = enum {
    /// No install row for this game.
    none,
    /// Installed AND the install's recorded `version` matches the
    /// game's `latest_version` from F95 (or there's no scraped
    /// version yet to compare against — we assume up-to-date until
    /// proven otherwise).
    up_to_date,
    /// Installed but the scraped version is newer than the install
    /// row's version — yellow indicator nudges the user toward a
    /// re-download.
    outdated,
};

/// Per-game install state. Uses `installed_set` as a fast first-
/// check (1 HashMap lookup); only when installed do we hit the DB
/// for the actual install version. Cheap: one O(log N) SELECT per
/// rendered card, all on a small + indexed table.
pub fn installDotState(frame: *Frame, game: *const library.Game) InstallDotState {
    if (!isInstalled(frame, game.f95_thread_id)) return .none;
    const latest = frame.lib.latestInstallForGame(game.f95_thread_id) catch return .up_to_date;
    if (latest) |inst| {
        defer frame.lib.freeInstall(inst);
        const scraped = game.latest_version orelse return .up_to_date;
        if (scraped.len == 0) return .up_to_date;
        // Treat the placeholder version "unversioned" as "we don't
        // really know what's installed" — show green, since we
        // can't claim it's outdated.
        if (std.mem.eql(u8, inst.version, "unversioned")) return .up_to_date;
        if (version_mod.equivalent(inst.version, scraped)) return .up_to_date;
        return .outdated;
    }
    return .up_to_date;
}

pub fn freeInstalledSet(state: *State, alloc: std.mem.Allocator) void {
    if (state.installed_set) |set_ptr| {
        set_ptr.deinit();
        alloc.destroy(set_ptr);
        state.installed_set = null;
    }
}

pub fn attemptsMap(frame: *Frame) *AttemptsMap {
    if (frame.state.download_attempts) |p| return p;
    const map_ptr = frame.lib.alloc.create(AttemptsMap) catch unreachable;
    map_ptr.* = AttemptsMap.init(frame.lib.alloc);
    frame.state.download_attempts = map_ptr;
    return map_ptr;
}

/// Record that the user just clicked Download for `game_id` — i.e. we
/// just enqueued `sources[0]` and should start counting failures from
/// index 0. Called by `doDownloadGame` before `enqueueOneSource`.
pub fn resetAttempt(frame: *Frame, game_id: u64) void {
    const m = attemptsMap(frame);
    m.put(game_id, 0) catch {};
}

// ============================================================
//  exe-exists probe
// ============================================================

/// Probe whether `exe` (typically a recipe's `launch.linux`, like
/// `"./MyGame.sh"`) exists as a file under `install_dir`. Handles a
/// leading `./` segment that Ren'Py recipes commonly carry.
fn exeExistsUnder(io: std.Io, install_dir: []const u8, exe: []const u8) bool {
    const rel = if (std.mem.startsWith(u8, exe, "./")) exe[2..] else exe;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, rel }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Tear-down for the post_installed set + per-game download-attempts
/// map + running-games map. Called from runMainLoop's defer block.
pub fn freePostInstalled(state: *State, alloc: std.mem.Allocator) void {
    if (state.post_installed) |set_ptr| {
        set_ptr.deinit();
        alloc.destroy(set_ptr);
        state.post_installed = null;
    }
    if (state.download_attempts) |map_ptr| {
        map_ptr.deinit();
        alloc.destroy(map_ptr);
        state.download_attempts = null;
    }
    launch_mod.freeRunningGames(state, alloc);
}
