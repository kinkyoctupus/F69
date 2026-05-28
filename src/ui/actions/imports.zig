// External-library importers (F95Checker + xLibrary) and the
// recurring update-check job (scan F95's latest-updates pages,
// enqueue matching tids into the sync queue).

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const f95 = @import("f95");
const dvui = @import("dvui");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const import_job = @import("../import_job.zig");
const importers_mod = @import("importers");
const file_picker = @import("util_file_picker");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const common = @import("common.zig");
const sync_act = @import("sync.zig");

const Frame = types.Frame;
const State = types.State;

pub const UpdateCheckPayload = owned_types.UpdateCheckPayload;
pub const UpdateCheckJob = owned_types.UpdateCheckJob;

// ============================================================
//  update check — walk F95's latest-updates pages
// ============================================================
//
// Replaces the previous bulk-version-check approach (one HTTP call
// per 100 library games) with a much smaller scan: walk F95's
// `/sam/latest_alpha/latest_data.php` pages newest → oldest, stop
// when we hit entries older than `last_update_check_ts`. For each
// entry whose `thread_id` is in our library, queue a sync. Mirrors
// the user's mental model — "show me what changed since I last
// checked", not "ask the server about every game".

/// Hard cap on pages walked per category so a misconfigured stamp
/// can't drag us through F95's entire history. 90 entries × 30
/// pages = 2700 most-recent threads per category, plenty for any
/// realistic check interval.
const UPDATE_WALK_MAX_PAGES: u32 = 30;

/// On first run (no persisted stamp), pretend we last checked this
/// long ago. 14 days × 86400 seconds = ~1.2 M; comfortably covers
/// the average user's catch-up window without scanning forever.
const UPDATE_WALK_FIRST_RUN_LOOKBACK_S: i64 = 14 * 24 * 60 * 60;

/// "Check for updates" — discovers which library games have changes
/// since the last refresh and queues them for sync.
///
/// In **scraper** mode this walks F95's `/sam/latest_alpha/...` pages
/// newest → oldest, stops at `last_update_check_ts`, and queues any
/// mismatched tid for a sync.
///
/// In **indexer** mode the latest-updates walker would be direct forum
/// scraping, which the strict 2-mode separation forbids. The indexer's
/// `/fast` endpoint already exposes a per-game `last_change`, so the
/// indexer-equivalent of "check for updates" is the batched `/fast`
/// pre-flight that already powers Refresh All: it visits every game's
/// `last_change`, filters to the ones whose value moved, and queues
/// only those for `/full`. Routing the button there is the natural
/// indexer-mode behavior — same semantics, zero forum traffic.
pub fn startUpdateCheck(frame: *Frame) void {
    const state = frame.state;
    if (state.refresh_backend == .indexer) {
        // Mirrors the Refresh All flow under the hood; both buttons
        // route to the same batched `/fast` pre-flight + parallel
        // `/full` pool in indexer mode.
        sync_act.startSyncAll(frame);
        return;
    }
    if (state.pending_update_check != null) return;
    // Fresh user-initiated batch — un-suspend image fetches in case
    // a previous Cancel left the cascade flag set.
    state.image_fetch_suspended = false;
    // Block the update walk while the bookmark importer is still
    // adding games. The walker snapshots the library tid set up
    // front, so starting mid-import would scan against an incomplete
    // snapshot AND race the bookmark drain when it later kicks
    // `startSyncAll`. Make the user wait for bookmarks to finish.
    if (state.pending_bookmarks != null) {
        state.sync_status = .ok;
        state.setSyncMsg("bookmarks import is running — try again when it finishes");
        return;
    }
    // Fresh batch — wipe stale recap entries so the end-of-batch
    // popup only lists what *this* check discovered.
    sync_act.clearSyncRecap(frame);
    if (frame.games.len == 0) {
        state.sync_status = .ok;
        state.setSyncMsg("library empty — nothing to check");
        return;
    }

    const alloc = frame.lib.alloc;

    // Materialize the library tid set up front so the worker doesn't
    // need access to the games slice (which can be reloaded mid-sync).
    var set: std.AutoHashMap(u64, void) = .init(alloc);
    set.ensureTotalCapacity(@intCast(frame.games.len)) catch {
        set.deinit();
        return;
    };
    for (frame.games) |g| set.put(g.f95_thread_id, {}) catch {};

    // Cut-off: persisted timestamp, OR (first run) "now - 14 days"
    // so we don't scan years of F95 history on the first click.
    const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
    const since: i64 = if (state.last_update_check_ts > 0)
        state.last_update_check_ts
    else
        now_s - UPDATE_WALK_FIRST_RUN_LOOKBACK_S;

    _ = job_mod.spawnJob(
        UpdateCheckPayload,
        updateCheckWorker,
        alloc,
        frame.win,
        .{
            .f95_svc = frame.f95_svc,
            .io = frame.io,
            .library_set = set,
            .since_ts = since,
            .mismatch_tids = .empty,
        },
        &state.pending_update_check,
    ) catch {
        set.deinit();
        return;
    };

    state.setSyncMsg("scanning F95 latest updates…");
    state.sync_status = .running;
}

fn updateCheckWorker(job: *UpdateCheckJob) void {
    const p = &job.payload;
    var url_buf: [256]u8 = undefined;
    var page: u32 = 1;
    var done: bool = false;

    while (!done and page <= UPDATE_WALK_MAX_PAGES) {
        if (job.cancelRequested()) {
            p.err_name = "Cancelled";
            job.markFailed();
            return;
        }
        // ts query param is just a cache-buster; the response is the
        // same regardless. Stamp it with the current second so we
        // don't accidentally hit a stale CDN copy.
        const cache_buster = std.Io.Clock.Timestamp.now(p.io, .real).raw.toSeconds();
        const url = std.fmt.bufPrint(
            &url_buf,
            "https://f95zone.to/sam/latest_alpha/latest_data.php?cmd=list&cat=games&page={d}&sort=date&rows=90&_={d}",
            .{ page, cache_buster },
        ) catch {
            p.err_name = "InternalUrlBuild";
            job.markFailed();
            return;
        };

        const body = p.f95_svc.client.get(url) catch |e| {
            p.err_name = @errorName(e);
            job.markFailed();
            return;
        };
        defer job.alloc.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, job.alloc, body, .{}) catch |e| {
            log.warn("update-check parse failed page={d}: {s}", .{ page, @errorName(e) });
            // Treat as end-of-stream rather than failing — F95
            // sometimes returns HTML when overloaded.
            done = true;
            break;
        };
        defer parsed.deinit();

        // Entries live at `msg.data` and are an array of objects.
        const data_v = blk: {
            if (parsed.value != .object) break :blk null;
            const msg = parsed.value.object.get("msg") orelse break :blk null;
            if (msg != .object) break :blk null;
            break :blk msg.object.get("data");
        };
        const arr = if (data_v) |dv| switch (dv) {
            .array => |a| a,
            else => break,
        } else break;
        if (arr.items.len == 0) {
            done = true;
            break;
        }

        for (arr.items) |entry| {
            if (entry != .object) continue;
            const ts_v = entry.object.get("ts") orelse continue;
            const tid_v = entry.object.get("thread_id") orelse continue;
            const ts: i64 = parseJsonInt64(ts_v) orelse continue;
            const tid_signed: i64 = parseJsonInt64(tid_v) orelse continue;
            if (tid_signed <= 0) continue;
            const tid: u64 = @intCast(tid_signed);

            p.scanned += 1;
            if (ts > p.newest_seen_ts) p.newest_seen_ts = ts;

            if (ts < p.since_ts) {
                done = true;
                continue; // keep scanning the rest of this page for any newer entries that lagged in sort order
            }

            if (p.library_set.contains(tid)) {
                p.mismatch_tids.append(job.alloc, tid) catch {};
            }
        }

        page += 1;
    }

    job.markDone();
}

/// Decode a JSON value that might be `.integer` (when F95 returned a
/// number) or `.string` (when they returned a stringified number).
/// Returns null for anything else.
fn parseJsonInt64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Drain the latest-updates walker each frame. Mismatches go into
/// the sync queue and we persist `newest_seen_ts` so the next scan
/// can start exactly where this one left off.
pub fn drainUpdateCheck(frame: *Frame) void {
    const state = frame.state;
    const slot_was_set = state.pending_update_check != null;
    job_mod.drainBackgroundJob(
        UpdateCheckPayload,
        onUpdateCheckDone,
        onUpdateCheckFailed,
        frame,
        &state.pending_update_check,
    );
    if (!slot_was_set) return;
    if (state.pending_update_check != null) return;
    // Worker reached terminal phase. If a fresh queue was installed
    // (the onDone handler grew it), kick the sync chain.
    // After the walker finishes, refill the parallel sync slots from
    // the queue it built. Calling `advanceSyncQueue` is safe whether
    // or not workers are still in flight — it only fills empty slots.
    if (state.sync_queue != null) {
        sync_act.advanceSyncQueue(frame);
    }
}

