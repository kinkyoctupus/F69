// Per-game download flows:
//   - `doDownloadGame` — recipe → downloads.Manager, with rotating
//     source-fallback baked in (`enqueueOneSource` / `tryNextSource`).
//   - RPDL flow (Tier 2): worker thread → search dl.rpdl.net → fetch
//     torrent → enqueue via aria2.
//   - Donor DDL (Tier 1): POST /sam/dddl.php for a signed URL → aria2
//     HTTP enqueue, with one auto-retry per expired URL.
//   - `drainCompletedDownloads` — per-frame consumer that hands each
//     just-finished download to the installer.zig post-install
//     pipeline.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const f95 = @import("f95");
const downloads = @import("downloads");
const recipe = @import("recipe");
const version_mod = @import("util_version");
const dvui = @import("dvui");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const common = @import("common.zig");
const installer_act = @import("installer.zig");

const Frame = types.Frame;
const State = types.State;

const DonorJobsMap = owned_types.DonorJobsMap;
const DonorRetriesMap = owned_types.DonorRetriesMap;
const DonorTickState = owned_types.DonorTickState;
const DonorTickLog = owned_types.DonorTickLog;

pub const RpdlDownloadPayload = owned_types.RpdlDownloadPayload;
pub const RpdlDownloadJob = owned_types.RpdlDownloadJob;
pub const DonorDownloadJob = owned_types.DonorDownloadJob;

// ============================================================
//  RPDL auto-download (Tier 2)
// ============================================================
//
// Per-game flow: search dl.rpdl.net by sanitized game name + parsed
// version → pick best torrent → fetch .torrent bytes → enqueue via
// downloads.Manager.enqueueTorrent → aria2 leeches + seeds (ratio
// 2.0 from daemon-wide defaults). All network work runs on a
// detached worker thread; `drainRpdlDownload` finishes the handoff
// on the UI thread.

/// Spawn the RPDL search → fetch worker. No-op when:
///   - another RPDL job is already running for any game (we
///     serialise to keep aria2's accept-rate sane);
///   - the user isn't logged into RPDL (the .torrent download
///     needs the bearer token).
pub fn startRpdlDownload(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    log.info("startRpdlDownload: ENTRY tid={d} name='{s}'", .{ game.f95_thread_id, game.name });

    if (state.pending_rpdl_download != null) {
        log.warn("startRpdlDownload: REFUSED — pending_rpdl_download already set (job in flight)", .{});
        state.setDownloadMsg("another RPDL download is already starting…");
        return;
    }
    const token = state.rpdl_token orelse {
        log.warn("startRpdlDownload: REFUSED — no RPDL token", .{});
        state.setDownloadMsg("RPDL: not logged in — open Settings → Accounts → RPDL");
        return;
    };
    if (token.len == 0) {
        log.warn("startRpdlDownload: REFUSED — token len=0", .{});
        state.setDownloadMsg("RPDL: token is empty — re-login");
        return;
    }
    log.info(
        "startRpdlDownload: PROCEEDING tid={d} name='{s}' version={?s} token={d}b",
        .{ game.f95_thread_id, game.name, game.latest_version, token.len },
    );

    const alloc = frame.lib.alloc;
    const name_dup = alloc.dupe(u8, game.name) catch {
        log.err("startRpdlDownload: name dupe OOM", .{});
        return;
    };
    const token_dup = alloc.dupe(u8, token) catch {
        log.err("startRpdlDownload: token dupe OOM", .{});
        alloc.free(name_dup);
        return;
    };
    const version_dup: ?[]u8 = if (game.latest_version) |v| (alloc.dupe(u8, v) catch null) else null;

    _ = job_mod.spawnJob(
        RpdlDownloadPayload,
        rpdlDownloadWorker,
        alloc,
        frame.win,
        .{
            .io = frame.io,
            .token = token_dup,
            .game_name = name_dup,
            .game_version = version_dup,
            .thread_id = game.f95_thread_id,
        },
        &state.pending_rpdl_download,
    ) catch |e| {
        log.err("startRpdlDownload: job alloc/spawn failed: {s}", .{@errorName(e)});
        alloc.free(name_dup);
        alloc.free(token_dup);
        if (version_dup) |v| alloc.free(v);
        return;
    };
    log.info("startRpdlDownload: worker thread spawned + detached", .{});
    log.info("startRpdlDownload: state.pending_rpdl_download set — awaiting drain", .{});
    var msg_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&msg_buf, "RPDL: searching for '{s}'…", .{game.name}) catch "RPDL: searching…";
    state.setDownloadMsg(m);
}

