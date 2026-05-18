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
    if (state.sync_queue != null and state.pending_sync == null) {
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

pub fn doFolderScan(frame: *Frame, dir_path: []const u8) void {
    const state = frame.state;
    if (dir_path.len == 0) {
        state.setFolderScanMsg("Pick a folder first.");
        return;
    }
    // Drop the previous scan's bundle if any so we don't leak.
    freeFolderScan(state, frame.lib.alloc);
    const bundle = folder_scan.scan(frame.lib.alloc, frame.io, dir_path) catch |e| {
        var buf: [192]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Scan failed: {s}", .{@errorName(e)}) catch "Scan failed";
        state.setFolderScanMsg(m);
        return;
    };
    // Heap-copy the bundle struct so we can stash a pointer on
    // State (Bundle.deinit takes a *Self).
    const bundle_ptr = frame.lib.alloc.create(importers_mod.Bundle) catch {
        var b_copy = bundle;
        b_copy.deinit();
        state.setFolderScanMsg("Out of memory.");
        return;
    };
    bundle_ptr.* = bundle;
    state.folder_scan_bundle = bundle_ptr;
    var buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&buf, "found {d} candidate folder(s)", .{bundle_ptr.games.len}) catch "scanned";
    state.setFolderScanMsg(m);
}

pub fn freeFolderScan(state: *State, alloc: std.mem.Allocator) void {
    if (state.folder_scan_bundle) |opaque_ptr| {
        const bundle: *importers_mod.Bundle = @ptrCast(@alignCast(opaque_ptr));
        bundle.deinit();
        alloc.destroy(bundle);
        state.folder_scan_bundle = null;
    }
    state.folder_resolve_idx = null;
    @memset(&state.folder_resolve_url_buf, 0);
}

pub fn folderScanBundle(state: *const State) ?*const importers_mod.Bundle {
    if (state.folder_scan_bundle) |p| {
        return @ptrCast(@alignCast(p));
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

    transferImported(alloc, frame.io, src_path, dst_path, mode) catch |e| {
        var buf: [256]u8 = undefined;
        const verb: []const u8 = if (mode == .copy) "copy" else "move";
        const m = std.fmt.bufPrint(&buf, "Folder {s} failed ({s}). Library row kept; you can install the game manually later.", .{ verb, @errorName(e) }) catch "Folder transfer failed";
        state.setFolderScanMsg(m);
        // Still drop the entry from the scan list — the library row
        // is in place; the user can use Manual install later if
        // they fix the path issue.
        dropEntryFromBundle(state, idx);
        return;
    };

    // Write the installs row pointing at the new destination so the
    // game shows up as installed in the library.
    var id_buf: [36]u8 = undefined;
    generateImportUuid(frame.io, &id_buf);
    const now = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
    frame.lib.upsertInstall(&.{
        .id = id_buf,
        .game_thread_id = tid,
        .version = version_dir,
        .install_path = dst_path,
        .recipe_id = "",
        .installed_at = now_s,
        .source = .manual,
    }) catch |e| {
        log.warn("folder-import: installs row for tid {d} failed: {s}", .{ tid, @errorName(e) });
    };

    state.reload_requested = true;
    dropEntryFromBundle(state, idx);
}

/// Transfer the source folder into the library. `mode = .move` uses
/// `renameAbsolute` first (cheap on same-FS) and falls back to
/// `migrate.copyVerifyDelete` on cross-FS or any rename error.
/// `mode = .copy` skips rename entirely and runs copy-verify with
/// `keep_source = true` so the originals stay intact (peak AND final
/// disk = 2x — the user opted into that with the radio).
fn transferImported(
    alloc: std.mem.Allocator,
    io: std.Io,
    src: []const u8,
    dst: []const u8,
    mode: @import("../state.zig").ImportMode,
) !void {
    // Make sure the destination's parent directory exists; rename
    // won't create it for us.
    if (std.mem.lastIndexOfScalar(u8, dst, '/')) |slash| {
        const parent = dst[0..slash];
        if (parent.len > 0) std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    switch (mode) {
        .move => {
            // Fast path: rename. Works on same FS in one syscall. Any
            // error (CrossDevice, PermissionDenied, DirNotEmpty, …)
            // falls through to the slower copy-verify-delete; the
            // migrator bails up front if the destination already exists,
            // so we don't risk overwriting a previous import on retry.
            std.Io.Dir.renameAbsolute(src, dst, io) catch |e| {
                log.info("folder-import: rename failed ({s}); falling back to copy-verify-delete", .{@errorName(e)});
                _ = try importers_mod.migrate.copyVerifyDelete(alloc, io, src, dst, .{});
            };
        },
        .copy => {
            _ = try importers_mod.migrate.copyVerifyDelete(alloc, io, src, dst, .{ .keep_source = true });
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