fn onUpdateCheckFailed(frame: *Frame, job: *UpdateCheckJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeUpdateCheckPayload(job);
    const cancelled = p.err_name != null and std.mem.eql(u8, p.err_name.?, "Cancelled");
    if (cancelled) {
        // User-driven stop — silent like the sync/bookmark cancel.
        state.sync_status = .idle;
        state.sync_msg.clear();
        return;
    }
    var emsg: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "update check failed: {s}", .{common.friendlyError(p.err_name orelse "?")}) catch "update check failed";
    state.sync_status = .err;
    state.setSyncMsg(m);
}

fn onUpdateCheckDone(frame: *Frame, job: *UpdateCheckJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeUpdateCheckPayload(job);

    // De-dup the mismatch list — the same tid can appear twice if a
    // game was updated more than once within the check window.
    var seen: std.AutoHashMap(u64, void) = .init(frame.lib.alloc);
    defer seen.deinit();
    var uniques: std.ArrayList(u64) = .empty;
    defer uniques.deinit(frame.lib.alloc);
    for (p.mismatch_tids.items) |tid| {
        const r = seen.getOrPut(tid) catch break;
        if (r.found_existing) continue;
        uniques.append(frame.lib.alloc, tid) catch break;
    }

    // Always advance the stamp on success — even with zero hits, we
    // confirmed nothing happened in our library during the window.
    if (p.newest_seen_ts > 0) {
        state.last_update_check_ts = p.newest_seen_ts;
        persistInt64IfDirty(frame.info.last_update_check_path, frame.io, p.newest_seen_ts);
    } else {
        // Worker saw zero entries (rare — maybe F95 was down). Stamp
        // with "now" anyway so the next click doesn't re-scan the
        // same empty pages.
        const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
        state.last_update_check_ts = now_s;
        persistInt64IfDirty(frame.info.last_update_check_path, frame.io, now_s);
    }

    if (uniques.items.len == 0) {
        var ok_buf: [96]u8 = undefined;
        const m = std.fmt.bufPrint(&ok_buf, "no library updates ({d} F95 entries scanned)", .{p.scanned}) catch "no library updates";
        state.sync_status = .ok;
        state.setSyncMsg(m);
        return;
    }

    // Append to (or install) the sync queue.
    if (state.sync_queue) |q| {
        const new_q = frame.lib.alloc.realloc(q, q.len + uniques.items.len) catch return;
        @memcpy(new_q[q.len..], uniques.items);
        state.sync_queue = new_q;
        state.sync_queue_total += @intCast(uniques.items.len);
    } else {
        const owned = frame.lib.alloc.alloc(u64, uniques.items.len) catch return;
        @memcpy(owned, uniques.items);
        state.sync_queue = owned;
        state.sync_queue_idx = 0;
        state.sync_queue_started = 0;
        state.sync_queue_total = @intCast(uniques.items.len);
    }

    var m_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&m_buf, "queued {d} updates ({d} F95 entries scanned)", .{ uniques.items.len, p.scanned }) catch "queued updates";
    state.sync_status = .ok;
    state.setSyncMsg(m);
}

fn freeUpdateCheckPayload(job: *UpdateCheckJob) void {
    job.payload.library_set.deinit();
    job.payload.mismatch_tids.deinit(job.alloc);
}

/// Write `ts` as decimal text to `path`. Best-effort; logs and
/// returns on any error so a transient file-system hiccup doesn't
/// crash the UI thread.
fn persistInt64IfDirty(path: []const u8, io: std.Io, ts: i64) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{ts}) catch return;
    common.persistTextFile(io, path, text) catch |e| {
        log.warn("persist {s} failed: {s}", .{ path, @errorName(e) });
    };
}

// ============================================================
//  Import from F95Checker / xLibrary
// ============================================================

/// Click handler for Settings → "Import from F95Checker...". Routes
/// through the review screen so the user picks Move/Copy/Link at the
/// moment of import (and sees what's coming in) rather than relying
/// on whichever Settings-page toggle was last selected.
pub fn doImportFromF95Checker(frame: *Frame) void {
    doStartF95CheckerReview(frame);
}

/// Direct (non-review) import path. Kept for tests / scripted entry
/// points; the UI now always goes through the review screen.
pub fn doImportFromF95CheckerDirect(frame: *Frame) void {
    startImport(frame, .f95checker, stateModeToJobMode(frame.state.folder_scan_mode));
}

/// Stage 1 of the F95Checker import: open the picker, read the DB
/// READ-ONLY into a Bundle, populate review state, switch screen.
/// No file mutation here — `~/.config/f95checker` is never touched
/// by this path.
pub fn doStartF95CheckerReview(frame: *Frame) void {
    const state = frame.state;
    if (state.import_job != null) {
        state.notifyWarn("An import is already in flight — wait for it to finish.");
        return;
    }
    const alloc = frame.lib.alloc;

    const home = frame.info.host.home orelse {
        state.notifyErr("Couldn't read $HOME; can't locate the F95Checker DB.");
        return;
    };
    const data_path = buildConfigDataPath(alloc, .f95checker, home) catch {
        state.notifyErr("Out of memory resolving F95Checker DB path.");
        return;
    };
    errdefer alloc.free(data_path);

    std.Io.Dir.cwd().access(frame.io, data_path, .{}) catch {
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "F95Checker DB not found at {s}", .{data_path}) catch "F95Checker DB not found";
        state.notifyErr(msg);
        alloc.free(data_path);
        return;
    };

    const games_base_dir = file_picker.openFolder(alloc, null) catch |e| {
        alloc.free(data_path);
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed";
        state.notifyErr(msg);
        return;
    } orelse {
        alloc.free(data_path);
        return; // user cancelled
    };
    errdefer alloc.free(games_base_dir);

    // Reuse the same safety gate that the direct-import path uses —
    // games-base-dir must not be (or live under) any upstream tool's
    // config dir. The review path never deletes, but Apply will,
    // depending on mode; refusing here keeps the rule consistent.
    if (importTargetUnsafe(frame.io, alloc, games_base_dir, home)) |reason| {
        defer alloc.free(reason);
        var buf: [320]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Import refused: {s}. Pick your games folder, NOT your tool's config folder.", .{reason}) catch "Import refused: unsafe games-base-dir choice.";
        state.notifyErr(m);
        alloc.free(data_path);
        alloc.free(games_base_dir);
        return;
    }

    // Read the DB into a Bundle on the main thread. F95Checker DBs
    // for typical libraries (a few hundred rows) finish in well under
    // a frame; if a power-user complains we'll move this to a worker.
    const bundle_ptr = alloc.create(importers_mod.Bundle) catch {
        alloc.free(data_path);
        alloc.free(games_base_dir);
        state.notifyErr("Out of memory reading F95Checker DB.");
        return;
    };
    bundle_ptr.* = importers_mod.f95checker.loadFromDb(alloc, data_path) catch |e| {
        alloc.destroy(bundle_ptr);
        alloc.free(data_path);
        alloc.free(games_base_dir);
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Couldn't read F95Checker DB: {s}", .{@errorName(e)}) catch "Couldn't read F95Checker DB";
        state.notifyErr(msg);
        return;
    };

    // Clear any prior review state before storing new pointers — a
    // second click of "Import…" must not leak the previous bundle.
    freeF95Review(state, alloc);

    var installed_n: usize = 0;
    for (bundle_ptr.games) |g| {
        if (g.installDirRel() != null) installed_n += 1;
    }

    state.f95_review_bundle = bundle_ptr;
    state.f95_review_game_count = bundle_ptr.games.len;
    state.f95_review_installed_count = installed_n;
    state.f95_review_games_base_dir = games_base_dir;
    state.f95_review_data_path = data_path;
    state.f95_review_msg = .{};
    state.screen = .import_f95_review;
}