fn rpdlDownloadWorker(job: *RpdlDownloadJob) void {
    const p = &job.payload;
    const fail = struct {
        fn run(j: *RpdlDownloadJob, err: []const u8) void {
            j.payload.err_name = err;
            j.markFailed();
        }
    }.run;

    const t_search = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} starting search for '{s}'", .{ p.thread_id, p.game_name });
    const results = downloads.rpdl.search(job.alloc, p.io, p.game_name) catch |e| {
        log.warn("rpdl search failed: {s}", .{@errorName(e)});
        fail(job, @errorName(e));
        return;
    };
    defer downloads.rpdl.freeSearchResults(job.alloc, results);
    const t_after_search = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} search_ms={d} returned {d} result(s)", .{ p.thread_id, t_after_search - t_search, results.len });

    if (results.len == 0) {
        log.warn("rpdl worker: tid={d} no search results", .{p.thread_id});
        fail(job, "NoMatches");
        return;
    }

    const ver_opt: ?[]const u8 = if (p.game_version) |v| v else null;
    const picked = downloads.rpdl.pickBestMatch(results, p.game_name, ver_opt) orelse {
        log.warn("rpdl worker: tid={d} all candidates rejected (zero-seed or name mismatch)", .{p.thread_id});
        fail(job, "NoSeeders");
        return;
    };

    p.picked_id = picked.id;
    p.picked_title = job.alloc.dupe(u8, picked.title) catch {
        fail(job, "OutOfMemory");
        return;
    };

    log.info("rpdl worker: tid={d} fetching .torrent for picked id={d}", .{ p.thread_id, picked.id });
    const t_fetch = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    const bytes = downloads.rpdl.fetchTorrent(job.alloc, p.io, p.token, picked.id) catch |e| {
        log.warn("rpdl fetchTorrent failed: {s}", .{@errorName(e)});
        fail(job, @errorName(e));
        return;
    };
    const t_done = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} fetched {d} torrent bytes in {d}ms (total elapsed {d}ms)", .{
        p.thread_id, bytes.len, t_done - t_fetch, t_done - t_search,
    });
    p.torrent_bytes = bytes;
    job.markDone();
}

/// Drain the RPDL search/fetch worker each frame. On done: hand the
/// .torrent bytes to the download Manager (which spawns aria2 if
/// needed). On failed: surface the error in `download_msg`.
pub fn drainRpdlDownload(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        RpdlDownloadPayload,
        onRpdlDownloadDone,
        onRpdlDownloadFailed,
        frame,
        &frame.state.pending_rpdl_download,
    );
}

fn freeRpdlPayload(job: *RpdlDownloadJob) void {
    const p = &job.payload;
    job.alloc.free(p.token);
    job.alloc.free(p.game_name);
    if (p.game_version) |v| job.alloc.free(v);
    if (p.picked_title) |t| job.alloc.free(t);
    if (p.torrent_bytes) |b| job.alloc.free(b);
}

fn onRpdlDownloadFailed(frame: *Frame, job: *RpdlDownloadJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeRpdlPayload(job);
    log.info("drainRpdlDownload: observed phase=failed tid={d}", .{p.thread_id});
    var emsg: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "RPDL: {s}", .{rpdlErrorMessage(p.err_name orelse "?")}) catch "RPDL failed";
    state.setDownloadMsg(m);
}

fn onRpdlDownloadDone(frame: *Frame, job: *RpdlDownloadJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeRpdlPayload(job);
    log.info("drainRpdlDownload: observed phase=done tid={d}", .{p.thread_id});

    const bytes = p.torrent_bytes orelse {
        state.setDownloadMsg("RPDL: internal error — no torrent bytes");
        return;
    };

    // Hand off to the download manager. aria2 will pick up our
    // daemon-wide --seed-ratio / --enable-dht defaults.
    // Capture the RPDL-derived version from the torrent title so the
    // install row records the exact build the user downloaded.
    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "rpdl:{d}", .{p.picked_id}) catch "rpdl";
    const picked_version: ?[]const u8 = if (p.picked_title) |t|
        version_mod.extractFromTitle(t)
    else
        null;
    if (picked_version) |v| {
        log.info("rpdl: tid={d} captured version='{s}' from torrent title", .{ p.thread_id, v });
    } else {
        log.warn("rpdl: tid={d} no version segment in torrent title", .{p.thread_id});
    }
    const dl_id = frame.dl_mgr.enqueueTorrent(label, bytes, .game, p.thread_id, null, null, picked_version) catch |e| {
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "RPDL: enqueue failed: {s}", .{@errorName(e)}) catch "RPDL: enqueue failed";
        state.setDownloadMsg(m);
        return;
    };

    var ok_buf: [192]u8 = undefined;
    const title = p.picked_title orelse "(unknown title)";
    const m = std.fmt.bufPrint(
        &ok_buf,
        "RPDL: queued '{s}' (torrent #{d}) as download {d} — seeding to 2.0 ratio when done",
        .{ title, p.picked_id, dl_id },
    ) catch "RPDL: queued";
    state.setDownloadMsg(m);
}

