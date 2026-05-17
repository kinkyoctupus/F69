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
const common = @import("common.zig");
const sync_act = @import("sync.zig");

const Frame = types.Frame;
const State = types.State;

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

const UpdateCheckPhase = enum(u8) { pending, done, failed };

/// Hard cap on pages walked per category so a misconfigured stamp
/// can't drag us through F95's entire history. 90 entries × 30
/// pages = 2700 most-recent threads per category, plenty for any
/// realistic check interval.
const UPDATE_WALK_MAX_PAGES: u32 = 30;

/// On first run (no persisted stamp), pretend we last checked this
/// long ago. 14 days × 86400 seconds = ~1.2 M; comfortably covers
/// the average user's catch-up window without scanning forever.
const UPDATE_WALK_FIRST_RUN_LOOKBACK_S: i64 = 14 * 24 * 60 * 60;

/// Spawn the latest-updates walker. No-op when a check is already
/// running or the library is empty.
pub fn startUpdateCheck(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_update_check != null) return;
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

    const job = alloc.create(UpdateCheckJob) catch {
        set.deinit();
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(UpdateCheckPhase.pending)),
        .alloc = alloc,
        .f95_svc = frame.f95_svc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .library_set = set,
        .since_ts = since,
        .mismatch_tids = .empty,
    };

    job.thr = std.Thread.spawn(.{}, updateCheckWorker, .{job}) catch {
        job.library_set.deinit();
        job.mismatch_tids.deinit(alloc);
        alloc.destroy(job);
        return;
    };
    job.thr.detach();

    state.pending_update_check = job;
    state.setSyncMsg("scanning F95 latest updates…");
    state.sync_status = .running;
}

fn updateCheckWorker(job: *UpdateCheckJob) void {
    var url_buf: [256]u8 = undefined;
    var page: u32 = 1;
    var done: bool = false;

    while (!done and page <= UPDATE_WALK_MAX_PAGES) {
        if (job.cancel.load(.acquire)) {
            job.err_name = "Cancelled";
            job.phase.store(@intFromEnum(UpdateCheckPhase.failed), .release);
            dvui.refresh(job.win, @src(), null);
            return;
        }
        // ts query param is just a cache-buster; the response is the
        // same regardless. Stamp it with the current second so we
        // don't accidentally hit a stale CDN copy.
        const cache_buster = std.Io.Clock.Timestamp.now(job.io, .real).raw.toSeconds();
        const url = std.fmt.bufPrint(
            &url_buf,
            "https://f95zone.to/sam/latest_alpha/latest_data.php?cmd=list&cat=games&page={d}&sort=date&rows=90&_={d}",
            .{ page, cache_buster },
        ) catch {
            job.err_name = "InternalUrlBuild";
            job.phase.store(@intFromEnum(UpdateCheckPhase.failed), .release);
            dvui.refresh(job.win, @src(), null);
            return;
        };

        const body = job.f95_svc.client.get(url) catch |e| {
            job.err_name = @errorName(e);
            job.phase.store(@intFromEnum(UpdateCheckPhase.failed), .release);
            dvui.refresh(job.win, @src(), null);
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

            job.scanned += 1;
            if (ts > job.newest_seen_ts) job.newest_seen_ts = ts;

            if (ts < job.since_ts) {
                done = true;
                continue; // keep scanning the rest of this page for any newer entries that lagged in sort order
            }

            if (job.library_set.contains(tid)) {
                job.mismatch_tids.append(job.alloc, tid) catch {};
            }
        }

        page += 1;
    }

    job.phase.store(@intFromEnum(UpdateCheckPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
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
    const job = state.pending_update_check orelse return;
    const phase: UpdateCheckPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;

    const cleanup = struct {
        fn run(j: *UpdateCheckJob, s: *types.State) void {
            j.library_set.deinit();
            j.mismatch_tids.deinit(j.alloc);
            j.alloc.destroy(j);
            s.pending_update_check = null;
        }
    }.run;

    if (phase == .failed) {
        const cancelled = job.err_name != null and std.mem.eql(u8, job.err_name.?, "Cancelled");
        if (cancelled) {
            // User-driven stop — silent like the sync/bookmark cancel.
            state.sync_status = .idle;
            state.sync_msg.clear();
            cleanup(job, state);
            return;
        }
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "update check failed: {s}", .{common.friendlyError(job.err_name orelse "?")}) catch "update check failed";
        state.sync_status = .err;
        state.setSyncMsg(m);
        cleanup(job, state);
        return;
    }

    // De-dup the mismatch list — the same tid can appear twice if a
    // game was updated more than once within the check window.
    var seen: std.AutoHashMap(u64, void) = .init(frame.lib.alloc);
    defer seen.deinit();
    var uniques: std.ArrayList(u64) = .empty;
    defer uniques.deinit(frame.lib.alloc);
    for (job.mismatch_tids.items) |tid| {
        const r = seen.getOrPut(tid) catch break;
        if (r.found_existing) continue;
        uniques.append(frame.lib.alloc, tid) catch break;
    }

    // Always advance the stamp on success — even with zero hits, we
    // confirmed nothing happened in our library during the window.
    if (job.newest_seen_ts > 0) {
        state.last_update_check_ts = job.newest_seen_ts;
        persistInt64IfDirty(frame.info.last_update_check_path, frame.io, job.newest_seen_ts);
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
        const m = std.fmt.bufPrint(&ok_buf, "no library updates ({d} F95 entries scanned)", .{job.scanned}) catch "no library updates";
        state.sync_status = .ok;
        state.setSyncMsg(m);
        cleanup(job, state);
        return;
    }

    // Append to (or install) the sync queue.
    if (state.sync_queue) |q| {
        const new_q = frame.lib.alloc.realloc(q, q.len + uniques.items.len) catch {
            cleanup(job, state);
            return;
        };
        @memcpy(new_q[q.len..], uniques.items);
        state.sync_queue = new_q;
        state.sync_queue_total += @intCast(uniques.items.len);
    } else {
        const owned = frame.lib.alloc.alloc(u64, uniques.items.len) catch {
            cleanup(job, state);
            return;
        };
        @memcpy(owned, uniques.items);
        state.sync_queue = owned;
        state.sync_queue_idx = 0;
        state.sync_queue_started = 0;
        state.sync_queue_total = @intCast(uniques.items.len);
    }

    var m_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&m_buf, "queued {d} updates ({d} F95 entries scanned)", .{ uniques.items.len, job.scanned }) catch "queued updates";
    state.sync_status = .ok;
    state.setSyncMsg(m);

    cleanup(job, state);

    if (state.pending_sync == null) sync_act.advanceSyncQueue(frame);
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

/// Click handler for Settings → "Import from F95Checker...". Opens a
/// directory picker for the source's games-base-dir (where the
/// relative paths in the source DB resolve against), then spawns the
/// worker. Source data path is the upstream-default
/// `~/.config/f95checker/db.sqlite3`.
pub fn doImportFromF95Checker(frame: *Frame) void {
    startImport(frame, .f95checker);
}

/// Click handler for Settings → "Import from xLibrary...". Same flow,
/// source data path is `~/.config/xlibrary/games-data.json`.
pub fn doImportFromXLibrary(frame: *Frame) void {
    startImport(frame, .xlibrary);
}

fn startImport(frame: *Frame, source: import_job.Source) void {
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