/// Apply the review: spawn the existing import worker. Worker re-
/// reads the DB itself (cheap; few KB to few MB) but we hand it the
/// games-base-dir + mode already picked here, so the user doesn't
/// see a second folder prompt.
pub fn doApplyF95CheckerReview(frame: *Frame) void {
    const state = frame.state;
    if (state.import_job != null) {
        state.notifyWarn("An import is already in flight — wait for it to finish.");
        return;
    }
    const alloc = frame.lib.alloc;

    const data_path_src = state.f95_review_data_path orelse {
        state.notifyErr("Review state missing DB path; cancel and re-open.");
        return;
    };
    const games_base_dir_src = state.f95_review_games_base_dir orelse {
        state.notifyErr("Review state missing games dir; cancel and re-open.");
        return;
    };

    // Hand the worker its own copies — `freeF95Review` frees the
    // review-state strings independently of the worker's lifecycle.
    const data_path = alloc.dupe(u8, data_path_src) catch {
        state.notifyErr("Out of memory starting import.");
        return;
    };
    errdefer alloc.free(data_path);
    const games_base_dir = alloc.dupe(u8, games_base_dir_src) catch {
        alloc.free(data_path);
        state.notifyErr("Out of memory starting import.");
        return;
    };
    errdefer alloc.free(games_base_dir);

    const existing_ids = collectExistingIds(frame) catch {
        alloc.free(data_path);
        alloc.free(games_base_dir);
        state.notifyErr("Couldn't enumerate existing library.");
        return;
    };

    const job = alloc.create(import_job.Job) catch {
        alloc.free(data_path);
        alloc.free(games_base_dir);
        var ids_mut = existing_ids;
        ids_mut.deinit();
        state.notifyErr("Out of memory starting import.");
        return;
    };
    job.* = .{
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .source = .f95checker,
        .data_path = data_path,
        .games_base_dir = games_base_dir,
        .library_root = frame.info.library_root,
        .mode = stateModeToJobMode(frame.state.folder_scan_mode),
        .existing_ids = existing_ids,
    };

    import_job.start(job) catch {
        job.deinit(alloc);
        alloc.destroy(job);
        state.notifyErr("Failed to spawn import worker thread.");
        return;
    };

    state.import_job = job;

    // Free the review bundle now — worker re-reads the DB on its
    // own thread, so we don't need to keep the in-memory copy.
    freeF95Review(state, alloc);
    state.screen = .settings;
    state.notifyInfo("Import started. Banner shows progress.");
}

pub fn doCancelF95CheckerReview(frame: *Frame) void {
    freeF95Review(frame.state, frame.lib.alloc);
    frame.state.screen = .settings;
}

/// Release everything `doStartF95CheckerReview` allocated. Safe to
/// call when nothing is set (all fields null-guarded).
pub fn freeF95Review(state: *State, alloc: std.mem.Allocator) void {
    if (state.f95_review_bundle) |p| {
        const bundle: *importers_mod.Bundle = @ptrCast(@alignCast(p));
        bundle.deinit();
        alloc.destroy(bundle);
        state.f95_review_bundle = null;
    }
    state.f95_review_game_count = 0;
    state.f95_review_installed_count = 0;
    if (state.f95_review_games_base_dir) |s| {
        alloc.free(s);
        state.f95_review_games_base_dir = null;
    }
    if (state.f95_review_data_path) |s| {
        alloc.free(s);
        state.f95_review_data_path = null;
    }
}

/// Typed accessor for the review bundle. Returns null when no review
/// is active.
pub fn f95ReviewBundle(state: *const State) ?*const importers_mod.Bundle {
    if (state.f95_review_bundle) |p| {
        return @ptrCast(@alignCast(p));
    }
    return null;
}

/// Click handler for Settings → "Import from xLibrary...". Same flow,
/// source data path is `~/.config/xlibrary/games-data.json`.
pub fn doImportFromXLibrary(frame: *Frame) void {
    startImport(frame, .xlibrary, stateModeToJobMode(frame.state.folder_scan_mode));
}

fn stateModeToJobMode(m: state_mod.ImportMode) import_job.Mode {
    return switch (m) {
        .move => .move,
        .copy => .copy,
        .link => .link,
    };
}

fn startImport(frame: *Frame, source: import_job.Source, mode: import_job.Mode) void {
    const state = frame.state;
    if (state.import_job != null) {
        state.notifyWarn("An import is already in flight — wait for it to finish.");
        return;
    }
    const alloc = frame.lib.alloc;

    // Source data path — upstream-default per source kind.
    const home = frame.info.host.home orelse {
        state.notifyErr("Couldn't read $HOME; pick the source data path manually instead.");
        return;
    };
    const data_path = buildConfigDataPath(alloc, source, home) catch {
        state.notifyErr("Out of memory resolving source data path.");
        return;
    };
    errdefer alloc.free(data_path);

    // Verify the data file exists before bothering the user with a
    // picker. Surfaces "you don't actually have F95Checker installed"
    // up front.
    std.Io.Dir.cwd().access(frame.io, data_path, .{}) catch {
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Source data not found at {s}", .{data_path}) catch "Source data not found";
        state.notifyErr(msg);
        alloc.free(data_path);
        return;
    };

    // Folder picker — user points at the dir containing the per-game
    // sub-folders (e.g. .../games/ that holds Babysitter-0.2.2b.-linux/,
    // BurningBoundaries-.../, etc.).
    const games_base_dir = file_picker.openFolder(alloc, null) catch |e| {
        alloc.free(data_path);
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed";
        state.notifyErr(msg);
        return;
    } orelse {
        alloc.free(data_path);
        return; // user cancelled
    };
    errdefer alloc.free(games_base_dir);

    // SAFETY: f69 NEVER cleans up upstream-owned config directories.
    // If the user accidentally points the picker at `~/.config/f95checker/`
    // or `~/.config/xlibrary/` (or any sub-path of either), the import
    // worker would later call `migrate.copyVerifyDelete` which DELETES
    // the source after copy+verify. A user lost their entire F95Checker
    // config this way on 2026-05-28 — see the memory note. Refuse here
    // before any filesystem mutation can start. Use absolute-path
    // resolution so symlinks / `..` / case quirks can't slip past.
    if (importTargetUnsafe(frame.io, alloc, games_base_dir, home)) |reason| {
        defer alloc.free(reason);
        var buf: [320]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Import refused: {s}. Pick your games folder (where Babysitter-0.2.2b.-linux/, etc. live), NOT your tool's config folder.", .{reason}) catch "Import refused: unsafe games-base-dir choice.";
        state.notifyErr(m);
        alloc.free(data_path);
        alloc.free(games_base_dir);
        return;
    }

    // Pre-collect existing thread ids so the worker can skip without
    // touching the DB.
    const existing_ids = collectExistingIds(frame) catch {
        alloc.free(data_path);
        alloc.free(games_base_dir);
        state.notifyErr("Couldn't enumerate existing library.");
        return;
    };

    const job = alloc.create(import_job.Job) catch {
        alloc.free(data_path);
        alloc.free(games_base_dir);
        var ids_mut = existing_ids;
        ids_mut.deinit();
        state.notifyErr("Out of memory starting import.");
        return;
    };
    job.* = .{
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .source = source,
        .data_path = data_path,
        .games_base_dir = games_base_dir,
        .library_root = frame.info.library_root,
        .mode = mode,
        .existing_ids = existing_ids,
    };

    import_job.start(job) catch {
        job.deinit(alloc);
        alloc.destroy(job);
        state.notifyErr("Failed to spawn import worker thread.");
        return;
    };

    state.import_job = job;
    state.notifyInfo("Import started. Banner shows progress.");
}

fn buildConfigDataPath(alloc: std.mem.Allocator, source: import_job.Source, home: []const u8) ![]u8 {
    return switch (source) {
        .f95checker => std.fmt.allocPrint(alloc, "{s}/.config/f95checker/db.sqlite3", .{home}),
        .xlibrary => std.fmt.allocPrint(alloc, "{s}/.config/xlibrary/games-data.json", .{home}),
    };
}

/// Hard refusal list — paths f69 must never touch as the games-base-dir
/// because the import worker eventually calls `migrate.copyVerifyDelete`
/// which DELETES the source after copy. A user already lost their F95Checker
/// config by picking `~/.config/f95checker/` here (see memory note); these
/// patterns make it impossible to repeat that mistake.
///
/// Returns null when the picked path is safe; otherwise an alloc-owned
/// reason string the caller surfaces in a toast. Symlinks are followed
/// via `realpath` before the comparison so a user can't accidentally
/// bypass via `ln -s ~/.config/f95checker games`.
fn importTargetUnsafe(io: std.Io, alloc: std.mem.Allocator, picked: []const u8, home: []const u8) ?[]u8 {
    const real_z = std.Io.Dir.cwd().realPathFileAlloc(io, picked, alloc) catch null;
    const real: []const u8 = if (real_z) |r| r else picked;
    defer if (real_z) |r| alloc.free(r);

    // Build the absolute forbidden prefixes. Each ends in '/' so we can
    // match either equality OR strict sub-path containment with a single
    // `startsWith`.
    const FORBIDDEN_SUBS = [_][]const u8{
        ".config/f95checker",
        ".config/xlibrary",
        ".local/share/f95checker",
        ".local/share/xlibrary",
    };
    for (FORBIDDEN_SUBS) |sub| {
        var pref_buf: [512]u8 = undefined;
        const pref = std.fmt.bufPrint(&pref_buf, "{s}/{s}", .{ home, sub }) catch continue;
        // Equality (user picked the dir itself).
        if (std.mem.eql(u8, real, pref)) {
            return std.fmt.allocPrint(alloc, "that's the {s} config directory — f69 never touches upstream tool dirs", .{sub}) catch null;
        }
        // Strict sub-path: prefix + "/".
        if (real.len > pref.len + 1 and std.mem.startsWith(u8, real, pref) and real[pref.len] == '/') {
            return std.fmt.allocPrint(alloc, "that's inside the {s} config directory — f69 never touches upstream tool dirs", .{sub}) catch null;
        }
    }
    return null;
}