/// Human-friendly error names for the RPDL flow. Falls through to
/// the raw `@errorName` when we don't recognise the cause.
fn rpdlErrorMessage(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "NoMatches")) return "no torrents found for this game";
    if (std.mem.eql(u8, name, "NoSeeders")) return "torrent has zero seeders — try again later";
    if (std.mem.eql(u8, name, "AuthRequired")) return "RPDL token rejected — re-login in Settings";
    if (std.mem.eql(u8, name, "NotFound")) return "torrent id not found on RPDL";
    if (std.mem.eql(u8, name, "NetworkError")) return "network error — check your connection";
    if (std.mem.eql(u8, name, "RpdlInvalidResponse")) return "RPDL returned an unexpected response";
    if (std.mem.eql(u8, name, "OutOfMemory")) return "out of memory";
    return name;
}


// ============================================================
//  Donor DDL (Tier 1) — POST /sam/dddl.php → aria2 enqueue
// ============================================================
//
// Per-game flow for users with an F95 donor account:
//   1. POST `/sam/dddl.php` with `thread_id=<tid>` and the session
//      cookie. Worker thread does this off the UI thread.
//   2. Response carries a short-lived signed URL pointing at
//      `attachments.f95zone.to`.
//   3. UI thread hands the URL to `dl_mgr.enqueueUrl` — aria2
//      downloads via HTTP, with Range-based resume support.
//
// Re-request handling: signed URLs have a TTL (observed at a few
// hours). When an aria2 job we marked as "donor-sourced" fails, the
// drain logic POSTs again for a fresh URL and re-enqueues — capped
// at MAX_DONOR_AUTO_RETRIES per thread per session so a permanently
// dead URL doesn't spin forever.

const DonorDownloadPhase = enum(u8) { pending, done, failed };
const MAX_DONOR_AUTO_RETRIES: u8 = 2;

// `DonorJobsMap` / `DonorRetriesMap` aliased from `owned.zig` at the
// top of the file. See module-doc comment in `src/ui/owned.zig` for
// the type-shape rationale.

fn donorJobsMap(frame: *Frame) *DonorJobsMap {
    if (frame.state.donor_jobs) |p| return p;
    const m = frame.lib.alloc.create(DonorJobsMap) catch unreachable;
    m.* = DonorJobsMap.init(frame.lib.alloc);
    frame.state.donor_jobs = m;
    return m;
}

fn donorRetriesMap(frame: *Frame) *DonorRetriesMap {
    if (frame.state.donor_retries) |p| return p;
    const m = frame.lib.alloc.create(DonorRetriesMap) catch unreachable;
    m.* = DonorRetriesMap.init(frame.lib.alloc);
    frame.state.donor_retries = m;
    return m;
}

pub fn freeDonorTables(state: *State, alloc: std.mem.Allocator) void {
    if (state.donor_jobs) |m| {
        m.deinit();
        alloc.destroy(m);
        state.donor_jobs = null;
    }
    if (state.donor_retries) |m| {
        m.deinit();
        alloc.destroy(m);
        state.donor_retries = null;
    }
    if (state.donor_tick_log) |m| {
        // Free the duped `last_error_msg` slices each entry owns.
        var it = m.valueIterator();
        while (it.next()) |entry| if (entry.last_error_msg) |s| alloc.free(s);
        m.deinit();
        alloc.destroy(m);
        state.donor_tick_log = null;
    }
}

fn donorTickLogPtr(frame: *Frame) *DonorTickLog {
    if (frame.state.donor_tick_log) |p| return p;
    const m = frame.lib.alloc.create(DonorTickLog) catch unreachable;
    m.* = DonorTickLog.init(frame.lib.alloc);
    frame.state.donor_tick_log = m;
    return m;
}

/// Per-frame helper: emits verbose telemetry for every in-flight
/// donor download. Throttled so a healthy 20-second download only
/// prints ~7 lines; stalls and aria2 errorMessage changes flush
/// immediately. Called from `guiFrame`.
/// Module-level state for the "how many donor jobs are we
/// tracking?" heartbeat — logs once when the count changes so the
/// user can see telemetry is active.
var donor_telemetry_last_count: usize = std.math.maxInt(usize);

pub fn drainDonorTelemetry(frame: *Frame) void {
    const state = frame.state;
    if (state.donor_jobs == null) {
        if (donor_telemetry_last_count != 0) {
            log.info("donor telemetry: 0 jobs tracked (no donor downloads registered yet)", .{});
            donor_telemetry_last_count = 0;
        }
        return;
    }
    const donor_set = donorJobsMap(frame);
    const n = donor_set.count();
    if (n != donor_telemetry_last_count) {
        log.info("donor telemetry: tracking {d} donor job(s)", .{n});
        donor_telemetry_last_count = n;
    }
    if (n == 0) return;
    const log_state = donorTickLogPtr(frame);
    const alloc = frame.lib.alloc;
    const now_ms = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toMilliseconds();

    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        const job = entry.value_ptr.*;
        if (!donor_set.contains(job.id)) continue;
        // Don't bother with permanently-terminated states — the
        // status-transition log in manager.tick() is sufficient.
        switch (job.status) {
            .done, .failed, .cancelled => continue,
            else => {},
        }

        const entry_ptr = log_state.getOrPut(job.id) catch continue;
        if (!entry_ptr.found_existing) entry_ptr.value_ptr.* = .{};
        const t = entry_ptr.value_ptr;

        // 1. aria2 errorMessage transitions — flush immediately.
        const cur_err = job.error_msg;
        const prev_err = t.last_error_msg;
        const err_changed = blk: {
            if (cur_err == null and prev_err == null) break :blk false;
            if (cur_err == null or prev_err == null) break :blk true;
            break :blk !std.mem.eql(u8, cur_err.?, prev_err.?);
        };
        if (err_changed) {
            if (t.last_error_msg) |s| alloc.free(s);
            t.last_error_msg = if (cur_err) |s| (alloc.dupe(u8, s) catch null) else null;
            if (cur_err) |s| {
                log.warn("donor tick job={d} aria2 errorMessage changed → '{s}'", .{ job.id, s });
            } else {
                log.info("donor tick job={d} aria2 errorMessage cleared", .{job.id});
            }
        }

        // 2. Stall detection — toggle stalled_since on 0 B/s while
        // the payload isn't complete, and log every transition.
        const has_payload = job.bytes_total != null and (job.bytes_total.? > 0);
        const at_zero = job.download_speed == 0;
        const not_complete = !has_payload or job.bytes_done < (job.bytes_total orelse 0);
        if (at_zero and not_complete and job.status != .seeding) {
            if (t.stalled_since_ms == null) {
                t.stalled_since_ms = now_ms;
                log.warn("donor tick job={d} STALLED at {d} bytes (aria2 status={s}, connections={d})", .{
                    job.id, job.bytes_done, @tagName(job.status), job.connections,
                });
            }
        } else if (t.stalled_since_ms) |since| {
            log.info("donor tick job={d} stall ended after {d} ms (speed={d} B/s)", .{
                job.id, now_ms - since, job.download_speed,
            });
            t.stalled_since_ms = null;
        }

        // 3. Periodic detailed status — every 3 seconds.
        const log_interval_ms: i64 = 3000;
        if (now_ms - t.last_log_ms >= log_interval_ms) {
            const elapsed_ms = if (t.last_log_ms == 0) 0 else now_ms - t.last_log_ms;
            const bytes_delta: u64 = if (job.bytes_done > t.last_bytes) job.bytes_done - t.last_bytes else 0;
            const rolling_bps: u64 = if (elapsed_ms > 0)
                @as(u64, @intCast(@divTrunc(@as(i64, @intCast(bytes_delta)) * 1000, elapsed_ms)))
            else
                0;
            log.info(
                "donor tick job={d} tid={d} status={s} bytes={d}/{?d} pct={d}% aria_speed={d}B/s rolling={d}B/s connections={d} err={?s}",
                .{
                    job.id,
                    job.game_id,
                    @tagName(job.status),
                    job.bytes_done,
                    job.bytes_total,
                    if (job.bytes_total) |total| (if (total == 0) 0 else @as(u64, @intCast(@divTrunc(job.bytes_done * 100, total)))) else 0,
                    job.download_speed,
                    rolling_bps,
                    job.connections,
                    job.error_msg,
                },
            );
            t.last_log_ms = now_ms;
            t.last_bytes = job.bytes_done;
        }
    }
}

/// True iff `download_job_id` was registered as having come from a
/// donor-DDL signed URL. drainCompletedDownloads uses this to route
/// `.failed` jobs through the re-request path instead of the regular
/// "try next recipe source" fallback.
pub fn isDonorJob(frame: *Frame, download_job_id: u64) bool {
    if (frame.state.donor_jobs == null) return false;
    return donorJobsMap(frame).contains(download_job_id);
}