// ============================================================
//  Export — write f69's library to a F95Checker-shaped db.sqlite3
//
//  Two-step UX:
//    1. Folder picker — user points at where db.sqlite3 should land.
//       Typically `~/.config/f95checker/` for an in-place restore, but
//       any dir works for a "stash a backup for later" flow.
//    2. If `<picked>/db.sqlite3` already exists, MOVE it to a
//       timestamped sibling (`db.sqlite3.bak-YYYYMMDD-HHMMSS`) BEFORE
//       writing anything new. This protects users with a live
//       f95checker config — the worst case is an extra backup file.
//
//  The output db is in F95Checker's modern schema (`games` table
//  matching upstream `modules/db.py`). F95Checker on next startup
//  creates the other tables via its own CREATE TABLE IF NOT EXISTS
//  flow, so the export is consumable end-to-end without our touching
//  upstream code paths.
// ============================================================

pub fn doExportToF95Checker(frame: *Frame) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Step 1: pick destination directory.
    const dest_dir = file_picker.openFolder(alloc, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed";
        state.notifyErr(msg);
        return;
    } orelse return; // user cancelled
    defer alloc.free(dest_dir);

    const db_path = std.fmt.allocPrint(alloc, "{s}/db.sqlite3", .{dest_dir}) catch {
        state.notifyErr("Out of memory composing db path.");
        return;
    };
    defer alloc.free(db_path);

    // Step 2: timestamped backup of any existing file. NEVER clobber
    // an existing f95checker db without a copy preserved.
    if (std.Io.Dir.cwd().access(frame.io, db_path, .{})) |_| {
        const ts_now = std.Io.Clock.Timestamp.now(frame.io, .real);
        const ts_s: i64 = @intCast(@divTrunc(ts_now.raw.toNanoseconds(), 1_000_000_000));
        const bak_path = std.fmt.allocPrint(alloc, "{s}.bak-{d}", .{ db_path, ts_s }) catch {
            state.notifyErr("Out of memory composing backup path.");
            return;
        };
        defer alloc.free(bak_path);
        std.Io.Dir.cwd().rename(db_path, std.Io.Dir.cwd(), bak_path, frame.io) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Couldn't back up existing db.sqlite3: {s}. Refusing to overwrite.", .{@errorName(e)}) catch "Couldn't back up existing db; refusing to overwrite";
            state.notifyErr(msg);
            return;
        };
        log.info("export: existing db.sqlite3 moved to {s}", .{bak_path});
    } else |_| {} // file doesn't exist — first export, no backup needed

    // Step 3: build the export rows. Walk every game; for each look up
    // the latest install + format the install path as the executables
    // JSON. The whole thing is alloc-owned scratch — freed in the defer
    // at function exit.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var rows: std.ArrayList(importers_mod.f95checker.ExportGame) = .empty;
    var installed_count: u32 = 0;
    for (frame.games) |*g| {
        const inst_opt = frame.lib.latestInstallForGame(g.f95_thread_id) catch null;
        defer if (inst_opt) |i| frame.lib.freeInstall(i);

        var exes_json: []const u8 = "";
        var installed_str: []const u8 = "";
        var added_on: i64 = 0;
        if (inst_opt) |inst| {
            // F95Checker's executables column is a JSON array of
            // absolute paths to launcher scripts. We pass the install
            // dir (post-Convert that's where run-mkxp-z.sh / Game.sh /
            // launcher.sh lives) — F95Checker calls xdg-open or similar
            // on it, which on Linux resolves the directory by listing
            // executables. For better targeting we could try to detect
            // an actual launcher .sh; deferring that — install dir is
            // close enough for the immediate restore-the-backup case.
            const path_arr = aalloc.alloc([]const u8, 1) catch continue;
            path_arr[0] = inst.install_path;
            exes_json = std.json.Stringify.valueAlloc(aalloc, path_arr, .{}) catch continue;
            installed_str = g.latest_version orelse "imported";
            added_on = inst.installed_at;
            installed_count += 1;
        }

        var finished_str: []const u8 = "";
        if (g.completion_status == .completed) {
            finished_str = g.latest_version orelse "completed";
        }

        rows.append(aalloc, .{
            .thread_id = g.f95_thread_id,
            .name = g.name,
            .version = g.latest_version,
            .developer = g.developer,
            .description = g.description_md,
            .changelog = g.changelog_md,
            .notes = g.notes,
            .cover_url = g.cover_url,
            .score = g.rating orelse 0,
            .votes = g.vote_count orelse 0,
            .rating = if (g.user_rating) |r| @intFromFloat(@round(r)) else 0,
            .last_launched = g.last_played_at orelse 0,
            .added_on = added_on,
            .last_updated = g.last_updated_at orelse 0,
            .tags = g.tags,
            .executables_json = exes_json,
            .finished = finished_str,
            .installed = installed_str,
            .url = "", // synthesised in writeToDb from thread_id
        }) catch {
            state.notifyErr("Out of memory building export rows.");
            return;
        };
    }

    // Step 4: write the db.
    importers_mod.f95checker.writeToDb(alloc, db_path, rows.items) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "F95Checker export failed: {s}", .{@errorName(e)}) catch "F95Checker export failed";
        state.notifyErr(msg);
        return;
    };

    var msg_buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "Exported {d} games ({d} installed) → {s}",
        .{ rows.items.len, installed_count, db_path },
    ) catch "Export complete";
    state.notifyInfo(msg);
    log.info("f95checker export: {d} games, {d} installed, target={s}", .{ rows.items.len, installed_count, db_path });
}

fn collectExistingIds(frame: *Frame) !std.AutoHashMap(u64, void) {
    var out = std.AutoHashMap(u64, void).init(frame.lib.alloc);
    errdefer out.deinit();
    for (frame.games) |*g| {
        try out.put(g.f95_thread_id, {});
    }
    return out;
}

/// Per-frame drain for the import worker. Pulls staged rows and
/// upserts on the UI thread (SQLite stays single-threaded), then on
/// terminal phase pops a toast + frees the job.
pub fn drainImport(frame: *Frame) void {
    const state = frame.state;
    const job = state.import_job orelse return;

    // Pull staged rows under the worker's mutex, then commit on UI.
    var to_upsert: std.ArrayList(import_job.StagedRow) = .empty;
    defer to_upsert.deinit(frame.lib.alloc);
    {
        job.stage_mu.lockUncancelable(job.io);
        defer job.stage_mu.unlock(job.io);
        const items = job.stage.items;
        const newly_drained = items.len - job.stage_drained;
        if (newly_drained > 0) {
            to_upsert.appendSlice(frame.lib.alloc, items[job.stage_drained..]) catch {};
            job.stage_drained = items.len;
        }
    }

    var imported_count: u32 = 0;
    var warn_count: u32 = 0;
    const now_ns = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now_ns.raw.toNanoseconds(), 1_000_000_000));
    for (to_upsert.items) |*row| {
        // Stamp creation time here (UI thread) so we don't need to
        // thread the clock through the worker.
        row.game.created_at = now_s;
        // Free strings AFTER successful upsert (or attempted upsert);
        // library.upsertGame dupes via SQL bind so we own the buffers
        // start to finish.
        frame.lib.upsertGame(&row.game) catch |e| {
            log.warn("import upsert game {d} ({s}) failed: {s}", .{ row.game.f95_thread_id, row.game.name, @errorName(e) });
        };
        if (row.install) |*i| {
            frame.lib.upsertInstall(i) catch |e| {
                log.warn("import upsert install for game {d} failed: {s}", .{ row.game.f95_thread_id, @errorName(e) });
            };
        }
        if (row.migrate_err != null) warn_count += 1;
        imported_count += 1;
        freeImportStagedRow(frame.lib.alloc, row);
    }
    if (imported_count > 0) {
        // Library snapshot is stale now; force a reload next frame so
        // the grid surfaces the new rows.
        state.reload_requested = true;
    }

    const phase = job.currentPhase();
    if (phase == .done or phase == .err or phase == .canceled) {
        // Final summary toast.
        var buf: [256]u8 = undefined;
        const games_n = job.games_imported.load(.monotonic);
        const installs_n = job.installs_migrated.load(.monotonic);
        const skipped = job.skipped.load(.monotonic);
        const msg = switch (phase) {
            .done => std.fmt.bufPrint(&buf, "Import complete: {d} game(s) imported ({d} install(s) migrated), {d} skipped.", .{ games_n, installs_n, skipped }) catch "Import complete.",
            .err => std.fmt.bufPrint(&buf, "Import failed: {s}", .{job.errMessage()}) catch "Import failed.",
            .canceled => std.fmt.bufPrint(&buf, "Import canceled. Partial: {d} game(s), {d} install(s) migrated.", .{ games_n, installs_n }) catch "Import canceled.",
            else => unreachable,
        };
        const kind: state_mod.ToastKind = switch (phase) {
            .done => if (warn_count > 0) .warn else .success,
            .err => .err,
            .canceled => .warn,
            else => .info,
        };
        state.pushToast(kind, msg);

        // Tear down the job.
        const alloc = frame.lib.alloc;
        job.deinit(alloc);
        alloc.destroy(job);
        state.import_job = null;
        state.reload_requested = true;
    }
}