/// Kick off the donor-DDL fetch worker. No-op when:
///   - another donor job is already starting (we serialise so the
///     URL→enqueue handoff stays simple);
///   - the user has no F95 session cookie (the POST would 401).
pub fn startDonorDownload(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    log.info("startDonorDownload: ENTRY tid={d} name='{s}'", .{ game.f95_thread_id, game.name });

    if (state.pending_donor_download != null) {
        log.warn("startDonorDownload: REFUSED — pending_donor_download already set", .{});
        state.setDownloadMsg("donor DDL: another request is already in flight…");
        return;
    }
    if (state.login_status != .logged_in) {
        log.warn("startDonorDownload: REFUSED — not logged in (status={s})", .{@tagName(state.login_status)});
        state.setDownloadMsg("donor DDL: log into F95 first (Settings → Accounts)");
        return;
    }
    log.info("startDonorDownload: PROCEEDING tid={d}", .{game.f95_thread_id});

    const alloc = frame.lib.alloc;
    const name_dup = alloc.dupe(u8, game.name) catch {
        log.err("startDonorDownload: name dupe OOM", .{});
        return;
    };
    const version_dup: ?[]u8 = if (game.latest_version) |v| (alloc.dupe(u8, v) catch null) else null;

    const job = alloc.create(DonorDownloadJob) catch {
        log.err("startDonorDownload: job alloc OOM", .{});
        alloc.free(name_dup);
        if (version_dup) |v| alloc.free(v);
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(DonorDownloadPhase.pending)),
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .f95_client = frame.f95_svc.client,
        .game_name = name_dup,
        .game_version = version_dup,
        .thread_id = game.f95_thread_id,
    };

    job.thr = std.Thread.spawn(.{}, donorDownloadWorker, .{job}) catch |e| {
        log.err("startDonorDownload: thread spawn failed: {s}", .{@errorName(e)});
        alloc.free(job.game_name);
        if (job.game_version) |v| alloc.free(v);
        alloc.destroy(job);
        return;
    };
    job.thr.detach();
    log.info("startDonorDownload: worker thread spawned + detached", .{});

    state.pending_donor_download = job;
    log.info("startDonorDownload: state.pending_donor_download set — awaiting drain", .{});
    var msg_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&msg_buf, "donor DDL: requesting signed URL for '{s}'…", .{game.name}) catch "donor DDL: requesting…";
    state.setDownloadMsg(m);
}

fn donorDownloadWorker(job: *DonorDownloadJob) void {
    const fail = struct {
        fn run(j: *DonorDownloadJob, err: []const u8) void {
            j.err_name = err;
            j.phase.store(@intFromEnum(DonorDownloadPhase.failed), .release);
            dvui.refresh(j.win, @src(), null);
        }
    }.run;

    log.info("donor worker: tid={d} starting two-step DDL flow", .{job.thread_id});
    const dl = f95.donor_ddl.requestDownload(job.alloc, job.f95_client, job.thread_id) catch |e| {
        log.warn("donor worker: tid={d} flow failed: {s}", .{ job.thread_id, @errorName(e) });
        fail(job, @errorName(e));
        return;
    };
    log.info(
        "donor worker: tid={d} got URL+cookie (url-len={d}, cookie-len={d}, file='{s}')",
        .{ job.thread_id, dl.url.len, dl.cookie.len, dl.filename },
    );
    job.signed_url = dl.url;
    job.signed_cookie = dl.cookie;
    job.signed_filename = dl.filename;
    job.phase.store(@intFromEnum(DonorDownloadPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

pub fn drainDonorDownload(frame: *Frame) void {
    const state = frame.state;
    const job = state.pending_donor_download orelse return;
    const phase: DonorDownloadPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;
    log.info("drainDonorDownload: observed phase={s} tid={d}", .{ @tagName(phase), job.thread_id });

    const cleanup = struct {
        fn run(j: *DonorDownloadJob, s: *State) void {
            j.alloc.free(j.game_name);
            if (j.game_version) |v| j.alloc.free(v);
            if (j.signed_url) |u| j.alloc.free(u);
            if (j.signed_cookie) |c| j.alloc.free(c);
            if (j.signed_filename) |fn_| j.alloc.free(fn_);
            j.alloc.destroy(j);
            s.pending_donor_download = null;
        }
    }.run;

    if (phase == .failed) {
        var emsg: [160]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "donor DDL: {s}", .{donorErrorMessage(job.err_name orelse "?")}) catch "donor DDL failed";
        state.setDownloadMsg(m);
        cleanup(job, state);
        return;
    }

    const url = job.signed_url orelse {
        state.setDownloadMsg("donor DDL: internal error — no signed URL");
        cleanup(job, state);
        return;
    };

    // Build the `Cookie:` header from the per-URL cookie F95 handed
    // back on step 2. Without these on every GET (and every aria2
    // retry), the attachments.f95zone.to CDN 403s. The header list
    // is built on the stack; aria2 sees just one header for now.
    var cookie_hdr_buf: [4096]u8 = undefined;
    const headers: []const []const u8 = blk: {
        const cookie = job.signed_cookie orelse break :blk &.{};
        if (cookie.len == 0) break :blk &.{};
        const hdr = std.fmt.bufPrint(&cookie_hdr_buf, "Cookie: {s}", .{cookie}) catch {
            log.warn("donor: cookie too large to fit in header buffer ({d} bytes); proceeding without it", .{cookie.len});
            break :blk &.{};
        };
        break :blk @as([]const []const u8, &.{hdr});
    };

    // Hand off to aria2 with donor-specific tuning:
    //   - Cookie header (mandatory; CDN 403s without it).
    //   - max-connection-per-server=8 + split=8 — aria2 defaults to 1
    //     stream per host which Cloudflare throttles harder than 4-8
    //     parallel streams. Most users observe 3-5x throughput.
    //   - retry-wait=3 — without it, transient 5xx triggers a tight
    //     retry loop that reads to the user as constant stalling.
    const http_opts: downloads.Aria2Daemon.UriOptions = .{
        .headers = headers,
        .max_connection_per_server = 8,
        .split = 8,
        .retry_wait = 3,
    };
    // Verbose enqueue log — useful when the user reports stuttering
    // / stalls. Captures the host the URL points at, how many bytes
    // of Cookie header we shipped, and which aria2 options we set.
    var url_host_buf: [128]u8 = undefined;
    const url_host = extractHostForLog(&url_host_buf, url);
    const cookie_len: usize = if (headers.len > 0) headers[0].len else 0;
    log.info(
        "donor enqueue: tid={d} host='{s}' url_len={d} cookie_hdr_len={d} version={?s} max_conn=8 split=8 retry_wait=3s",
        .{ job.thread_id, url_host, url.len, cookie_len, job.game_version },
    );
    const dl_id = frame.dl_mgr.enqueueUrl(url, .game, job.thread_id, null, null, job.game_version, http_opts) catch |e| {
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "donor DDL: enqueue failed: {s}", .{@errorName(e)}) catch "donor DDL: enqueue failed";
        state.setDownloadMsg(m);
        cleanup(job, state);
        return;
    };

    // Register the job-id ↔ thread-id mapping so on aria2 failure we
    // can re-POST for a fresh signed URL (the donor link has a TTL).
    donorJobsMap(frame).put(dl_id, job.thread_id) catch {};
    log.info("donor enqueue: tid={d} → aria2 job_id={d} (registered for URL-expiry retry)", .{ job.thread_id, dl_id });

    var ok_buf: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&ok_buf, "donor DDL: queued as download {d}", .{dl_id}) catch "donor DDL: queued";
    state.setDownloadMsg(m);

    cleanup(job, state);
}

/// Human-friendly error names for the donor-DDL flow.
/// Pull just the host segment out of a URL for log lines —
/// `https://attachments.f95zone.to/long/signed/path` → `attachments.f95zone.to`.
/// Falls back to `"?"` if the URL doesn't look like an http URL.
fn extractHostForLog(buf: []u8, url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "?";
    const host_start = scheme_end + 3;
    var host_end = host_start;
    while (host_end < url.len and url[host_end] != '/' and url[host_end] != '?') : (host_end += 1) {}
    const host = url[host_start..host_end];
    const n = @min(host.len, buf.len);
    @memcpy(buf[0..n], host[0..n]);
    return buf[0..n];
}

fn donorErrorMessage(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "AuthRequired")) return "F95 session expired — log in again";
    if (std.mem.eql(u8, name, "DonorNotEligible")) return "this F95 account isn't a donor — Tier-1 DDL requires a paid contribution";
    if (std.mem.eql(u8, name, "DonorNoDdl")) return "no donor DDL configured for this thread — try RPDL instead";
    if (std.mem.eql(u8, name, "DonorInvalidResponse")) return "F95 returned an unexpected response (endpoint changed?)";
    if (std.mem.eql(u8, name, "NotFound")) return "F95 says this thread doesn't exist";
    if (std.mem.eql(u8, name, "NetworkError")) return "network error — check your connection";
    if (std.mem.eql(u8, name, "OutOfMemory")) return "out of memory";
    return name;
}