fn freeImportStagedRow(alloc: std.mem.Allocator, r: *import_job.StagedRow) void {
    alloc.free(r.game.name);
    if (r.game.developer) |s| alloc.free(s);
    if (r.game.cover_url) |s| alloc.free(s);
    if (r.game.description_md) |s| alloc.free(s);
    if (r.game.changelog_md) |s| alloc.free(s);
    if (r.game.notes) |s| alloc.free(s);
    if (r.game.latest_version) |s| alloc.free(s);
    for (r.game.tags) |t| alloc.free(t);
    if (r.game.tags.len > 0) alloc.free(r.game.tags);
    if (r.install) |*i| {
        alloc.free(i.version);
        alloc.free(i.install_path);
        if (i.executable) |s| alloc.free(s);
        if (i.launch_args) |s| alloc.free(s);
        alloc.free(i.recipe_id);
    }
    if (r.migrate_err) |s| alloc.free(s);
}

/// Click handler for Settings → "Import from F95Checker..." (re-stated
/// here to give the public surface a stable home next to the legacy
/// per-mod actions below).
fn legacyImportAnchor() void {}

// ============================================================
//  folder-scan importer — walks a directory of installed games
// ============================================================
//
// User points at a folder, we run `importers.folder_scan.scan` on
// it, and surface the parsed entries on the Import screen for
// review. Per-entry resolution (paste F95 URL / add as custom) is
// driven from the UI; this module owns the state lifetime and the
// "commit to library" path.

const folder_scan = importers_mod.folder_scan;

/// Incremental scan session — owned by State while a folder scan is
/// running. Replaces the previous all-at-once `folder_scan.scan` call
/// that froze the UI on libraries of a few hundred folders. The
/// render loop calls `tickFolderScan` each frame while the session
/// is active; the UI shows newly-found games as they appear instead
/// of waiting for the whole walk to complete.
const ScanSession = struct {
    arena: *std.heap.ArenaAllocator,
    games_list: std.ArrayList(importers_mod.ImportedGame),
    rows_list: std.ArrayList(state_mod.FolderImportRowState),
    /// Cached library snapshot for name_match prefill. Owned by
    /// `frame.lib`; freed via `lib.freeGames` in `freeFolderScan`.
    /// Lifetime: lives until the session is torn down.
    lib_games: []library.Game,
    /// `name_match.Candidate` view of lib_games. Pre-built so each
    /// scan tick doesn't redo the conversion.
    candidates: []importers_mod.name_match.Candidate,
    /// Owned by `arena`. Identifies the file-system root we're
    /// walking; combined with `entry.name` to build per-entry probe
    /// paths.
    scan_root: []const u8,
    /// Live directory iterator. `dir` is open until session teardown.
    dir: std.Io.Dir,
    iter: std.Io.Dir.Iterator,
    /// Heap-owned bundle struct mirror so `state.folder_scan_bundle`
    /// can carry a stable `*Bundle` pointer. `bundle.games` is
    /// kept in sync with `games_list.items` after each append.
    bundle: *importers_mod.Bundle,
    done: bool = false,
    /// Running tally of scanned entries (regardless of match).
    /// Surfaces in the status line so the user sees progress on
    /// huge directories.
    scanned: usize = 0,

    /// Number of top-level entries we process per `tickFolderScan`
    /// call. Tuned for ~30 Hz render rate: small enough to keep one
    /// frame under 16 ms even on slow filesystems (FUSE NTFS),
    /// large enough that 100 folders finish within ~1 s.
    pub const STEP_BATCH: usize = 4;
};

/// Kick off an incremental folder scan. Allocates the session,
/// opens the scan root, fills the cached library snapshot, and
/// installs an empty Bundle so the UI can render the (initially
/// empty) preview right away. Each subsequent frame calls
/// `tickFolderScan` to add a batch of found games.
pub fn doFolderScan(frame: *Frame, dir_path: []const u8) void {
    const state = frame.state;
    if (dir_path.len == 0) {
        state.setFolderScanMsg("Pick a folder first.");
        return;
    }
    // Drop the previous scan (bundle, session, row states, lib snap).
    freeFolderScan(state, frame.lib, frame.io);

    const lib_alloc = frame.lib.alloc;
    const arena_ptr = lib_alloc.create(std.heap.ArenaAllocator) catch {
        state.setFolderScanMsg("Out of memory starting scan.");
        return;
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(lib_alloc);

    const a = arena_ptr.allocator();

    var dir = std.Io.Dir.cwd().openDir(frame.io, dir_path, .{ .iterate = true }) catch |e| {
        var buf: [192]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Open failed: {s}", .{@errorName(e)}) catch "Open failed";
        state.setFolderScanMsg(m);
        arena_ptr.deinit();
        lib_alloc.destroy(arena_ptr);
        return;
    };

    const scan_root_dup = a.dupe(u8, dir_path) catch {
        state.setFolderScanMsg("Out of memory.");
        dir.close(frame.io);
        arena_ptr.deinit();
        lib_alloc.destroy(arena_ptr);
        return;
    };

    // Snapshot the library and build candidate slices for the
    // per-row name_match prefill. Caching here (vs per-tick or
    // per-frame) keeps the iterator fast even on a 500-game library.
    const lib_games: []library.Game = frame.lib.listGames() catch &.{};
    state.folder_scan_lib_snapshot = if (lib_games.len > 0) lib_games.ptr else null;
    state.folder_scan_lib_count = lib_games.len;

    var candidates: []importers_mod.name_match.Candidate = &.{};
    if (a.alloc(importers_mod.name_match.Candidate, lib_games.len)) |cs| {
        candidates = cs;
        for (lib_games, 0..) |g, i| {
            candidates[i] = .{ .thread_id = g.f95_thread_id, .name = g.name };
        }
    } else |_| {
        // No candidates → no auto-link prefill; rows will start
        // .unresolved and the user picks via the typeahead. Not a
        // fatal condition.
    }

    const bundle_ptr = lib_alloc.create(importers_mod.Bundle) catch {
        state.setFolderScanMsg("Out of memory.");
        dir.close(frame.io);
        arena_ptr.deinit();
        lib_alloc.destroy(arena_ptr);
        return;
    };
    bundle_ptr.* = .{ .arena = arena_ptr, .games = &.{} };

    const session = lib_alloc.create(ScanSession) catch {
        state.setFolderScanMsg("Out of memory.");
        lib_alloc.destroy(bundle_ptr);
        dir.close(frame.io);
        arena_ptr.deinit();
        lib_alloc.destroy(arena_ptr);
        return;
    };
    session.* = .{
        .arena = arena_ptr,
        .games_list = .empty,
        .rows_list = .empty,
        .lib_games = lib_games,
        .candidates = candidates,
        .scan_root = scan_root_dup,
        .dir = dir,
        .iter = dir.iterate(),
        .bundle = bundle_ptr,
    };

    state.folder_scan_session = session;
    state.folder_scan_bundle = bundle_ptr;
    state.folder_scan_row_states = null;
    state.folder_scan_row_count = 0;
    state.setFolderScanMsg("Scanning…");
}

/// Drive the current scan session forward by `ScanSession.STEP_BATCH`
/// entries. No-op when no session is active or the iterator has
/// already drained. Called from the import screen's render path.
pub fn tickFolderScan(frame: *Frame) void {
    const state = frame.state;
    const opaque_ptr = state.folder_scan_session orelse return;
    const session: *ScanSession = @ptrCast(@alignCast(opaque_ptr));
    if (session.done) return;

    var processed: usize = 0;
    while (processed < ScanSession.STEP_BATCH) : (processed += 1) {
        const entry_opt = session.iter.next(frame.io) catch |iter_err| blk: {
            // Iterator errored. The OLD code treated this as
            // "end of dir" which silently stopped the scan
            // mid-way through (FUSE NTFS can throw transient
            // errors on individual entries). Log it loudly and
            // try once more — if it fails again next tick we'll
            // eventually run out of entries naturally OR keep
            // hitting an error. Either way the user sees the
            // log line.
            std.log.scoped(.ui_actions).warn("folder-scan iter error: {s} — skipping entry, will retry", .{@errorName(iter_err)});
            break :blk null;
        };
        const entry = entry_opt orelse {
            session.done = true;
            session.dir.close(frame.io);
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "Scan done — {d} game(s) found.", .{session.games_list.items.len}) catch "Scan done.";
            state.setFolderScanMsg(m);
            return;
        };
        session.scanned += 1;
        processOneEntry(frame, session, entry) catch |e| {
            std.log.scoped(.ui_actions).warn("folder-scan entry skipped: {s}", .{@errorName(e)});
        };
    }

    var buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&buf, "Scanning… {d} found, {d} dirs checked", .{ session.games_list.items.len, session.scanned }) catch "Scanning…";
    state.setFolderScanMsg(m);
}