/// Attempt to re-request a fresh signed URL for a donor job whose
/// aria2 download just failed (likely a TTL expiry). Returns true
/// when a retry was kicked off; false when retry is unavailable
/// (not a donor job, already at retry cap, another donor request in
/// flight, etc).
pub fn maybeRetryDonorJob(frame: *Frame, download_job_id: u64) bool {
    const state = frame.state;
    if (state.donor_jobs == null) return false;
    const jobs = donorJobsMap(frame);
    const thread_id = jobs.get(download_job_id) orelse return false;
    _ = jobs.remove(download_job_id);

    // Snapshot the failed job's progress + last aria2 errorMessage
    // so the retry log line shows the user where the previous
    // attempt died.
    var failed_bytes_done: u64 = 0;
    var failed_bytes_total: ?u64 = null;
    var failed_err_msg: ?[]const u8 = null;
    if (frame.dl_mgr.jobs.get(download_job_id)) |j| {
        failed_bytes_done = j.bytes_done;
        failed_bytes_total = j.bytes_total;
        failed_err_msg = j.error_msg;
    }

    // Bound retries per thread so a permanently expired URL doesn't
    // pin a worker forever.
    const retries = donorRetriesMap(frame);
    const tries = (retries.get(thread_id) orelse 0) + 1;
    if (tries > MAX_DONOR_AUTO_RETRIES) {
        log.warn("donor retry: tid={d} exceeded {d} attempts, giving up", .{ thread_id, MAX_DONOR_AUTO_RETRIES });
        var emsg: [160]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "donor DDL: download failed after {d} retries — try Download again", .{tries - 1}) catch "donor DDL: retries exhausted";
        state.setDownloadMsg(m);
        return false;
    }
    retries.put(thread_id, tries) catch {};

    if (state.pending_donor_download != null) {
        log.info("donor retry: tid={d} queued behind in-flight donor job", .{thread_id});
        return false; // drain will re-evaluate next frame
    }

    // Find the matching library row so startDonorDownload has a name
    // to log.
    var target: ?*library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == thread_id) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        log.warn("donor retry: tid={d} no longer in library", .{thread_id});
        return false;
    };

    log.info(
        "donor retry: tid={d} attempt {d}/{d} — re-POSTing for fresh URL (downloaded={d}/{?d} before failure, err={?s})",
        .{
            thread_id,
            tries,
            MAX_DONOR_AUTO_RETRIES,
            failed_bytes_done,
            failed_bytes_total,
            failed_err_msg,
        },
    );
    startDonorDownload(frame, game);
    return true;
}

/// True iff the Manager has a job tied to this F95 thread that is
/// still active (anything but the terminal `done` / `failed` /
/// `cancelled` set). The detail page's Download button uses this to
/// swap its label to "View download" and route to the downloads
/// screen instead of starting a duplicate fetch.
pub fn hasActiveDownloadForGame(frame: *Frame, thread_id: u64) bool {
    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        const j = entry.value_ptr.*;
        if (j.game_id != thread_id) continue;
        switch (j.status) {
            .done, .failed, .cancelled => continue,
            else => return true,
        }
    }
    return false;
}

/// Return a snapshot of the first leeching/queued job tied to this
/// game. Skips `.seeding` because the payload is already complete
/// (we don't want the detail-page progress bar showing once the user
/// can actually play). Returns null when nothing is in flight.
pub fn findLeechingJobForGame(frame: *Frame, thread_id: u64) ?downloads.Job {
    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        const j = entry.value_ptr.*;
        if (j.game_id != thread_id) continue;
        switch (j.status) {
            .queued, .fetching_metadata, .downloading, .verifying => return j,
            else => continue,
        }
    }
    return null;
}


// ============================================================
//  per-game download — recipe → downloads.Manager
// ============================================================