/// True when a scan is currently in progress; the UI uses this to
/// auto-tick each frame.
pub fn folderScanInProgress(state: *const State) bool {
    const opaque_ptr = state.folder_scan_session orelse return false;
    const session: *const ScanSession = @ptrCast(@alignCast(opaque_ptr));
    return !session.done;
}

/// Process ONE top-level entry. On a hit, appends a game + row to
/// the session's lists and re-syncs the bundle slice + State row
/// state pointers so the next render frame sees the new row.
fn processOneEntry(
    frame: *Frame,
    session: *ScanSession,
    entry: std.Io.Dir.Entry,
) !void {
    if (entry.kind != .directory and entry.kind != .unknown) {
        std.log.scoped(.importers_folder).info("skip '{s}': not a dir (kind={s})", .{ entry.name, @tagName(entry.kind) });
        return;
    }
    if (folder_scan.looksLikeCompanionFile(entry.name)) {
        std.log.scoped(.importers_folder).info("skip '{s}': companion-file pattern", .{entry.name});
        return;
    }

    var top_path_buf: [1024]u8 = undefined;
    const top_path = try std.fmt.bufPrint(&top_path_buf, "{s}/{s}", .{ session.scan_root, entry.name });

    var rel_buf: [1024]u8 = undefined;
    const hit_opt = folder_scan.detectEngineDeep(frame.io, top_path, &rel_buf);
    const hit = hit_opt orelse {
        std.log.scoped(.importers_folder).info("skip '{s}': no engine fingerprint", .{entry.name});
        return;
    };

    const a = session.arena.allocator();
    const entry_name_dup = try a.dupe(u8, entry.name);

    var parse_buf: [1024]u8 = undefined;
    const parsed = folder_scan.parseFolderName(&parse_buf, entry.name);
    const parsed_name: []const u8 = if (parsed) |p| p.name else entry.name;
    const parsed_version: ?[]const u8 = if (parsed) |p| p.version else null;

    const name_dup = try a.dupe(u8, parsed_name);
    const version_dup: ?[]const u8 = if (parsed_version) |v| try a.dupe(u8, v) else null;
    const install_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ entry_name_dup, hit.fingerprint_rel });

    try session.games_list.append(a, .{
        .thread_id = importers_mod.folder_scan.syntheticThreadId(name_dup),
        .name = name_dup,
        .version = version_dup,
        .engine = hit.engine,
        .install_executable_rel = install_path,
    });

    var row: state_mod.FolderImportRowState = .{};
    copyToBuf(&row.name_buf, name_dup);
    if (version_dup) |v| copyToBuf(&row.version_buf, v);

    if (importers_mod.name_match.bestMatch(name_dup, session.candidates)) |m| {
        row.link_state = .linked_existing;
        row.link_thread_id = m.thread_id;
        copyToBuf(&row.link_buf, m.name);
        if (version_dup == null) {
            for (session.lib_games) |lg| {
                if (lg.f95_thread_id == m.thread_id) {
                    if (lg.latest_version) |lv| copyToBuf(&row.version_buf, lv);
                    break;
                }
            }
        }
    } else {
        // No fuzzy match crossed threshold. Seed `link_buf` with the
        // parsed name so the typeahead has something to filter on the
        // moment the user opens the cell. `typeahead_open` stays
        // FALSE — auto-opening made row heights wildly variable
        // (closed ~65 px, open with suggestion list ~200 px), which
        // broke viewport culling. The "no match — click ▼" chip
        // tells the user exactly what to do; one click expands it.
        copyToBuf(&row.link_buf, name_dup);
    }

    populateRowIssues(frame, &row, top_path);

    try session.rows_list.append(a, row);

    session.bundle.games = session.games_list.items;
    frame.state.folder_scan_row_states = session.rows_list.items.ptr;
    frame.state.folder_scan_row_count = session.rows_list.items.len;
}

/// Run the compat service against `install_root` and copy up to
/// `FOLDER_IMPORT_MAX_ISSUES` matched recipe ids+titles into the
/// row state. Idempotent — safe to call again after a re-scan.
fn populateRowIssues(frame: *Frame, row: *state_mod.FolderImportRowState, install_root: []const u8) void {
    row.issue_count = 0;
    const issues = frame.compat_svc.scan(install_root, &.{}) catch return;
    defer frame.compat_svc.freeIssues(issues);
    var n: u8 = 0;
    for (issues) |iss| {
        if (n >= state_mod.FOLDER_IMPORT_MAX_ISSUES) break;
        var slot = &row.issues[n];
        const id_n = @min(iss.recipe_id.len, slot.id_buf.len);
        @memcpy(slot.id_buf[0..id_n], iss.recipe_id[0..id_n]);
        slot.id_len = @intCast(id_n);
        const t_n = @min(iss.title.len, slot.title_buf.len);
        @memcpy(slot.title_buf[0..t_n], iss.title[0..t_n]);
        slot.title_len = @intCast(t_n);
        n += 1;
    }
    row.issue_count = n;
}

fn copyToBuf(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
}

/// Free the folder-scan preview state. Takes `lib + io` separately
/// so the shutdown path (which doesn't construct a `Frame`) can call
/// us too. `io` is only used to close the live directory handle held
/// by a mid-scan session; `lib` releases the cached `listGames`
/// snapshot.
pub fn freeFolderScan(state: *State, lib: *library.Library, io: std.Io) void {
    const alloc = lib.alloc;
    if (state.folder_scan_session) |p| {
        const session: *ScanSession = @ptrCast(@alignCast(p));
        if (!session.done) session.dir.close(io);
        alloc.destroy(session);
        state.folder_scan_session = null;
    }
    if (state.folder_scan_bundle) |opaque_ptr| {
        const bundle: *importers_mod.Bundle = @ptrCast(@alignCast(opaque_ptr));
        bundle.deinit();
        alloc.destroy(bundle);
        state.folder_scan_bundle = null;
    }
    // Row states live inside the session's arena (freed via the
    // Bundle's arena above); their ArrayList header lived in the
    // session struct (also freed above). Just zero the State
    // pointers here.
    state.folder_scan_row_states = null;
    state.folder_scan_row_count = 0;
    if (state.folder_scan_lib_snapshot) |p| {
        const slice = @as([*]library.Game, @ptrCast(@alignCast(p)))[0..state.folder_scan_lib_count];
        lib.freeGames(slice);
        state.folder_scan_lib_snapshot = null;
        state.folder_scan_lib_count = 0;
    }
    state.folder_resolve_idx = null;
    @memset(&state.folder_resolve_url_buf, 0);
    @memset(&state.folder_bulk_name_buf, 0);
    @memset(&state.folder_bulk_version_buf, 0);
}

pub fn folderScanLibSnapshot(state: *const State) []library.Game {
    if (state.folder_scan_lib_snapshot) |p| {
        const slice = @as([*]library.Game, @ptrCast(@alignCast(p)))[0..state.folder_scan_lib_count];
        return slice;
    }
    return &.{};
}

pub fn folderScanBundle(state: *const State) ?*const importers_mod.Bundle {
    if (state.folder_scan_bundle) |p| {
        return @ptrCast(@alignCast(p));
    }
    return null;
}

/// Typed accessor for the per-row editable state slice. Length is
/// `state.folder_scan_row_count`. Returns null when no scan is
/// active (or when row-state alloc failed).
pub fn folderScanRowStates(state: *State) ?[]state_mod.FolderImportRowState {
    if (state.folder_scan_row_states) |p| {
        const rows: [*]state_mod.FolderImportRowState = @ptrCast(@alignCast(p));
        return rows[0..state.folder_scan_row_count];
    }
    return null;
}

/// Resolve an entry from the scan list, MOVE the source folder into
/// `<library_root>/<tid>/<version_or_'imported'>/`, and write a
/// matching `installs` row so the game shows up as installed.
///
/// `idx` is the index into `bundle.games`. `thread_id` is either the
/// real F95 thread id the user pasted, OR null to commit the entry
/// as a "custom" row with the synthetic id the scanner generated.
///
/// Move strategy: try `renameAbsolute` first — on the same
/// filesystem this is a single inode update (O(1)). If the source
/// and destination live on different filesystems, fall back to
/// `migrate.copyVerifyDelete`, which is robust but pays a full
/// disk-walk per file. The Import-screen tip nudges the user to
/// keep the source folder near `library_root` for the fast path.
///
/// On success the entry is removed from the scan bundle and a
/// reload is requested so the library grid picks up the new row.
pub fn resolveFolderEntry(frame: *Frame, idx: usize, thread_id: ?u64) void {
    resolveFolderEntryWithMode(frame, idx, thread_id, frame.state.folder_scan_mode);
}

/// Commit every ticked + resolved row in the current folder-scan
/// preview. Per PLAN §2.13, dispatches on `link_state`:
///
///   - `.linked_existing` → attach the install to the linked
///      library game (`row.link_thread_id`). Library row's existing
///      name/latest_version stay untouched.
///
///   - `.custom_new` → mint a random high-bit-set thread id via
///      `name_match.customNewThreadId`, insert a fresh library row
///      using `row.name_buf` + `row.version_buf`, attach install.
///
///   - `.f95_url` → parse the URL in `row.link_buf` to a numeric
///      thread id, insert a placeholder library row (name
///      "(unsynced)") so the install can attach, then mark the row
///      so the next Sync All pulls metadata. (We deliberately don't
///      scrape inline — keeps commit snappy on batch imports.)
///
/// Commits in reverse index order so `dropEntryFromBundle`'s
/// shift-down doesn't slide rows under us. Rows with
/// `.unresolved` or unticked are skipped.
pub fn commitFolderImport(frame: *Frame) void {
    const state = frame.state;
    const bundle = folderScanBundle(state) orelse return;
    const rows = folderScanRowStates(state) orelse return;
    if (rows.len != bundle.games.len) return;

    var committed: usize = 0;
    var skipped_unresolved: usize = 0;
    var i: usize = rows.len;
    while (i > 0) {
        i -= 1;
        const r = &rows[i];
        if (!r.checked) continue;
        if (r.link_state == .unresolved) {
            skipped_unresolved += 1;
            continue;
        }
        commitOneRow(frame, i, r, bundle.games[i], state.folder_scan_mode) catch |e| {
            log.warn("folder-import row {d}: {s}", .{ i, @errorName(e) });
            continue;
        };
        committed += 1;
    }

    // Refresh the cached library snapshot so subsequent typeahead
    // searches see the games we just imported (especially the
    // custom_new entries we minted). Without this, picking
    // "+ Custom new" for a row and then trying to link a sibling
    // folder to it would silently miss — the lib_games slice was
    // taken at scan start and never updated.
    if (committed > 0) refreshLibSnapshot(frame);

    var msg_buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Imported {d} row(s); {d} unresolved skipped.", .{ committed, skipped_unresolved }) catch "Import finished";
    state.setFolderScanMsg(msg);
    state.reload_requested = true;
}

/// Drop the cached library snapshot and grab a fresh one. Used after
/// commits so newly-created library rows (e.g. custom_new) are
/// visible to typeahead searches on remaining unresolved rows.
fn refreshLibSnapshot(frame: *Frame) void {
    const state = frame.state;
    if (state.folder_scan_lib_snapshot) |p| {
        const slice = @as([*]library.Game, @ptrCast(@alignCast(p)))[0..state.folder_scan_lib_count];
        frame.lib.freeGames(slice);
        state.folder_scan_lib_snapshot = null;
        state.folder_scan_lib_count = 0;
    }
    if (frame.lib.listGames()) |gs| {
        state.folder_scan_lib_snapshot = if (gs.len > 0) gs.ptr else null;
        state.folder_scan_lib_count = gs.len;
    } else |_| {}
}

/// 3-state commit for a single preview row. Branches on
/// `row.link_state` to figure out (a) the thread id, (b) what the
/// library row should look like, and (c) whether to mint a fresh
/// library entry. After thread id is settled, the shared
/// "transfer the on-disk folder + write installs row" tail is the
/// same as the legacy commit path.
fn commitOneRow(
    frame: *Frame,
    idx: usize,
    row: *state_mod.FolderImportRowState,
    game: importers_mod.ImportedGame,
    mode: state_mod.ImportMode,
) !void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Pull the user-edited name + version. These win over the
    // scanner's parse — the user may have corrected them.
    const edited_name = sliceBuf(&row.name_buf);
    const edited_version = sliceBuf(&row.version_buf);

    // Step 1 — resolve the thread id.
    const tid: u64 = switch (row.link_state) {
        .linked_existing => row.link_thread_id orelse return error.LinkUnresolved,
        .custom_new => importers_mod.name_match.customNewThreadId(frame.io),
        .f95_url => blk: {
            const url = sliceBuf(&row.link_buf);
            const tid_str = f95.extractThreadId(url) orelse {
                state.setFolderScanMsg("Couldn't parse the F95 URL — fix it on the row and re-Import.");
                return error.LinkUnresolved;
            };
            const parsed = std.fmt.parseInt(u64, tid_str, 10) catch return error.LinkUnresolved;
            row.link_thread_id = parsed;
            break :blk parsed;
        },
        .unresolved => unreachable, // caller guards
    };

    // Step 2 — make sure a library row exists for this thread id.
    // For linked_existing the row already exists; insertIfMissing is
    // a no-op there. For custom_new / f95_url we provide the name we
    // want the placeholder row to carry. Library will keep whatever
    // existing row is there; insert only fires when the tid is new.
    const placeholder_name: []const u8 = switch (row.link_state) {
        .linked_existing => "(linked)", // never written — row already exists
        .custom_new => if (edited_name.len > 0) edited_name else "(custom)",
        .f95_url => "(unsynced)", // a later Sync pulls the real metadata
        .unresolved => unreachable,
    };
    const lib_row = library.Game{
        .f95_thread_id = tid,
        .name = placeholder_name,
        .latest_version = if (edited_version.len > 0) edited_version else null,
    };
    _ = frame.lib.insertIfMissing(&lib_row) catch {
        return error.LibInsertFailed;
    };

    // Step 3 — build src/dst paths. `installDirRel` is the top-level
    // wrapper folder, regardless of where inside it the engine
    // fingerprint lives.
    const folder_name = game.installDirRel() orelse {
        return error.NoInstallDirRel;
    };
    const scan_root = state.folderScanPathSlice();
    const src_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ scan_root, folder_name });
    defer alloc.free(src_path);

    const version_dir: []const u8 = if (edited_version.len > 0) edited_version else "imported";
    const dst_path = try std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ frame.info.library_root, tid, version_dir });
    defer alloc.free(dst_path);

    // Step 4 — idempotency: skip if an install already points at
    // exactly this destination for exactly this thread id.
    if (installAlreadyAtPath(frame.lib, tid, dst_path)) {
        state.setFolderScanMsg("Skipped — an install already exists at that target path.");
        dropEntryFromBundle(state, idx);
        return;
    }

    // Step 5 — move/copy/link the folder. The transfer result tells
    // us which path to put on the install row (dst for move/copy,
    // src for link — `link` doesn't touch disk).
    const transfer = transferImported(alloc, frame.io, src_path, dst_path, mode) catch |e| {
        var buf: [256]u8 = undefined;
        const verb: []const u8 = switch (mode) {
            .copy => "copy",
            .move => "move",
            .link => "link",
        };
        const m = std.fmt.bufPrint(&buf, "Folder {s} failed ({s}). Library row kept.", .{ verb, @errorName(e) }) catch "Folder transfer failed";
        state.setFolderScanMsg(m);
        dropEntryFromBundle(state, idx);
        return;
    };

    // Step 6 — install row.
    var id_buf: [36]u8 = undefined;
    generateImportUuid(frame.io, &id_buf);
    const now = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
    frame.lib.upsertInstall(&.{
        .id = id_buf,
        .game_thread_id = tid,
        .version = version_dir,
        .install_path = transfer.install_path,
        .recipe_id = "",
        .installed_at = now_s,
        .source = .manual,
    }) catch |e| {
        log.warn("folder-import row {d}: install upsert failed: {s}", .{ idx, @errorName(e) });
    };

    // Surface a loud warning when the cross-FS copy succeeded but the
    // source delete failed (typical on FUSE NTFS / exFAT mounts). The
    // destination is fine — game is fully imported — but the user
    // needs to know the source folder is still on disk.
    if (transfer.source_delete_failed) {
        var buf: [320]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Imported '{s}' OK but source folder couldn't be deleted (likely FUSE NTFS read-only mount). Clean up manually: {s}", .{ folder_name, src_path }) catch "Imported; source not deleted (see logs)";
        state.setFolderScanMsg(m);
        log.warn("folder-import row {d}: source delete failed; src={s}", .{ idx, src_path });
    }

    dropEntryFromBundle(state, idx);
}