/// Look up the recipe for `game`. If found, enqueue the *first*
/// resolvable source via the Manager. RPDL goes via
/// `rpdl.fetchTorrent` → `Manager.enqueueTorrent`; ddl / mirror
/// sources go straight to `Manager.enqueueUrl`.
///
/// On success: routes to the Downloads screen so the user sees the
/// new job in flight. On failure: writes a one-line message to
/// `state.download_msg_buf` and stays on the detail screen.
///
/// Sync — RPDL fetch + aria2 RPC together typically settle in well
/// under a second on localhost. Worker offload comes when we move
/// off the first-source heuristic and try every fallback in turn.
pub fn doDownloadGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    const parsed_opt = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Recipe lookup failed: {s}", .{@errorName(e)}) catch "Recipe lookup failed";
        state.setDownloadMsg(msg);
        return;
    };
    var parsed = parsed_opt orelse {
        state.setDownloadMsg("No recipe for this game. Drop one in <config>/f69/recipes/<id>.game.zon");
        return;
    };
    defer parsed.deinit();

    if (parsed.recipe.sources.len == 0) {
        state.setDownloadMsg("Recipe has no sources defined.");
        return;
    }

    // Start the fallback chain at source index 0; the `.failed`
    // observer bumps this on each mirror failure.
    common.resetAttempt(frame, game.f95_thread_id);
    const src = parsed.recipe.sources[0];

    const job_id = enqueueOneSource(frame, src, .game, game.f95_thread_id, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Download failed: {s}", .{@errorName(e)}) catch "Download failed";
        state.setDownloadMsg(msg);
        return;
    };

    var ok_buf: [160]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Queued download (job {d}) — see Downloads", .{job_id}) catch "Queued download";
    state.setDownloadMsg(ok_msg);
    state.screen = .downloads;
}

pub fn enqueueOneSource(
    frame: *Frame,
    src: recipe.Source,
    kind: downloads.JobKind,
    game_id: u64,
    mod_id: ?u64,
) !u64 {
    // Look up the game so recipe-source enqueues record the
    // currently-scraped version on the Job. Recipe sources don't
    // carry a version field themselves; the library row is the
    // best source of truth for "what version did the user click
    // Download for?".
    const game_version: ?[]const u8 = blk: {
        for (frame.games) |*g| {
            if (g.f95_thread_id == game_id) break :blk g.latest_version;
        }
        break :blk null;
    };
    switch (src) {
        .rpdl => |x| {
            const token = frame.state.rpdl_token orelse return error.RpdlTokenMissing;
            const bytes = try downloads.rpdl.fetchTorrent(frame.lib.alloc, frame.io, token, x.id);
            defer frame.lib.alloc.free(bytes);
            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "rpdl:{d}", .{x.id}) catch "rpdl";
            return try frame.dl_mgr.enqueueTorrent(label, bytes, kind, game_id, mod_id, null, game_version);
        },
        .ddl => |x| {
            const sha = downloads.hexDecode(x.sha256) catch null;
            return try frame.dl_mgr.enqueueUrl(x.url, kind, game_id, mod_id, sha, game_version, .{});
        },
        .mirror => |x| {
            const sha = if (x.sha256) |h| (downloads.hexDecode(h) catch null) else null;
            return try frame.dl_mgr.enqueueUrl(x.url, kind, game_id, mod_id, sha, game_version, .{});
        },
    }
}


pub fn drainCompletedDownloads(frame: *Frame) void {
    const seen = installer_act.postInstalledSet(frame);

    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        const job = entry.value_ptr;
        // `.seeding` jobs have their full payload on disk — aria2
        // doesn't flip them to `.done` until the seed-ratio target
        // is met, which can be hours later. We don't want to make
        // the user wait that long to play; trigger post-install
        // the moment leeching wraps. The seed continues in parallel.
        const ready = switch (job.status) {
            .done, .seeding, .failed => true,
            else => false,
        };
        if (!ready) continue;
        if (job.game_id == 0) continue; // raw paste — no destination / no recipe
        if (seen.contains(job.id)) continue;
        seen.put(job.id, {}) catch {};

        switch (job.status) {
            .done, .seeding => switch (job.kind) {
                .game => installer_act.startPostInstall(frame, job.id, job.game_id, job.expected_sha256) catch |e| {
                    log.warn("post-install start for game-job {d} failed: {s}", .{ job.id, @errorName(e) });
                },
                .mod => installer_act.postInstallMod(frame, job.id, job.game_id, job.mod_id) catch |e| {
                    log.warn("post-install for mod-job {d} failed: {s}", .{ job.id, @errorName(e) });
                },
            },
            .failed => {
                // Donor-DDL signed URLs have a TTL (a few hours).
                // When the URL expires the aria2 download fails with
                // an auth/forbidden error — give it one auto-retry by
                // POSTing for a fresh URL. Only when the retry path
                // refuses (not a donor job, retry cap exhausted) do
                // we fall through to the recipe-source rotator.
                if (maybeRetryDonorJob(frame, job.id)) {
                    log.info("donor retry: kicked off fresh signed URL request for game {d}", .{job.game_id});
                } else {
                    installer_act.tryNextSource(frame, job.game_id) catch |e| {
                        log.warn("fallback for game {d} failed: {s}", .{ job.game_id, @errorName(e) });
                    };
                }
            },
            else => unreachable,
        }
    }
}