/// Re-scan idempotency check. Returns true when the library already
/// has an install for this thread id at exactly this on-disk path —
/// the user has scanned the same dir twice. The committer skips
/// such rows so we don't dupe install rows or trigger a redundant
/// folder transfer.
fn installAlreadyAtPath(lib: *library.Library, thread_id: u64, install_path: []const u8) bool {
    const installs = lib.listInstalls(thread_id) catch return false;
    defer lib.freeInstalls(installs);
    for (installs) |inst| {
        if (std.mem.eql(u8, inst.install_path, install_path)) return true;
    }
    return false;
}

fn sliceBuf(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

/// Same as `resolveFolderEntry` but takes an explicit transfer mode
/// rather than reading `folder_scan_mode`. Kept as the inner
/// implementation so the public entry point stays a single-arg call
/// from the UI and the mode is sourced from the user's radio.
fn resolveFolderEntryWithMode(frame: *Frame, idx: usize, thread_id: ?u64, mode: @import("../state.zig").ImportMode) void {
    const state = frame.state;
    const bundle = folderScanBundle(state) orelse return;
    if (idx >= bundle.games.len) return;
    const game = bundle.games[idx];

    const tid = thread_id orelse game.thread_id;
    const insert_name = if (game.name.len > 0) game.name else "(unnamed)";
    const row = library.Game{
        .f95_thread_id = tid,
        .name = insert_name,
        .latest_version = game.version,
    };
    _ = frame.lib.insertIfMissing(&row) catch |e| {
        var buf: [160]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Library insert failed: {s}", .{@errorName(e)}) catch "Library insert failed";
        state.setFolderScanMsg(m);
        return;
    };

    // Move the source folder under library_root. `install_executable_rel`
    // is `<folder>/` per the scanner; trim the trailing slash to get
    // the folder name we need to join onto `folder_scan_path_buf`.
    const folder_name = blk: {
        const rel = game.install_executable_rel orelse {
            state.setFolderScanMsg("Imported library row, but the scan entry had no folder path to move.");
            return;
        };
        const trimmed = std.mem.trim(u8, rel, "/");
        break :blk if (trimmed.len > 0) trimmed else rel;
    };
    const scan_root = state.folderScanPathSlice();
    const alloc = frame.lib.alloc;
    const src_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ scan_root, folder_name }) catch {
        state.setFolderScanMsg("Out of memory building source path.");
        return;
    };
    defer alloc.free(src_path);

    const version_dir: []const u8 = if (game.version) |v| v else "imported";
    const dst_path = std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ frame.info.library_root, tid, version_dir }) catch {
        state.setFolderScanMsg("Out of memory building destination path.");
        return;
    };
    defer alloc.free(dst_path);

    const transfer = transferImported(alloc, frame.io, src_path, dst_path, mode) catch |e| {
        var buf: [256]u8 = undefined;
        const verb: []const u8 = switch (mode) {
            .copy => "copy",
            .move => "move",
            .link => "link",
        };
        const m = std.fmt.bufPrint(&buf, "Folder {s} failed ({s}). Library row kept; you can install the game manually later.", .{ verb, @errorName(e) }) catch "Folder transfer failed";
        state.setFolderScanMsg(m);
        // Still drop the entry from the scan list — the library row
        // is in place; the user can use Manual install later if
        // they fix the path issue.
        dropEntryFromBundle(state, idx);
        return;
    };

    // Write the installs row pointing at the install path the transfer
    // landed at (`dst` for move/copy, `src` for link).
    var id_buf: [36]u8 = undefined;
    generateImportUuid(frame.io, &id_buf);
    const now = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
    frame.lib.upsertInstall(&.{
        .id = id_buf,
        .game_thread_id = tid,
        .version = version_dir,
        .install_path = transfer.install_path,
        .recipe_id = "",
        .installed_at = now_s,
        .source = .manual,
    }) catch |e| {
        log.warn("folder-import: installs row for tid {d} failed: {s}", .{ tid, @errorName(e) });
    };

    state.reload_requested = true;
    dropEntryFromBundle(state, idx);
}

/// Transfer the source folder into the library — or don't, in
/// `link` mode, where the caller records the install path as-is and
/// no filesystem mutation happens at all.
///
/// `mode = .move` uses `renameAbsolute` first (cheap on same-FS) and
/// falls back to `migrate.copyVerifyDelete` on cross-FS or any
/// rename error. `mode = .copy` skips rename entirely and runs
/// copy-verify with `keep_source = true` so originals stay intact.
/// `mode = .link` does nothing on disk — `result.install_path`
/// points at `src` so the library row references the original
/// directory.
///
/// `source_delete_failed` is surfaced so the caller can notify the
/// user when the destination copy is good but the source needs
/// manual cleanup (FUSE NTFS / exFAT mounts often refuse delete).
const TransferResult = struct {
    source_delete_failed: bool = false,
    /// The path the caller should record on the library install row.
    /// `dst` for move/copy; `src` for link. Borrowed — has the same
    /// lifetime as the caller's `src` and `dst` slices.
    install_path: []const u8,
};

fn transferImported(
    alloc: std.mem.Allocator,
    io: std.Io,
    src: []const u8,
    dst: []const u8,
    mode: @import("../state.zig").ImportMode,
) !TransferResult {
    switch (mode) {
        .link => {
            // No file mutation at all. The install row will point at
            // the existing source directory. Safest mode — also the
            // only one that's reversible-by-default (just delete the
            // library row).
            return .{ .install_path = src };
        },
        .move, .copy => {
            // Make sure the destination's parent directory exists;
            // rename won't create it for us.
            if (std.mem.lastIndexOfScalar(u8, dst, '/')) |slash| {
                const parent = dst[0..slash];
                if (parent.len > 0) std.Io.Dir.cwd().createDirPath(io, parent) catch {};
            }
            switch (mode) {
                .move => {
                    // Fast path: rename. Works on same FS in one syscall.
                    // Any error (CrossDevice, PermissionDenied, DirNotEmpty,
                    // …) falls through to the slower copy-verify-delete;
                    // the migrator bails up front if the destination
                    // already exists, so we don't risk overwriting a
                    // previous import on retry.
                    std.Io.Dir.renameAbsolute(src, dst, io) catch |e| {
                        log.info("folder-import: rename failed ({s}); falling back to copy-verify-delete", .{@errorName(e)});
                        const stats = try importers_mod.migrate.copyVerifyDelete(alloc, io, src, dst, .{});
                        return .{ .install_path = dst, .source_delete_failed = stats.source_delete_failed };
                    };
                    return .{ .install_path = dst };
                },
                .copy => {
                    _ = try importers_mod.migrate.copyVerifyDelete(alloc, io, src, dst, .{ .keep_source = true });
                    return .{ .install_path = dst };
                },
                .link => unreachable, // outer switch covers this
            }
        },
    }
}

/// 36-char hex+dash UUID built from io clock + Wyhash, same shape
/// as the installer module's `generateUuid` but inlined here so
/// imports.zig doesn't reach across into actions/installer.zig.
fn generateImportUuid(io: std.Io, out: *[36]u8) void {
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const ns: u64 = @intCast(@max(0, now.raw.toNanoseconds()));
    var h = std.hash.Wyhash.init(ns);
    h.update(std.mem.asBytes(&ns));
    const a = h.final();
    const b = std.hash.Wyhash.hash(a, std.mem.asBytes(&ns));
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], a, .little);
    std.mem.writeInt(u64, bytes[8..16], b, .little);
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[pos] = '-';
            pos += 1;
        }
        out[pos] = hex[byte >> 4];
        out[pos + 1] = hex[byte & 0xF];
        pos += 2;
    }
}

fn dropEntryFromBundle(state: *State, idx: usize) void {
    const opaque_ptr = state.folder_scan_bundle orelse return;
    const mutable: *importers_mod.Bundle = @ptrCast(@alignCast(opaque_ptr));
    if (idx >= mutable.games.len) return;
    if (idx < mutable.games.len - 1) {
        mutable.games[idx] = mutable.games[mutable.games.len - 1];
    }
    mutable.games.len -= 1;
    state.folder_resolve_idx = null;
    @memset(&state.folder_resolve_url_buf, 0);
}

/// Parse a pasted "F95 thread URL or id" string into a u64 thread
/// id. Returns null when the input doesn't look like either. Lifted
/// from the existing paste-import path; this function makes it
/// reusable from the folder-scan resolution popup.
pub fn parseF95ThreadInput(s: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (trimmed.len == 0) return null;
    if (f95.extractThreadId(trimmed)) |id_str| {
        return std.fmt.parseInt(u64, id_str, 10) catch null;
    }
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

