// User actions that mutate state but don't render UI:
//   - sync engine (worker thread + atomic + drainSync per frame)
//   - sync-all queue
//   - cover-bytes cache (lazy disk read + LRU-ish promotion)
//   - browser launch (non-blocking via detached worker)
//   - delete game (DB row + cover file + cache eviction)
//
// All public to `screens.zig` (which calls them on button presses) and
// to `ui.zig` (which calls drainSync each frame and startSyncAll on
// the post-import auto-sync trigger).

const std = @import("std");
const atomic_io = @import("util_atomic_io");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const f95 = @import("f95");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox_mod = @import("sandbox");
const convert_mod = @import("convert");
const compat_mod = @import("compat");
const installer_mod = @import("installer");
const resolver = @import("resolver");
const dvui = @import("dvui");
const image = @import("image");
const version_mod = @import("util_version");
const types = @import("types.zig");
const state_mod = @import("state.zig");
const mod_job_queue = @import("mod_job_queue.zig");
const import_job = @import("import_job.zig");
const importers_mod = @import("importers");
const file_picker = @import("util_file_picker");

const Frame = types.Frame;
const State = types.State;

// ============================================================
//  sync-batch recap — end-of-run "what changed" popup
// ============================================================
//
// During a sync-all / updates-check batch, every job that ends with
// a *different* version than what we stored (and only when we had
// a prior version to compare against — first-time syncs don't
// count as updates) appends an entry here. When the batch
// finishes, the UI raises a modal listing the games whose versions
// moved. Mirrors F95Checker's end-of-check recap.

pub const SyncRecapEntry = struct {
    thread_id: u64,
    /// All slices alloc-owned by `frame.lib.alloc`. Freed via
    /// `freeSyncRecap` on dismiss / app shutdown.
    name: []u8,
    old_version: []u8,
    new_version: []u8,
    /// True when the auto-update hook in `drainSync` kicked off a
    /// background download for this row. Popup label appends a
    /// "· auto-downloaded" suffix so the user knows the new version
    /// is already being fetched.
    auto_downloaded: bool = false,
};

const SyncRecapList = std.ArrayList(SyncRecapEntry);

fn syncRecapList(frame: *Frame) *SyncRecapList {
    if (frame.state.sync_recap) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
    const list_ptr = frame.lib.alloc.create(SyncRecapList) catch unreachable;
    list_ptr.* = .empty;
    frame.state.sync_recap = list_ptr;
    return list_ptr;
}

/// Read-only accessor for the UI — returns `&.{}` when the recap
/// hasn't been touched yet.
pub fn syncRecapEntries(state: *const State) []const SyncRecapEntry {
    const opaque_ptr = state.sync_recap orelse return &.{};
    const list_ptr: *const SyncRecapList = @ptrCast(@alignCast(opaque_ptr));
    return list_ptr.items;
}

/// Free every entry's owned strings + the list itself. Idempotent.
pub fn freeSyncRecap(state: *State, alloc: std.mem.Allocator) void {
    if (state.sync_recap) |opaque_ptr| {
        const list_ptr: *SyncRecapList = @ptrCast(@alignCast(opaque_ptr));
        for (list_ptr.items) |e| {
            alloc.free(e.name);
            alloc.free(e.old_version);
            alloc.free(e.new_version);
        }
        list_ptr.deinit(alloc);
        alloc.destroy(list_ptr);
        state.sync_recap = null;
    }
    state.sync_recap_show = false;
}

/// Clear the recap entries without destroying the backing list. Used
/// at the start of each new batch so stale entries from a previous
/// run don't leak into the new popup.
pub fn clearSyncRecap(frame: *Frame) void {
    const alloc = frame.lib.alloc;
    if (frame.state.sync_recap) |opaque_ptr| {
        const list_ptr: *SyncRecapList = @ptrCast(@alignCast(opaque_ptr));
        for (list_ptr.items) |e| {
            alloc.free(e.name);
            alloc.free(e.old_version);
            alloc.free(e.new_version);
        }
        list_ptr.clearRetainingCapacity();
    }
    frame.state.sync_recap_show = false;
}

/// Append a version-bump entry. Silently drops on alloc failure —
/// the recap is convenience, not correctness, so it shouldn't fail
/// loudly.
fn pushSyncRecap(
    frame: *Frame,
    thread_id: u64,
    name: []const u8,
    old_version: []const u8,
    new_version: []const u8,
) void {
    const alloc = frame.lib.alloc;
    const name_dup = alloc.dupe(u8, name) catch return;
    errdefer alloc.free(name_dup);
    const old_dup = alloc.dupe(u8, old_version) catch {
        alloc.free(name_dup);
        return;
    };
    errdefer alloc.free(old_dup);
    const new_dup = alloc.dupe(u8, new_version) catch {
        alloc.free(name_dup);
        alloc.free(old_dup);
        return;
    };
    const list = syncRecapList(frame);
    list.append(alloc, .{
        .thread_id = thread_id,
        .name = name_dup,
        .old_version = old_dup,
        .new_version = new_dup,
    }) catch {
        alloc.free(name_dup);
        alloc.free(old_dup);
        alloc.free(new_dup);
    };
}

/// Flip the `auto_downloaded` flag on the recap entry matching
/// `thread_id`. Called from `drainSync` right after the auto-update
/// hook enqueues a download so the end-of-batch popup can label the
/// row. No-op when the entry isn't found (shouldn't happen — we
/// only call this right after `pushSyncRecap` on the same id — but
/// keep it forgiving rather than asserting).
fn markRecapAutoDownloaded(state: *State, thread_id: u64) void {
    const opaque_ptr = state.sync_recap orelse return;
    const list_ptr: *SyncRecapList = @ptrCast(@alignCast(opaque_ptr));
    for (list_ptr.items) |*entry| {
        if (entry.thread_id == thread_id) {
            entry.auto_downloaded = true;
            return;
        }
    }
}

// ============================================================
//  sync action — worker-thread offload
// ============================================================

/// Phases of the worker. UI thread only reads; worker only writes
/// (transitions are .pending → .done|.failed exactly once).
const SyncJobPhase = enum(u8) { pending, done, failed };

/// One outstanding Sync. Heap-alloc'd so it outlives the click handler;
/// the UI thread drains and frees once `phase` transitions away from
/// `.pending`.
pub const SyncJob = struct {
    /// Atomic so the UI thread sees writes from the worker.
    phase: std.atomic.Value(u8),
    thread_id: u64,
    /// Set when phase == .done. Strings are job.alloc-owned; drainSync
    /// copies them into `lib.alloc`-owned slots via `applyScrape`, then
    /// frees these.
    rating: ?f32 = null,
    vote_count: ?u32 = null,
    engine: ?library.Engine = null,
    dev_status: ?library.DevStatus = null,
    last_updated_at: ?i64 = null,
    thread_info_md: ?[]u8 = null,
    censored: ?library.CensoredState = null,
    name: ?[]u8 = null,
    version: ?[]u8 = null,
    developer: ?[]u8 = null,
    /// Outer slice + each inner string job.alloc-owned. drainSync
    /// hands them to Library.applyScrape (which dupes), then free.
    tags: ?[]const []const u8 = null,
    /// Same shape as `tags` — screenshot URLs scraped from the OP.
    screenshots: ?[]const []const u8 = null,
    /// Plain-text scrape blobs — description / changelog / reviews.
    /// All job.alloc-owned; drainSync transfers to Library and the
    /// cleanup() helper frees on the way out.
    description_md: ?[]u8 = null,
    changelog_md: ?[]u8 = null,
    reviews_md: ?[]u8 = null,
    downloads_md: ?[]u8 = null,
    /// Download link entries, each pre-formatted as
    /// `<host>\t<url>\t<label>`. Same lifetime as `tags`.
    download_links: ?[]const []const u8 = null,
    /// Set when phase == .failed; static string, not allocator-owned.
    err_name: ?[]const u8 = null,
    /// Detached worker thread handle; owned by Job, not joined (we drain
    /// via the atomic flag and detach so the OS reaps the thread).
    thr: std.Thread,
    /// Allocator that owns this Job + url copy.
    alloc: std.mem.Allocator,
    url: []u8,
    f95_svc: *f95.Service,
    /// Used to wake the UI thread once the worker writes `phase`.
    win: *dvui.Window,
    /// Owned copy of the covers cache dir; used by the worker to write
    /// the fetched cover bytes. Owned-and-freed alongside the Job.
    covers_dir: []u8,
    /// Set to `true` by the worker after it writes a fresh cover file
    /// so `drainSync` can invalidate the in-memory cache entry.
    cover_updated: bool = false,
    /// Io vtable — worker uses it for the cover-file write.
    io: std.Io,
    /// Set by the UI thread (Cancel button) to ask the worker to bail
    /// out at the next phase boundary. The worker treats this as an
    /// expected exit, not an error.
    cancel: std.atomic.Value(bool) = .init(false),
    /// Intra-sync progress: items completed / planned. Updated by the
    /// worker after each phase (HTML parse + cover + each screenshot).
    /// The UI banner reads both atomically to render the "step k/N"
    /// sub-bar inside a single game's sync.
    progress_done: std.atomic.Value(u32) = .init(0),
    progress_total: std.atomic.Value(u32) = .init(1),
    /// Worker → drain hint: F95 returned HTTP 404 for this thread.
    /// drainSync treats this as a soft outcome (mark the row's
    /// `dev_status = .orphaned`, refresh `last_scraped_at`) rather
    /// than a hard failure that surfaces an error banner.
    orphaned: bool = false,
};

pub fn syncGame(frame: *Frame, game: *library.Game) void {
    const state = frame.state;
    // If a sync is already running, append THIS game to the queue
    // instead of bouncing the click. The drainSync loop will pop it
    // when the active job finishes. Idempotent: re-clicking on a
    // game that's already queued is a no-op.
    if (state.pending_sync != null) {
        if (queuePosition(state, game.f95_thread_id) != null) return;
        appendToSyncQueue(frame.lib.alloc, state, game.f95_thread_id) catch {
            state.sync_status = .err;
            state.setSyncMsg("queue alloc failed");
        };
        return;
    }

    var tid_buf: [32]u8 = undefined;
    const tid_str = std.fmt.bufPrint(&tid_buf, "{d}", .{game.f95_thread_id}) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: thread id format");
        return;
    };
    var url_buf: [128]u8 = undefined;
    const url_slice = f95.canonicalUrl(&url_buf, tid_str) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: url build");
        return;
    };

    const alloc = frame.lib.alloc;
    const job = alloc.create(SyncJob) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: job alloc");
        return;
    };
    const url_owned = alloc.dupe(u8, url_slice) catch {
        alloc.destroy(job);
        state.sync_status = .err;
        state.setSyncMsg("internal error: url dup");
        return;
    };
    const covers_owned = alloc.dupe(u8, frame.info.covers_dir) catch {
        alloc.free(url_owned);
        alloc.destroy(job);
        state.sync_status = .err;
        state.setSyncMsg("internal error: covers_dir dup");
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(SyncJobPhase.pending)),
        .thread_id = game.f95_thread_id,
        .alloc = alloc,
        .url = url_owned,
        .f95_svc = frame.f95_svc,
        .win = frame.win,
        .covers_dir = covers_owned,
        .io = frame.io,
        .thr = undefined,
        .cancel = .init(false),
        .progress_done = .init(0),
        .progress_total = .init(1),
    };

    job.thr = std.Thread.spawn(.{}, syncWorker, .{job}) catch {
        alloc.free(covers_owned);
        alloc.free(url_owned);
        alloc.destroy(job);
        state.sync_status = .err;
        state.setSyncMsg("internal error: thread spawn");
        return;
    };
    // Detach is safe even if the worker has already exited by the time
    // we get here — POSIX `pthread_detach` accepts joinable+exited
    // threads. The worker only writes `job.phase` via release-store +
    // `dvui.refresh`; we never read it before `state.pending_sync`
    // is set below, so drainSync can't fire prematurely.
    job.thr.detach();

    state.sync_status = .running;
    // Banner shows the active game's name + queue progress. If the
    // user adds another game while this one's running, the queue
    // The banner reads `state.currentSyncName()` and the queue
    // counters directly — no need to bake them into `sync_msg`. Clear
    // any lingering completion message so a stale "sync-all complete"
    // doesn't sit on top of the in-progress banner.
    state.setCurrentSyncName(game.name);
    state.sync_msg_len = 0;
    state.sync_status = .running;
    state.pending_sync = job;
}

/// Wall-clock milliseconds via the Zig 0.16 `std.Io.Clock` API.
/// Hides the verbose call site so the timing log macros stay tidy.
fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

fn syncWorker(job: *SyncJob) void {
    // Coarse wall-clock timing so the log shows where the seconds go.
    // Phase boundaries: HTML fetch+parse → cover fetch → screenshots.
    // The image phases dominate when a thread has many screenshots
    // because each GET is rate-limited at the F95 client level.
    const t_start = nowMs(job.io);
    const scraped = job.f95_svc.scrapeThread(job.url) catch |e| {
        // HTTP 404 from F95 means the thread is gone — dev took it
        // down, mod nuked it, whatever. We don't want to error out
        // (the user would have to dismiss a banner per orphaned
        // game during a sync-all). Instead flag the job and let
        // drainSync flip the row's dev_status to .orphaned.
        if (e == f95.errors.Error.NotFound) {
            log.info("sync tid={d} ORPHANED (F95 returned 404) elapsed_ms={d}", .{ job.thread_id, nowMs(job.io) - t_start });
            job.orphaned = true;
            job.phase.store(@intFromEnum(SyncJobPhase.done), .release);
            dvui.refresh(job.win, @src(), null);
            return;
        }
        log.info("sync tid={d} FAIL scrape elapsed_ms={d} err={s}", .{ job.thread_id, nowMs(job.io) - t_start, @errorName(e) });
        job.err_name = @errorName(e);
        job.phase.store(@intFromEnum(SyncJobPhase.failed), .release);
        dvui.refresh(job.win, @src(), null);
        return;
    };
    const t_after_scrape = nowMs(job.io);
    log.info(
        "sync tid={d} scrape_ms={d} name={?s} engine_str={?s} version={?s} developer={?s}",
        .{ job.thread_id, t_after_scrape - t_start, scraped.name, scraped.engine_str, scraped.version, scraped.developer },
    );

    // ScrapedThread strings are job.alloc-owned; we transfer ownership
    // onto the SyncJob fields, drainSync copies into Library.
    job.name = if (scraped.name) |n| @constCast(n) else null;
    job.version = if (scraped.version) |v| @constCast(v) else null;
    job.developer = if (scraped.developer) |d| @constCast(d) else null;
    job.rating = scraped.rating;
    job.vote_count = scraped.vote_count;
    if (scraped.engine_str) |e| {
        job.engine = library.Engine.fromBracket(e);
        job.alloc.free(e);
    }
    if (scraped.dev_status_str) |s| {
        job.dev_status = library.DevStatus.fromBracket(s);
        job.alloc.free(s);
    }
    if (scraped.last_updated_at) |ts| job.last_updated_at = ts;
    if (scraped.thread_info_md) |t| job.thread_info_md = @constCast(t);
    if (scraped.censored_str) |c| {
        job.censored = library.CensoredState.fromText(c);
        job.alloc.free(c);
    }
    if (scraped.tags.len > 0) job.tags = scraped.tags;
    if (scraped.screenshots.len > 0) job.screenshots = scraped.screenshots;
    if (scraped.description_md) |d| job.description_md = @constCast(d);
    if (scraped.changelog_md) |c| job.changelog_md = @constCast(c);
    if (scraped.reviews_md) |r| job.reviews_md = @constCast(r);
    if (scraped.downloads_md) |d| job.downloads_md = @constCast(d);
    if (scraped.download_links.len > 0) {
        job.download_links = encodeDownloadLinks(job.alloc, scraped.download_links) catch null;
        // Encoded copy lives on the job; free the source list now.
        for (scraped.download_links) |link| {
            job.alloc.free(link.url);
            if (link.label) |lab| job.alloc.free(lab);
        }
        job.alloc.free(scraped.download_links);
    }

    // Phase-1 work in this worker is intentionally minimal: text +
    // cover only. Screenshots are deferred to a background image
    // worker (see ImageJob / drainImageQueue) so the library row
    // becomes usable as soon as the cover + metadata commit. The
    // image-fetch phase used to dominate wall time (≥1.5s per shot
    // through the rate limiter) and blocked the row from showing
    // until the very last screenshot landed.
    const want_cover = scraped.cover_url != null;
    var cover_path_buf: [256]u8 = undefined;
    const cover_present = if (want_cover) blk: {
        const cp = std.fmt.bufPrint(&cover_path_buf, "{s}/{d}", .{ job.covers_dir, job.thread_id }) catch break :blk false;
        break :blk fileExists(job.io, cp);
    } else true;

    const t_before_images = nowMs(job.io);
    if (!want_cover or cover_present) {
        // Nothing to fetch in this worker. Leave `progress_total` at
        // its initial 1 so the banner's sub-progress doesn't flicker.
        if (scraped.cover_url) |cu| job.alloc.free(cu);
        log.info(
            "sync tid={d} cover_cached={any} shots_deferred={d}",
            .{ job.thread_id, want_cover and cover_present, scraped.screenshots.len },
        );
    } else {
        // Cover work coming up — publish the planned step count.
        job.progress_total.store(2, .release);
        job.progress_done.store(1, .release);
        dvui.refresh(job.win, @src(), null);
        if (scraped.cover_url) |cu| {
            defer job.alloc.free(cu);
            if (job.cancel.load(.acquire)) {
                log.info("sync tid={d} cancelled before cover fetch", .{job.thread_id});
            } else {
                const t_c0 = nowMs(job.io);
                if (fetchAndWriteCover(job, cu)) {
                    job.cover_updated = true;
                    log.info("sync tid={d} cover_ms={d}", .{ job.thread_id, nowMs(job.io) - t_c0 });
                } else |_| {
                    log.info("sync tid={d} cover FAIL elapsed_ms={d}", .{ job.thread_id, nowMs(job.io) - t_c0 });
                }
                _ = job.progress_done.fetchAdd(1, .release);
                dvui.refresh(job.win, @src(), null);
            }
        }
    }

    // If the user clicked Cancel, mark the job failed so drainSync
    // skips the applyScrape write — the scraped data is still owned
    // by job and will be freed via cleanup(). This keeps cancellation
    // observable to the UI without partial-row commits.
    if (job.cancel.load(.acquire)) {
        log.info("sync tid={d} TOTAL_ms={d} CANCELLED", .{ job.thread_id, nowMs(job.io) - t_start });
        job.err_name = "Cancelled";
        job.phase.store(@intFromEnum(SyncJobPhase.failed), .release);
        dvui.refresh(job.win, @src(), null);
        return;
    }

    log.info(
        "sync tid={d} TOTAL_ms={d} scrape_ms={d} images_ms={d}",
        .{ job.thread_id, nowMs(job.io) - t_start, t_after_scrape - t_start, nowMs(job.io) - t_before_images },
    );
    job.phase.store(@intFromEnum(SyncJobPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

/// Encode a `DownloadLink` slice into the persisted line format —
/// `<host>\t<url>\t<label>` — and return an outer slice owned by
/// `alloc` (each row also `alloc`-owned). Caller frees inner + outer.
fn encodeDownloadLinks(alloc: std.mem.Allocator, links: []const f95.DownloadLink) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    for (links) |link| {
        const host = @tagName(link.host);
        const label = link.label orelse "";
        const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}", .{ host, link.url, label });
        errdefer alloc.free(line);
        try out.append(alloc, line);
    }
    return try out.toOwnedSlice(alloc);
}

/// Worker-thread helper: fetch image bytes via the same rate-limited
/// HTTP client and atomically replace the on-disk cover file.
fn fetchAndWriteCover(job: *SyncJob, cover_url: []const u8) !void {
    const raw = try job.f95_svc.client.getImage(cover_url);
    defer job.alloc.free(raw);
    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("cover transcode failed ({s}): {s}", .{ @errorName(e), cover_url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try coverPath(&path_buf, job.covers_dir, job.thread_id);
    try writeAtomic(job.io, path, ready);

    // Also write the thumbnail. Failure here is non-fatal — the lazy
    // path in `thumbBytes` will regenerate from the full-size file.
    writeThumbBeside(job.alloc, job.io, path, ready) catch |e| {
        std.log.scoped(.ui_actions).warn("cover thumb gen failed: {s}", .{@errorName(e)});
    };
}

/// Thin shim around `util/atomic_io.writeFileAtomic`. dvui reads
/// images via stb, so a half-written file would render garbage —
/// the rename ensures readers only ever see the complete file.
fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try atomic_io.writeFileAtomic(io, path, bytes);
}

/// Fetch a single screenshot to `<covers_dir>/<tid>.s<n>`. Same atomic
/// write pattern as the cover.
fn fetchAndWriteScreenshot(job: *SyncJob, url: []const u8, idx: usize) !void {
    const raw = try job.f95_svc.client.getImage(url);
    defer job.alloc.free(raw);
    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("screenshot {d} transcode failed ({s}): {s}", .{ idx, @errorName(e), url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ job.covers_dir, job.thread_id, idx });
    try writeAtomic(job.io, path, ready);

    writeThumbBeside(job.alloc, job.io, path, ready) catch |e| {
        std.log.scoped(.ui_actions).warn("screenshot {d} thumb gen failed: {s}", .{ idx, @errorName(e) });
    };
}

/// Generate a thumbnail from the JPEG bytes we just wrote and save it
/// to `<full_path>.t` atomically. Pulled into its own helper because
/// both cover and screenshot fetches need it.
fn writeThumbBeside(alloc: std.mem.Allocator, io: std.Io, full_path: []const u8, ready_bytes: []const u8) !void {
    const thumb_bytes = try thumbify(alloc, ready_bytes);
    defer alloc.free(thumb_bytes);
    var tbuf: [320]u8 = undefined;
    const tpath = try std.fmt.bufPrint(&tbuf, "{s}.t", .{full_path});
    try writeAtomic(io, tpath, thumb_bytes);
}

/// Normalize downloaded image bytes for on-disk caching.
///
/// Every supported format is decoded to RGBA, downscaled to fit under
/// the SDL3 GPU transfer-buffer ceiling (`image.MAX_DIM` per side),
/// and re-encoded as JPEG quality 90. The disk cache thus contains
/// uniform JPEGs at known-safe dimensions — dvui's render-time stb
/// path can never hit the over-2048-pixel-per-side memcpy that crashed
/// on a 1 MiB animated GIF from the F95 CDN.
///
/// Format routing:
///   - AVIF / HEIF (`ftyp`-prefixed) → libavif (statically linked)
///   - JPEG / PNG / GIF / BMP        → stb_image (vendored by dvui)
///   - anything else                  → `UnsupportedImageFormat`
///
/// GIFs lose animation here (stb returns the first frame only). That's
/// the same trade-off the rest of the pipeline made anyway — dvui can't
/// animate GIFs. If we ever want playback we'd swap this for
/// `stbi_load_gif_from_memory` and a per-game frame cache.
fn prepareImageForDisk(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (image.isAvif(raw)) {
        var dec = try image.decodeAvif(alloc, raw);
        defer dec.deinit();
        return try fitAndEncodeJpeg(alloc, dec.rgba, dec.width, dec.height);
    }
    if (image.isStbFormat(raw)) {
        return try decodeStbAndEncodeJpeg(alloc, raw);
    }
    return error.UnsupportedImageFormat;
}

/// stb decode → fit → JPEG encode. We must memcpy stb's output into
/// our own allocator because `stbi_image_free` expects libc's free
/// (stb is built without libc malloc shims, but the freer matches
/// stb's internal allocator).
fn decodeStbAndEncodeJpeg(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var iw: c_int = 0;
    var ih: c_int = 0;
    var ic: c_int = 0;
    const data = dvui.c.stbi_load_from_memory(
        raw.ptr,
        @intCast(raw.len),
        &iw,
        &ih,
        &ic,
        4, // request RGBA
    ) orelse {
        log.warn("stbi_load_from_memory failed", .{});
        return error.DecodeFailed;
    };
    defer dvui.c.stbi_image_free(data);

    if (iw <= 0 or ih <= 0) return error.DecodeFailed;
    const w: u32 = @intCast(iw);
    const h: u32 = @intCast(ih);
    const total: usize = @as(usize, w) * h * 4;
    return try fitAndEncodeJpeg(alloc, data[0..total], w, h);
}

/// Halve-until-fits, then JPEG-encode. Always writes a heap-allocated
/// slice; caller frees.
fn fitAndEncodeJpeg(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    const fit = try image.fitToMaxDim(alloc, rgba, w, h);
    defer alloc.free(fit.rgba);
    return try encodeRgbaToJpeg(alloc, fit.rgba, fit.w, fit.h, JPEG_QUALITY_FULL);
}

/// JPEG qualities. Full-size cache uses 90 (near-imperceptible loss);
/// thumbnails use 85 (still clean at 96×54, smaller files).
const JPEG_QUALITY_FULL: c_int = 90;
const JPEG_QUALITY_THUMB: c_int = 85;

/// Encode an RGBA8 buffer to a JPEG byte stream via stb_image_write
/// (vendored by dvui). stb's JPEG encoder ignores the alpha channel,
/// which is fine for game screenshots.
fn encodeRgbaToJpeg(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, quality: c_int) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    errdefer aw.deinit();

    const res = dvui.c.stbi_write_jpg_to_func(
        &stbiJpegWriteCallback,
        @ptrCast(&aw.writer),
        @intCast(w),
        @intCast(h),
        4, // RGBA in; stb drops the alpha channel for JPEG
        rgba.ptr,
        quality,
    );
    if (res == 0) return error.JpegEncodeFailed;
    return aw.toOwnedSlice();
}

/// Decode → resize to thumbnail cap → JPEG q85 encode. The result
/// is what we save as `<tid>.t` / `<tid>.s<n>.t` so the ribbon, list
/// rows, and grid cards never have to decode a full-size image.
fn thumbify(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (image.isAvif(raw)) {
        var dec = try image.decodeAvif(alloc, raw);
        defer dec.deinit();
        const fit = try image.fitToCap(alloc, dec.rgba, dec.width, dec.height, image.THUMB_CAP);
        defer alloc.free(fit.rgba);
        return try encodeRgbaToJpeg(alloc, fit.rgba, fit.w, fit.h, JPEG_QUALITY_THUMB);
    }
    if (image.isStbFormat(raw)) {
        var iw: c_int = 0;
        var ih: c_int = 0;
        var ic: c_int = 0;
        const data = dvui.c.stbi_load_from_memory(raw.ptr, @intCast(raw.len), &iw, &ih, &ic, 4) orelse {
            log.warn("thumbify: stbi_load failed", .{});
            return error.DecodeFailed;
        };
        defer dvui.c.stbi_image_free(data);
        if (iw <= 0 or ih <= 0) return error.DecodeFailed;
        const w: u32 = @intCast(iw);
        const h: u32 = @intCast(ih);
        const total: usize = @as(usize, w) * h * 4;
        const fit = try image.fitToCap(alloc, data[0..total], w, h, image.THUMB_CAP);
        defer alloc.free(fit.rgba);
        return try encodeRgbaToJpeg(alloc, fit.rgba, fit.w, fit.h, JPEG_QUALITY_THUMB);
    }
    return error.UnsupportedImageFormat;
}

/// stb_image_write callback that funnels its emitted bytes into a
/// `std.Io.Writer.Allocating`. stb writes the JPEG in chunks; we
/// concatenate them all into the writer's growable buffer.
fn stbiJpegWriteCallback(ctx: ?*anyopaque, data_ptr: ?*anyopaque, len: c_int) callconv(.c) void {
    const writer: *std.Io.Writer = @ptrCast(@alignCast(ctx.?));
    if (data_ptr == null or len <= 0) return;
    const bytes: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data_ptr.?)))[0..@intCast(len)];
    writer.writeAll(bytes) catch |err| {
        std.log.scoped(.ui_actions).warn("jpeg encode write failed: {s}", .{@errorName(err)});
    };
}

/// File path for a screenshot — paired with `coverPath` for the cover.
pub fn screenshotPath(buf: []u8, covers_dir: []const u8, thread_id: u64, idx: usize) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/{d}.s{d}", .{ covers_dir, thread_id, idx });
}

/// True when on-disk image set already matches the scrape: cover
/// file present (when `want_cover`), s1..s<want_count> all present,
/// and s<want_count+1> absent (so we re-fetch when an image was
/// added). Used to short-circuit the per-game image fetch loop on
/// re-sync. Any stat error is treated as "missing".
fn imagesAlreadyFetched(
    io: std.Io,
    covers_dir: []const u8,
    thread_id: u64,
    want_cover: bool,
    want_count: usize,
) bool {
    var path_buf: [256]u8 = undefined;

    if (want_cover) {
        const cover = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ covers_dir, thread_id }) catch return false;
        if (!fileExists(io, cover)) return false;
    }

    var i: usize = 1;
    while (i <= want_count) : (i += 1) {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ covers_dir, thread_id, i }) catch return false;
        if (!fileExists(io, p)) return false;
    }

    // Reject when the on-disk set has MORE files than the scrape —
    // means the OP gained/lost screenshots and we should re-fetch
    // wholesale. (Cheap check; only one extra stat per call.)
    const extra = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ covers_dir, thread_id, want_count + 1 }) catch return false;
    if (fileExists(io, extra)) return false;

    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Return cached slide bytes for the current (thread, idx) pair. If
/// the active slide changed since last call, drop the old buffer and
/// load the new file. The pointer stays stable across frames while
/// the user is on the same slide, so dvui's texture cache hits and
/// no re-decode/upload happens per frame.
///
/// Returns null if the file is missing on disk (screenshot not yet
/// synced) — callers should render a placeholder.
///
/// Cache lifetime is tied to the slide selection. `freeSlideCache`
/// must be called when the detail page closes or the user navigates
/// to a different game so we don't leak the buffer.
pub fn slideBytes(frame: *Frame, thread_id: u64, idx: usize) ?[]const u8 {
    const state = frame.state;
    const same = state.slide_cache_thread == thread_id and state.slide_cache_idx == idx;
    if (same) {
        return state.slide_cache_bytes;
    }
    // Different slide — drop old buffer.
    if (state.slide_cache_bytes) |old| frame.lib.alloc.free(old);
    state.slide_cache_bytes = null;
    state.slide_cache_thread = thread_id;
    state.slide_cache_idx = idx;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ frame.info.covers_dir, thread_id, idx }) catch return null;
    state.slide_cache_bytes = std.Io.Dir.cwd().readFileAlloc(
        frame.io,
        path,
        frame.lib.alloc,
        .limited(16 * 1024 * 1024),
    ) catch null;
    return state.slide_cache_bytes;
}

/// Drop the slide cache. Call on detail-page exit, on Sync (the bytes
/// just got rewritten), and when navigating to a different game.
pub fn freeSlideCache(state: *State, alloc: std.mem.Allocator) void {
    if (state.slide_cache_bytes) |b| {
        alloc.free(b);
        state.slide_cache_bytes = null;
    }
    state.slide_cache_thread = null;
    state.slide_cache_idx = 0;
}

/// Return cached bytes for the thumbnail-strip slot at `idx` for the
/// given thread. Slide 0 is the cover; 1..N are screenshots. Bytes
/// are loaded lazily on first call per slot and stay cached for the
/// lifetime of the user's stay on this game's detail page. Returns
/// null when the file is missing on disk.
pub fn thumbBytes(frame: *Frame, thread_id: u64, idx: usize) ?[]const u8 {
    const state = frame.state;

    if (state.thumb_cache_thread != thread_id) {
        // Different game — drop the entire strip and reset.
        for (&state.thumb_cache_bytes) |*slot| {
            if (slot.*) |b| frame.lib.alloc.free(b);
            slot.* = null;
        }
        state.thumb_cache_thread = thread_id;
    }

    if (idx >= state.thumb_cache_bytes.len) return null;

    if (state.thumb_cache_bytes[idx] == null) {
        // All image work happens at sync time — `.t` files are
        // written alongside the full-size cover/screenshots by
        // `writeThumbBeside`. If the thumb is missing here, the
        // game was synced before the thumb pipeline existed; the
        // renderer shows a placeholder. Re-sync (or a future
        // "Fix images" button) regenerates everything.
        var thumb_buf: [256]u8 = undefined;
        const thumb_path = if (idx == 0)
            (std.fmt.bufPrint(&thumb_buf, "{s}/{d}.t", .{ frame.info.covers_dir, thread_id }) catch return null)
        else
            (std.fmt.bufPrint(&thumb_buf, "{s}/{d}.s{d}.t", .{ frame.info.covers_dir, thread_id, idx }) catch return null);
        state.thumb_cache_bytes[idx] = std.Io.Dir.cwd().readFileAlloc(
            frame.io,
            thumb_path,
            frame.lib.alloc,
            .limited(2 * 1024 * 1024),
        ) catch null;
    }
    return state.thumb_cache_bytes[idx];
}

/// Drop the thumb-strip cache. Call on detail-page exit, when
/// switching games (`thumbBytes` does this automatically), and on
/// Sync (the on-disk bytes just got rewritten).
pub fn freeThumbCache(state: *State, alloc: std.mem.Allocator) void {
    for (&state.thumb_cache_bytes) |*slot| {
        if (slot.*) |b| {
            alloc.free(b);
            slot.* = null;
        }
    }
    state.thumb_cache_thread = null;
}

/// Called once per frame. If a worker has finished, applies its result
/// to the matching game row, persists, frees the job, clears
/// `state.pending_sync`. No-op while the worker is still pending.
pub fn drainSync(frame: *Frame) void {
    const state = frame.state;
    const opaque_job = state.pending_sync orelse return;
    const job: *SyncJob = @ptrCast(@alignCast(opaque_job));

    const phase: SyncJobPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;

    // We *cannot* use `defer` for the cleanup here, because the
    // batch-chain calls (`advanceSyncQueue` → `syncGame`) need to see
    // `state.pending_sync = null` so they actually spawn the next job
    // instead of queueing it behind the just-finished one. The defer
    // would fire AFTER advance, so syncGame would observe the still-
    // set pending_sync and silently append to the queue, leaving the
    // batch stalled with no active worker. Worse: the defer would
    // then clear pending_sync, nuking the newly-spawned next job's
    // pointer. So: cleanup() is explicit, run before any chain call.
    const cleanup = struct {
        fn run(j: *SyncJob, s: *State) void {
            j.alloc.free(j.url);
            j.alloc.free(j.covers_dir);
            if (j.name) |n| j.alloc.free(n);
            if (j.version) |v| j.alloc.free(v);
            if (j.developer) |d| j.alloc.free(d);
            if (j.tags) |ts| {
                for (ts) |t| j.alloc.free(t);
                j.alloc.free(ts);
            }
            if (j.screenshots) |ss| {
                for (ss) |x| j.alloc.free(x);
                j.alloc.free(ss);
            }
            if (j.description_md) |d| j.alloc.free(d);
            if (j.changelog_md) |c| j.alloc.free(c);
            if (j.reviews_md) |r| j.alloc.free(r);
            if (j.downloads_md) |d| j.alloc.free(d);
            if (j.thread_info_md) |t| j.alloc.free(t);
            if (j.download_links) |dl| {
                for (dl) |d| j.alloc.free(d);
                j.alloc.free(dl);
            }
            j.alloc.destroy(j);
            s.pending_sync = null;
            s.active_sync_name_len = 0;
        }
    }.run;

    // Cover was just rewritten on disk — drop the cached entry so the
    // next frame re-reads it.
    if (job.cover_updated) {
        invalidateCover(state, frame.lib.alloc, job.thread_id);
    }

    // The sync worker also rewrote the full-size cover + every
    // screenshot AND their `.t` thumbs. The detail-page caches keyed
    // on `thread_id` still hold the old (or null) bytes — drop them
    // so the next paint reloads from the freshly-written files.
    // Without this, slide 0 stays at "(no cover)" until the user
    // navigates away and back.
    if (state.slide_cache_thread == job.thread_id) {
        freeSlideCache(state, frame.lib.alloc);
    }
    if (state.thumb_cache_thread == job.thread_id) {
        freeThumbCache(state, frame.lib.alloc);
    }

    if (phase == .failed) {
        // User cancellation is not an error path — silently clean up
        // and DO NOT chain into the rest of the queue (cancelSync
        // already freed it). Real failures still surface a banner.
        const was_cancelled = job.err_name != null and std.mem.eql(u8, job.err_name.?, "Cancelled");
        if (was_cancelled) {
            state.sync_status = .idle;
            state.sync_msg_len = 0;
            cleanup(job, state);
            return;
        }
        state.sync_status = .err;
        const friendly = friendlyError(job.err_name orelse "?");
        var emsg: [128]u8 = undefined;
        const m = if (state.sync_queue) |_|
            std.fmt.bufPrint(&emsg, "sync-all: {d}/{d} — failed: {s}", .{ state.sync_queue_started, state.sync_queue_total, friendly }) catch "sync-all error"
        else
            std.fmt.bufPrint(&emsg, "scrape failed: {s}", .{friendly}) catch "scrape failed";
        state.setSyncMsg(m);
        cleanup(job, state);
        // Don't abort the batch on a single failure — keep going.
        if (state.sync_queue != null) advanceSyncQueue(frame);
        return;
    }

    // .done — find the row by thread_id and apply numeric fields.
    var target: ?*library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == job.thread_id) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        state.sync_status = .err;
        state.setSyncMsg("synced game no longer in list");
        cleanup(job, state);
        // Don't stall a sync-all batch on a single missing row.
        if (state.sync_queue != null) advanceSyncQueue(frame);
        return;
    };

    const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();

    // Orphaned outcome: F95 returned 404 for this thread. Don't
    // clobber the row's good data with the empty scrape — only flip
    // dev_status + bump last_scraped_at so the badge updates and the
    // user can see the row was checked.
    if (job.orphaned) {
        frame.lib.applyScrape(game, .{
            .dev_status = .orphaned,
            .last_scraped_at = now_s,
        }) catch |e| {
            state.sync_status = .err;
            var emsg: [80]u8 = undefined;
            const m = std.fmt.bufPrint(&emsg, "DB write failed: {s}", .{@errorName(e)}) catch "DB write failed";
            state.setSyncMsg(m);
            cleanup(job, state);
            if (state.sync_queue != null) advanceSyncQueue(frame);
            return;
        };
        state.sync_status = .ok;
        state.sort_applied_column = null;
        state.sort_applied_dir = null;
        var orph_buf: [128]u8 = undefined;
        const m = if (state.sync_queue) |_|
            std.fmt.bufPrint(&orph_buf, "sync-all: {d}/{d} — orphaned (thread gone from F95)", .{ state.sync_queue_started, state.sync_queue_total }) catch "orphaned"
        else
            std.fmt.bufPrint(&orph_buf, "orphaned — F95 returned 404 for thread {d}", .{job.thread_id}) catch "orphaned";
        state.setSyncMsg(m);
        cleanup(job, state);
        if (state.sync_queue != null) advanceSyncQueue(frame);
        return;
    }

    // Capture the *old* version before applyScrape rewrites it, so
    // the end-of-batch recap can show "Foo 0.5 → 0.6" diffs. Only
    // games that already had a version recorded count as "updates";
    // first-time syncs of an unsynced row don't qualify.
    const old_version_snapshot: ?[]u8 = if (game.latest_version) |v|
        frame.lib.alloc.dupe(u8, v) catch null
    else
        null;
    defer if (old_version_snapshot) |s| frame.lib.alloc.free(s);

    frame.lib.applyScrape(game, .{
        .name = job.name,
        .version = job.version,
        .developer = job.developer,
        .rating = job.rating,
        .vote_count = job.vote_count,
        .engine = job.engine,
        .dev_status = job.dev_status,
        .last_updated_at = job.last_updated_at,
        .thread_info_md = job.thread_info_md,
        .censored = job.censored,
        .tags = job.tags,
        .screenshots = job.screenshots,
        .description_md = job.description_md,
        .changelog_md = job.changelog_md,
        .reviews_md = job.reviews_md,
        .download_links = job.download_links,
        .downloads_md = job.downloads_md,
        .last_scraped_at = now_s,
    }) catch |e| {
        state.sync_status = .err;
        var emsg: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "DB write failed: {s}", .{@errorName(e)}) catch "DB write failed";
        state.setSyncMsg(m);
        cleanup(job, state);
        // Continue the batch even when one DB write fails.
        if (state.sync_queue != null) advanceSyncQueue(frame);
        return;
    };

    // After a successful scrape we have everything needed to author
    // the canonical game recipe (name + version + engine + thread).
    // Auto-save it idempotently so the Recipe tab — which we're
    // about to retire — never becomes a precondition for anything
    // else (mods, downloads, sharing).
    ensureGameRecipeOnDisk(frame, game) catch |e| {
        log.warn("auto-save game recipe for {d} failed: {s}", .{ game.f95_thread_id, @errorName(e) });
    };

    // Recap accumulation. Only fires when we're inside a batch (the
    // popup at the end is the whole point) AND the version actually
    // moved AND there *was* a prior version to move from. A solo
    // per-game sync still updates the row but doesn't generate a
    // recap entry; that's by design — the popup is for the long-
    // running "what should I redownload?" flows.
    if (state.sync_queue != null) {
        if (old_version_snapshot) |old_v| {
            if (game.latest_version) |new_v| {
                if (!std.mem.eql(u8, old_v, new_v)) {
                    pushSyncRecap(frame, game.f95_thread_id, game.name, old_v, new_v);
                    // Auto-update hook: only inside batch sync, only
                    // when this game opted in (or inherits an opted-in
                    // global default), and only when the recipe is
                    // ready (has an auto-fetchable source AND its
                    // version matches the new F95 version — a stale
                    // recipe would just re-fetch the old build).
                    // Skipped silently when manual-only or a
                    // download/install is already in flight.
                    if (shouldAutoUpdate(state, game) and
                        !hasActiveDownloadForGame(frame, game.f95_thread_id) and
                        !isInstallingForGame(frame, game.f95_thread_id) and
                        recipeReadyForAutoUpdate(frame, game.f95_thread_id, new_v))
                    {
                        log.info("auto-update: tid={d} '{s}' {s} -> {s}", .{ game.f95_thread_id, game.name, old_v, new_v });
                        doDownloadGame(frame, game);
                        markRecapAutoDownloaded(state, game.f95_thread_id);
                    } else if (shouldAutoUpdate(state, game) and
                        !hasAutoFetchableSource(frame, game.f95_thread_id))
                    {
                        log.info("auto-update: tid={d} skipped — no auto-fetchable recipe source", .{game.f95_thread_id});
                    } else if (shouldAutoUpdate(state, game) and
                        hasAutoFetchableSource(frame, game.f95_thread_id))
                    {
                        log.info("auto-update: tid={d} skipped — recipe version doesn't match new F95 version {s} (recipe lags)", .{ game.f95_thread_id, new_v });
                    }
                }
            }
        }
    }

    state.sync_status = .ok;
    // Game's rating/vote_count just changed — invalidate sort so a
    // rating-/votes-sorted view re-orders next frame.
    state.sort_applied_column = null;
    state.sort_applied_dir = null;

    var msgbuf: [96]u8 = undefined;
    const m = if (state.sync_queue) |_|
        std.fmt.bufPrint(&msgbuf, "sync-all: {d}/{d} — last \xE2\x98\x85 {?d:.2}", .{ state.sync_queue_started, state.sync_queue_total, game.rating }) catch "sync-all"
    else
        std.fmt.bufPrint(&msgbuf, "synced: \xE2\x98\x85 {?d:.2} ({?d} votes)", .{ game.rating, game.vote_count }) catch "synced";
    state.setSyncMsg(m);

    // Phase 2: hand the just-scraped screenshot list to the background
    // image worker so the row is fully populated in the background.
    // game.screenshots is library-owned and stable; the enqueue copy
    // happens lazily on spawn (drainImageQueue dupes for the worker).
    // Idempotent — `enqueueImageFetch` no-ops on dupes.
    if (game.screenshots.len > 0) {
        enqueueImageFetch(frame, game.f95_thread_id, game.screenshots.len);
    }

    cleanup(job, state);
    // If a batch is in flight, kick off the next item.
    if (state.sync_queue != null) advanceSyncQueue(frame);
}

// ============================================================
//  sync-all queue
// ============================================================

/// Build a queue of every "(unsynced)" game's thread_id and kick off
/// the first sync. drainSync auto-pops the next when each completes.
pub fn startSyncAll(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_sync != null or state.sync_queue != null) return;
    log.info("startSyncAll: queueing all {d} games", .{frame.games.len});
    // Fresh batch starts with an empty recap — stale entries from a
    // previous run would mislead the end-of-batch popup.
    clearSyncRecap(frame);

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(frame.lib.alloc);

    // Queue every game in the library — synced rows get re-scraped so
    // rating / version / changelog / downloads stay current. The user
    // can still hit Cancel mid-batch via the per-game queue position.
    for (frame.games) |*g| {
        ids.append(frame.lib.alloc, g.f95_thread_id) catch return;
    }

    if (ids.items.len == 0) {
        state.sync_status = .ok;
        state.setSyncMsg("library is empty — add games first");
        return;
    }

    const owned = ids.toOwnedSlice(frame.lib.alloc) catch return;
    state.sync_queue = owned;
    state.sync_queue_idx = 0;
    state.sync_queue_started = 0;
    state.sync_queue_total = @intCast(owned.len);

    advanceSyncQueue(frame);
}

/// Queue a sync for every game still showing as `(unsynced)` (a row
/// added via paste-import or bookmarks pull that hasn't been
/// scraped yet). Skips already-synced rows so a big freshly-imported
/// batch can finish quickly without redoing the whole library.
pub fn startSyncAllUnsynced(frame: *Frame) void {
    const state = frame.state;
    // Unconditional entry log so a click that gets gated out is
    // visible in the log instead of silently doing nothing.
    log.info("startSyncAllUnsynced: invoked (games_len={d})", .{frame.games.len});

    if (state.pending_sync != null or state.sync_queue != null) {
        log.info("startSyncAllUnsynced: refused — a sync is already running", .{});
        state.pushToast(.info, "A sync is already running — cancel it first.");
        return;
    }
    clearSyncRecap(frame);

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(frame.lib.alloc);

    // "Never synced" is the authoritative signal — Game.last_scraped_at
    // is null until the first successful sync sets it. The earlier
    // predicate (`name == "(unsynced)"`) only matched the placeholder
    // name that paste-import / bookmarks pull writes initially; a row
    // whose first scrape failed could still have a real-looking name
    // from an OP fragment yet have never been completed.
    for (frame.games) |*g| {
        if (g.last_scraped_at != null) continue;
        ids.append(frame.lib.alloc, g.f95_thread_id) catch return;
    }

    if (ids.items.len == 0) {
        // The sync banner is hidden when no queue/job exists, so
        // setSyncMsg here would be invisible. Push a toast instead so
        // the click visibly does *something* — even when the answer
        // is "nothing matches your filter".
        log.info("startSyncAllUnsynced: no rows with last_scraped_at == null — nothing to queue", .{});
        state.pushToast(.info, "No unsynced games — every library row has been scraped at least once.");
        return;
    }

    log.info("startSyncAllUnsynced: queueing {d} unsynced game(s)", .{ids.items.len});

    const owned = ids.toOwnedSlice(frame.lib.alloc) catch return;
    state.sync_queue = owned;
    state.sync_queue_idx = 0;
    state.sync_queue_started = 0;
    state.sync_queue_total = @intCast(owned.len);

    advanceSyncQueue(frame);
}

/// Position of `thread_id` in the sync queue (1-indexed, where 1 is
/// "next up"). Returns null if it's not queued. Used to label the
/// detail-page sync button as "Queued (N/M)" so the user knows where
/// in line they are.
pub fn queuePosition(state: *State, thread_id: u64) ?struct { idx: usize, total: usize } {
    const q = state.sync_queue orelse return null;
    var i: usize = state.sync_queue_idx;
    while (i < q.len) : (i += 1) {
        if (q[i] == thread_id) {
            const remaining_total = q.len - state.sync_queue_idx;
            return .{ .idx = (i - state.sync_queue_idx) + 1, .total = remaining_total };
        }
    }
    return null;
}

/// Append a thread_id to the in-memory sync queue, growing the slice
/// by one. If no queue exists yet, allocates a fresh one. Callers
/// only invoke this while a sync is already running, so the existing
/// active job is counted as "item 1" of the resulting batch — total
/// = (running + items in queue). The pop offset (`sync_queue_idx`)
/// stays 0-based for `advanceSyncQueue`; the display counter
/// (`sync_queue_started`) tracks the 1-based current-item position.
fn appendToSyncQueue(alloc: std.mem.Allocator, state: *State, thread_id: u64) !void {
    if (state.sync_queue) |q| {
        const new_q = try alloc.realloc(q, q.len + 1);
        new_q[q.len] = thread_id;
        state.sync_queue = new_q;
        state.sync_queue_total += 1;
    } else {
        const q = try alloc.alloc(u64, 1);
        q[0] = thread_id;
        state.sync_queue = q;
        state.sync_queue_idx = 0;
        // Currently-running solo sync is item 1; this appended one
        // becomes item 2 once popped.
        state.sync_queue_started = 1;
        state.sync_queue_total = 2;
    }
}

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

pub const UpdateCheckJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    f95_svc: *f95.Service,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,
    /// Library thread-id set — built on the UI thread before spawn,
    /// read-only on the worker thread for membership tests.
    library_set: std.AutoHashMap(u64, void),
    /// Stop the walk once we hit an entry with `ts < since_ts`.
    since_ts: i64,
    /// Highest `ts` observed across all scanned entries. Becomes
    /// `state.last_update_check_ts` on success.
    newest_seen_ts: i64 = 0,
    /// Thread IDs that the F95 latest-updates pages reported as
    /// changed since `since_ts` AND that are in our library. The UI
    /// thread drains this into the sync queue.
    mismatch_tids: std.ArrayList(u64),
    /// Total entries seen across all walked pages — for the
    /// post-walk status message.
    scanned: u32 = 0,
    err_name: ?[]const u8 = null,
    /// Flipped to `true` by the UI thread to ask the walker to bail
    /// at the next page boundary. Used by the graceful-shutdown path.
    cancel: std.atomic.Value(bool) = .init(false),
};

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
    clearSyncRecap(frame);
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
    const opaque_job = state.pending_update_check orelse return;
    const job: *UpdateCheckJob = @ptrCast(@alignCast(opaque_job));
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
            state.sync_msg_len = 0;
            cleanup(job, state);
            return;
        }
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "update check failed: {s}", .{friendlyError(job.err_name orelse "?")}) catch "update check failed";
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

    if (state.pending_sync == null) advanceSyncQueue(frame);
}

/// Write `ts` as decimal text to `path`. Best-effort; logs and
/// returns on any error so a transient file-system hiccup doesn't
/// crash the UI thread.
fn persistInt64IfDirty(path: []const u8, io: std.Io, ts: i64) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{ts}) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("persist {s} failed: {s}", .{ path, @errorName(e) });
    };
}

/// Flip the cancel flag on every in-flight worker (sync,
/// bookmarks, update-check). Used by the graceful-shutdown path to
/// nudge detached workers toward their next phase boundary so the
/// HTTP client can be torn down cleanly. Idempotent.
pub fn cancelAllWorkers(state: *types.State) void {
    if (state.pending_sync) |opaque_job| {
        const j: *SyncJob = @ptrCast(@alignCast(opaque_job));
        j.cancel.store(true, .release);
    }
    // Phase-2 image worker: shared cancel flag covers both the active
    // job and any tids still queued.
    state.image_cancel.store(true, .release);
    if (state.pending_bookmarks) |opaque_job| {
        const j: *BookmarksJob = @ptrCast(@alignCast(opaque_job));
        j.cancel.store(true, .release);
    }
    if (state.pending_update_check) |opaque_job| {
        const j: *UpdateCheckJob = @ptrCast(@alignCast(opaque_job));
        j.cancel.store(true, .release);
    }
}

/// True when any async worker is still occupying its state slot
/// (`pending_sync` / `pending_bookmarks` / `pending_update_check`,
/// pending donor or RPDL handoff, or any in-flight post-install
/// extract). The graceful-shutdown loop spins on this until
/// everything clears.
pub fn workersBusy(state: *const types.State) bool {
    if (state.pending_sync != null) return true;
    if (state.image_active != null) return true;
    if (state.image_queue != null and state.image_queue_head < state.image_queue_len) return true;
    if (state.pending_bookmarks != null) return true;
    if (state.pending_update_check != null) return true;
    if (state.pending_rpdl_download != null) return true;
    if (state.pending_donor_download != null) return true;
    if (state.post_install_jobs) |opaque_ptr| {
        const list_ptr: *const PostInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        if (list_ptr.items.len > 0) return true;
    }
    if (manualInstallsRunning(state)) return true;
    return false;
}

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

const RpdlDownloadPhase = enum(u8) { pending, done, failed };

pub const RpdlDownloadJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,
    /// Inputs owned by the job.
    token: []u8,
    game_name: []u8,
    game_version: ?[]u8,
    thread_id: u64,
    /// Worker output. On success: torrent bytes + the picked
    /// torrent's metadata. UI thread hands the bytes to aria2 and
    /// frees both. On failure: err_name explains the stop.
    picked_id: u64 = 0,
    picked_title: ?[]u8 = null,
    torrent_bytes: ?[]u8 = null,
    err_name: ?[]const u8 = null,
};

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

    const job = alloc.create(RpdlDownloadJob) catch {
        log.err("startRpdlDownload: job alloc OOM", .{});
        alloc.free(name_dup);
        alloc.free(token_dup);
        if (version_dup) |v| alloc.free(v);
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(RpdlDownloadPhase.pending)),
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .token = token_dup,
        .game_name = name_dup,
        .game_version = version_dup,
        .thread_id = game.f95_thread_id,
    };

    job.thr = std.Thread.spawn(.{}, rpdlDownloadWorker, .{job}) catch |e| {
        log.err("startRpdlDownload: thread spawn failed: {s}", .{@errorName(e)});
        alloc.free(job.token);
        alloc.free(job.game_name);
        if (job.game_version) |v| alloc.free(v);
        alloc.destroy(job);
        return;
    };
    job.thr.detach();
    log.info("startRpdlDownload: worker thread spawned + detached", .{});

    state.pending_rpdl_download = job;
    log.info("startRpdlDownload: state.pending_rpdl_download set — awaiting drain", .{});
    var msg_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&msg_buf, "RPDL: searching for '{s}'…", .{game.name}) catch "RPDL: searching…";
    state.setDownloadMsg(m);
}

fn rpdlDownloadWorker(job: *RpdlDownloadJob) void {
    const fail = struct {
        fn run(j: *RpdlDownloadJob, err: []const u8) void {
            j.err_name = err;
            j.phase.store(@intFromEnum(RpdlDownloadPhase.failed), .release);
            dvui.refresh(j.win, @src(), null);
        }
    }.run;

    const t_search = std.Io.Clock.Timestamp.now(job.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} starting search for '{s}'", .{ job.thread_id, job.game_name });
    const results = downloads.rpdl.search(job.alloc, job.io, job.game_name) catch |e| {
        log.warn("rpdl search failed: {s}", .{@errorName(e)});
        fail(job, @errorName(e));
        return;
    };
    defer downloads.rpdl.freeSearchResults(job.alloc, results);
    const t_after_search = std.Io.Clock.Timestamp.now(job.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} search_ms={d} returned {d} result(s)", .{ job.thread_id, t_after_search - t_search, results.len });

    if (results.len == 0) {
        log.warn("rpdl worker: tid={d} no search results", .{job.thread_id});
        fail(job, "NoMatches");
        return;
    }

    const ver_opt: ?[]const u8 = if (job.game_version) |v| v else null;
    const picked = downloads.rpdl.pickBestMatch(results, job.game_name, ver_opt) orelse {
        log.warn("rpdl worker: tid={d} all candidates rejected (zero-seed or name mismatch)", .{job.thread_id});
        fail(job, "NoSeeders");
        return;
    };

    job.picked_id = picked.id;
    job.picked_title = job.alloc.dupe(u8, picked.title) catch {
        fail(job, "OutOfMemory");
        return;
    };

    log.info("rpdl worker: tid={d} fetching .torrent for picked id={d}", .{ job.thread_id, picked.id });
    const t_fetch = std.Io.Clock.Timestamp.now(job.io, .real).raw.toMilliseconds();
    const bytes = downloads.rpdl.fetchTorrent(job.alloc, job.io, job.token, picked.id) catch |e| {
        log.warn("rpdl fetchTorrent failed: {s}", .{@errorName(e)});
        fail(job, @errorName(e));
        return;
    };
    const t_done = std.Io.Clock.Timestamp.now(job.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} fetched {d} torrent bytes in {d}ms (total elapsed {d}ms)", .{
        job.thread_id, bytes.len, t_done - t_fetch, t_done - t_search,
    });
    job.torrent_bytes = bytes;
    job.phase.store(@intFromEnum(RpdlDownloadPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

/// Drain the RPDL search/fetch worker each frame. On done: hand the
/// .torrent bytes to the download Manager (which spawns aria2 if
/// needed). On failed: surface the error in `download_msg`.
pub fn drainRpdlDownload(frame: *Frame) void {
    const state = frame.state;
    const opaque_job = state.pending_rpdl_download orelse return;
    const job: *RpdlDownloadJob = @ptrCast(@alignCast(opaque_job));
    const phase: RpdlDownloadPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;
    log.info("drainRpdlDownload: observed phase={s} tid={d}", .{ @tagName(phase), job.thread_id });

    const cleanup = struct {
        fn run(j: *RpdlDownloadJob, s: *types.State) void {
            j.alloc.free(j.token);
            j.alloc.free(j.game_name);
            if (j.game_version) |v| j.alloc.free(v);
            if (j.picked_title) |t| j.alloc.free(t);
            if (j.torrent_bytes) |b| j.alloc.free(b);
            j.alloc.destroy(j);
            s.pending_rpdl_download = null;
        }
    }.run;

    if (phase == .failed) {
        var emsg: [160]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "RPDL: {s}", .{rpdlErrorMessage(job.err_name orelse "?")}) catch "RPDL failed";
        state.setDownloadMsg(m);
        cleanup(job, state);
        return;
    }

    const bytes = job.torrent_bytes orelse {
        state.setDownloadMsg("RPDL: internal error — no torrent bytes");
        cleanup(job, state);
        return;
    };

    // Hand off to the download manager. aria2 will pick up our
    // daemon-wide --seed-ratio / --enable-dht defaults.
    // Capture the RPDL-derived version from the torrent title so the
    // install row records the exact build the user downloaded.
    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "rpdl:{d}", .{job.picked_id}) catch "rpdl";
    const picked_version: ?[]const u8 = if (job.picked_title) |t|
        version_mod.extractFromTitle(t)
    else
        null;
    if (picked_version) |v| {
        log.info("rpdl: tid={d} captured version='{s}' from torrent title", .{ job.thread_id, v });
    } else {
        log.warn("rpdl: tid={d} no version segment in torrent title", .{job.thread_id});
    }
    const dl_id = frame.dl_mgr.enqueueTorrent(label, bytes, .game, job.thread_id, null, null, picked_version) catch |e| {
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "RPDL: enqueue failed: {s}", .{@errorName(e)}) catch "RPDL: enqueue failed";
        state.setDownloadMsg(m);
        cleanup(job, state);
        return;
    };

    var ok_buf: [192]u8 = undefined;
    const title = job.picked_title orelse "(unknown title)";
    const m = std.fmt.bufPrint(
        &ok_buf,
        "RPDL: queued '{s}' (torrent #{d}) as download {d} — seeding to 2.0 ratio when done",
        .{ title, job.picked_id, dl_id },
    ) catch "RPDL: queued";
    state.setDownloadMsg(m);

    cleanup(job, state);
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

pub const DonorDownloadJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,
    f95_client: *f95.Client,
    game_name: []u8, // owned
    /// Snapshot of the F95-scraped version at click time. Owned.
    /// Donor URLs don't carry a version inline, so this is the best
    /// signal we have for what build the user is about to install.
    game_version: ?[]u8 = null,
    thread_id: u64,
    /// Worker output on success — the signed URL + the per-URL
    /// cookie F95 hands back from /sam/dddl.php step 2. UI thread
    /// frees both after enqueue.
    signed_url: ?[]u8 = null,
    signed_cookie: ?[]u8 = null,
    /// Best-effort filename hint from F95's file-list response —
    /// purely informational (aria2 derives the real on-disk name from
    /// the URL / Content-Disposition).
    signed_filename: ?[]u8 = null,
    err_name: ?[]const u8 = null,
};

const DonorJobsMap = std.AutoHashMap(u64, u64); // download_job_id → thread_id
const DonorRetriesMap = std.AutoHashMap(u64, u8); // thread_id → retries used

fn donorJobsMap(frame: *Frame) *DonorJobsMap {
    if (frame.state.donor_jobs) |p| return @ptrCast(@alignCast(p));
    const m = frame.lib.alloc.create(DonorJobsMap) catch unreachable;
    m.* = DonorJobsMap.init(frame.lib.alloc);
    frame.state.donor_jobs = m;
    return m;
}

fn donorRetriesMap(frame: *Frame) *DonorRetriesMap {
    if (frame.state.donor_retries) |p| return @ptrCast(@alignCast(p));
    const m = frame.lib.alloc.create(DonorRetriesMap) catch unreachable;
    m.* = DonorRetriesMap.init(frame.lib.alloc);
    frame.state.donor_retries = m;
    return m;
}

pub fn freeDonorTables(state: *State, alloc: std.mem.Allocator) void {
    if (state.donor_jobs) |p| {
        const m: *DonorJobsMap = @ptrCast(@alignCast(p));
        m.deinit();
        alloc.destroy(m);
        state.donor_jobs = null;
    }
    if (state.donor_retries) |p| {
        const m: *DonorRetriesMap = @ptrCast(@alignCast(p));
        m.deinit();
        alloc.destroy(m);
        state.donor_retries = null;
    }
    if (state.donor_tick_log) |p| {
        const m: *DonorTickLog = @ptrCast(@alignCast(p));
        // Free the duped `last_error_msg` slices each entry owns.
        var it = m.valueIterator();
        while (it.next()) |entry| if (entry.last_error_msg) |s| alloc.free(s);
        m.deinit();
        alloc.destroy(m);
        state.donor_tick_log = null;
    }
}

const DonorTickState = struct {
    /// Wall-clock ms of the last verbose log line for this job.
    /// Throttles the per-tick log to ~once per 3 s to keep the
    /// terminal readable.
    last_log_ms: i64 = 0,
    /// Bytes completed at last log — paired with `last_log_ms` to
    /// derive a rolling "speed since previous log line" value that
    /// matches what aria2 reports.
    last_bytes: u64 = 0,
    /// Wall-clock ms when the download first started reporting
    /// 0 B/s. Null while progress is flowing. Logged at the moment
    /// the stall begins AND when it recovers.
    stalled_since_ms: ?i64 = null,
    /// Last-seen aria2 errorMessage. Owned by the alloc; freed on
    /// replace and on `freeDonorTables`. Logged whenever it changes.
    last_error_msg: ?[]u8 = null,
};

const DonorTickLog = std.AutoHashMap(u64, DonorTickState);

fn donorTickLogPtr(frame: *Frame) *DonorTickLog {
    if (frame.state.donor_tick_log) |p| return @ptrCast(@alignCast(p));
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
    const opaque_job = state.pending_donor_download orelse return;
    const job: *DonorDownloadJob = @ptrCast(@alignCast(opaque_job));
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
//  Master tag list refresh
// ============================================================
//
// One-shot worker that re-fetches F95's `/tags/` index, sorts +
// dedupes, swaps `state.tags_master`, and persists to
// `<data_root>/tags.txt`. Tags change rarely so the user clicks
// "Refresh" in Settings → Library every now and then.

const RefreshTagsPhase = enum(u8) { pending, done, failed };

pub const RefreshTagsJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,
    f95_svc: *f95.Service,
    /// Worker output. Owns the slice + inner strings on success;
    /// drain transfers ownership into `state.tags_master`.
    tags_out: []const []const u8 = &.{},
    fetched_at: i64 = 0,
    err_name: ?[]const u8 = null,
};

pub fn startRefreshTags(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_tags_refresh != null) return;

    const alloc = frame.lib.alloc;
    const job = alloc.create(RefreshTagsJob) catch return;
    job.* = .{
        .phase = .init(@intFromEnum(RefreshTagsPhase.pending)),
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .f95_svc = frame.f95_svc,
    };
    job.thr = std.Thread.spawn(.{}, refreshTagsWorker, .{job}) catch {
        alloc.destroy(job);
        return;
    };
    job.thr.detach();
    state.pending_tags_refresh = job;
}

fn refreshTagsWorker(job: *RefreshTagsJob) void {
    const tags = f95.tags.fetchAllTags(job.alloc, job.f95_svc.client) catch |e| {
        log.warn("refresh tags failed: {s}", .{@errorName(e)});
        job.err_name = @errorName(e);
        job.phase.store(@intFromEnum(RefreshTagsPhase.failed), .release);
        dvui.refresh(job.win, @src(), null);
        return;
    };
    job.tags_out = tags;
    job.fetched_at = std.Io.Clock.Timestamp.now(job.io, .real).raw.toSeconds();
    job.phase.store(@intFromEnum(RefreshTagsPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

pub fn drainRefreshTags(frame: *Frame) void {
    const state = frame.state;
    const opaque_job = state.pending_tags_refresh orelse return;
    const job: *RefreshTagsJob = @ptrCast(@alignCast(opaque_job));
    const phase: RefreshTagsPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;

    const cleanup = struct {
        fn run(j: *RefreshTagsJob, s: *types.State) void {
            j.alloc.destroy(j);
            s.pending_tags_refresh = null;
        }
    }.run;

    if (phase == .failed) {
        var emsg: [160]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "tag refresh failed: {s}", .{friendlyError(job.err_name orelse "?")}) catch "tag refresh failed";
        state.setSyncMsg(m);
        cleanup(job, state);
        return;
    }

    // Swap in the new list. Free the old master list first.
    freeTagsMaster(frame.lib.alloc, state);
    state.tags_master = job.tags_out;
    state.tags_master_fetched_at = job.fetched_at;

    // Persist. Best-effort — log on failure, don't crash the UI.
    f95.tags.saveToDisk(frame.lib.alloc, frame.io, frame.info.tags_master_path, job.tags_out, job.fetched_at) catch |e| {
        log.warn("tags.txt save failed: {s}", .{@errorName(e)});
    };

    var ok_buf: [96]u8 = undefined;
    const m = std.fmt.bufPrint(&ok_buf, "refreshed {d} tags", .{job.tags_out.len}) catch "refreshed tags";
    state.sync_status = .ok;
    state.setSyncMsg(m);

    cleanup(job, state);
}

/// Release the master tag list back to `alloc`. Used by the refresh
/// drain before swap-in, and by `runMainLoop`'s shutdown defer.
pub fn freeTagsMaster(alloc: std.mem.Allocator, state: *types.State) void {
    for (state.tags_master) |t| alloc.free(t);
    if (state.tags_master.len > 0) alloc.free(state.tags_master);
    state.tags_master = &.{};
}

/// Cancel the running sync (if any) and drop the rest of the batch
/// queue. Worker observes `job.cancel` between phases and exits as
/// `Cancelled`. UI thread frees the queue immediately; drainSync's
/// cleanup will run when the worker reports back.
pub fn cancelSync(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_sync) |opaque_job| {
        const j: *SyncJob = @ptrCast(@alignCast(opaque_job));
        j.cancel.store(true, .release);
        log.info("cancelSync: flag set on tid={d}", .{j.thread_id});
    }
    if (state.sync_queue) |q| {
        frame.lib.alloc.free(q);
        state.sync_queue = null;
        state.sync_queue_idx = 0;
        state.sync_queue_started = 0;
        state.sync_queue_total = 0;
    }
    // Phase-2 piggybacks: cancelling a sync drops queued image work
    // too. `drainImageQueue` reaps the active job, clears the queue,
    // and resets `image_cancel` to false once everything's torn down.
    state.image_cancel.store(true, .release);
}

/// Cancel ONLY the phase-2 image fetch queue. Leaves any in-flight
/// sync alone — used by the dedicated "Cancel images" banner button
/// that shows after phase-1 has wrapped up.
pub fn cancelImageQueue(frame: *Frame) void {
    frame.state.image_cancel.store(true, .release);
    log.info("cancelImageQueue: flag set", .{});
}

/// Pop the next thread_id off the queue and spawn its SyncJob. Frees
/// the queue when exhausted.
pub fn advanceSyncQueue(frame: *Frame) void {
    const state = frame.state;
    const queue = state.sync_queue orelse return;
    if (state.sync_queue_idx >= queue.len) {
        frame.lib.alloc.free(queue);
        state.sync_queue = null;
        state.sync_queue_idx = 0;
        var msg_buf: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&msg_buf, "sync-all complete ({d} games)", .{state.sync_queue_total}) catch "sync-all complete";
        state.sync_status = .ok;
        state.setSyncMsg(m);
        state.sync_queue_total = 0;
        state.sync_queue_started = 0;
        // Surface the end-of-batch popup if any games actually
        // changed versions. Empty recap stays hidden — no point
        // showing an empty list.
        if (syncRecapEntries(state).len > 0) {
            state.sync_recap_show = true;
        }
        return;
    }
    const tid = queue[state.sync_queue_idx];
    state.sync_queue_idx += 1;
    state.sync_queue_started += 1;

    var target: ?*library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == tid) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        // Game disappeared from the slice — skip and try the next.
        advanceSyncQueue(frame);
        return;
    };
    syncGame(frame, game);
}

// ============================================================
//  phase-2: background screenshot fetch
// ============================================================
//
// Why this exists: phase-1 (`syncWorker`) used to fetch the cover AND
// every screenshot serially before marking the row .done. Each image
// is rate-limited at ≥1.5s through `f95.Client`, so a popular OP with
// 20 screenshots blocked the row from showing for ~30s, and a sync-
// all of 1500 games was effectively unusable.
//
// Phase-2 splits the work: as soon as phase-1 commits text+cover
// (`applyScrape`), `drainSync` enqueues the tid here. A single
// background worker walks the FIFO, refetching only the screenshots
// the OP advertises. The library is fully usable in the meantime —
// the detail page already lazy-loads screenshots from disk and
// renders placeholders for missing slides.
//
// Concurrency: ONE image job in flight at a time. The rate limiter
// serializes per-host requests anyway, so parallel workers would just
// queue behind each other. Single-worker means simpler state.

const ImageJobPhase = enum(u8) { pending, done };

pub const ImageJob = struct {
    phase: std.atomic.Value(u8),
    thread_id: u64,
    /// Screenshot URLs to fetch in order, mapped to `.s1` .. `.sN`.
    /// Outer slice + each inner string job.alloc-owned.
    urls: []const []const u8,
    /// Display name (for the banner row). job.alloc-owned; may be "".
    name: []const u8,
    /// Per-job counter for the "X/Y" sub-progress. Worker increments;
    /// drainImageQueue tears down when phase == done.
    progress_done: std.atomic.Value(u32) = .init(0),
    progress_total: u32 = 0,
    thr: std.Thread,
    alloc: std.mem.Allocator,
    f95_svc: *f95.Service,
    win: *dvui.Window,
    covers_dir: []u8,
    io: std.Io,
    /// Points into `state.image_cancel` so a single Cancel click
    /// aborts the active job AND prevents further pops from the queue.
    cancel: *std.atomic.Value(bool),
    /// Points into `state.image_done` — worker bumps after each
    /// fetched (or skipped-because-already-on-disk) screenshot, so
    /// the banner shows aggregate progress across the whole batch
    /// instead of just the current job.
    aggregate_done: *std.atomic.Value(u32),
};

fn imageWorker(job: *ImageJob) void {
    const t_start = nowMs(job.io);
    var ok: u32 = 0;
    var fail: u32 = 0;
    var skipped: u32 = 0;
    defer log.info(
        "imgworker tid={d} TOTAL_ms={d} ok={d} fail={d} skipped={d}",
        .{ job.thread_id, nowMs(job.io) - t_start, ok, fail, skipped },
    );

    for (job.urls, 0..) |url, idx| {
        if (job.cancel.load(.acquire)) {
            log.info("imgworker tid={d} cancelled at shot {d}", .{ job.thread_id, idx + 1 });
            break;
        }

        // Skip when the file is already on disk — re-running sync over
        // a partially-fetched tid should not re-download what we have.
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ job.covers_dir, job.thread_id, idx + 1 }) catch {
            fail += 1;
            _ = job.aggregate_done.fetchAdd(1, .release);
            _ = job.progress_done.fetchAdd(1, .release);
            dvui.refresh(job.win, @src(), null);
            continue;
        };
        if (fileExists(job.io, path)) {
            skipped += 1;
            _ = job.aggregate_done.fetchAdd(1, .release);
            _ = job.progress_done.fetchAdd(1, .release);
            dvui.refresh(job.win, @src(), null);
            continue;
        }

        const t_s0 = nowMs(job.io);
        // Reuse phase-1's helper. It writes `<covers>/<tid>.s<idx>`
        // atomically + a thumb beside it; identical layout to before
        // the phase split, so detail-page slide loads keep working.
        fetchAndWriteScreenshotForImage(job, url, idx + 1) catch |e| {
            std.log.scoped(.ui_actions).warn(
                "phase2 screenshot {d} fetch failed: {s}",
                .{ idx + 1, @errorName(e) },
            );
            fail += 1;
            _ = job.aggregate_done.fetchAdd(1, .release);
            _ = job.progress_done.fetchAdd(1, .release);
            dvui.refresh(job.win, @src(), null);
            continue;
        };
        log.info("imgworker tid={d} shot[{d}]_ms={d}", .{ job.thread_id, idx + 1, nowMs(job.io) - t_s0 });
        ok += 1;
        _ = job.aggregate_done.fetchAdd(1, .release);
        _ = job.progress_done.fetchAdd(1, .release);
        dvui.refresh(job.win, @src(), null);
    }

    job.phase.store(@intFromEnum(ImageJobPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

/// Thin wrapper to call `fetchAndWriteScreenshot` from an `ImageJob`
/// (which doesn't carry a `SyncJob`). Same byte format on disk so
/// slide-cache reads work unchanged.
fn fetchAndWriteScreenshotForImage(job: *ImageJob, url: []const u8, idx: usize) !void {
    const raw = try job.f95_svc.client.getImage(url);
    defer job.alloc.free(raw);
    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("phase2 screenshot {d} transcode failed ({s}): {s}", .{ idx, @errorName(e), url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try screenshotPath(&path_buf, job.covers_dir, job.thread_id, idx);
    try writeAtomic(job.io, path, ready);

    writeThumbBeside(job.alloc, job.io, path, ready) catch |e| {
        std.log.scoped(.ui_actions).warn("phase2 screenshot thumb gen failed: {s}", .{@errorName(e)});
    };
}

/// Enqueue a tid for phase-2 screenshot fetch. UI-thread only; called
/// from `drainSync` after `applyScrape` succeeds. Idempotent: a tid
/// already pending is left alone (the worker reads URLs from the
/// current Library row anyway, so a duplicate enqueue would just
/// fetch the same thing twice). Grows the queue geometrically.
pub fn enqueueImageFetch(frame: *Frame, thread_id: u64, planned_urls: usize) void {
    const state = frame.state;
    if (planned_urls == 0) return;

    // Dedup: scan pending range. Cheap — sync-all batches are typically
    // a few hundred items max and most have ~5 screenshots.
    if (state.image_queue) |q| {
        var i: usize = state.image_queue_head;
        while (i < state.image_queue_len) : (i += 1) {
            if (q[i] == thread_id) return;
        }
    }

    // Grow when full. Start at 32 slots; double thereafter.
    if (state.image_queue == null or state.image_queue_len == state.image_queue_cap) {
        const new_cap: usize = if (state.image_queue_cap == 0) 32 else state.image_queue_cap * 2;
        const new_buf = frame.lib.alloc.alloc(u64, new_cap) catch {
            log.warn("enqueueImageFetch: queue alloc failed for tid={d}", .{thread_id});
            return;
        };
        if (state.image_queue) |old| {
            @memcpy(new_buf[0..state.image_queue_len], old[0..state.image_queue_len]);
            frame.lib.alloc.free(old);
        }
        state.image_queue = new_buf;
        state.image_queue_cap = new_cap;
    }
    state.image_queue.?[state.image_queue_len] = thread_id;
    state.image_queue_len += 1;
    state.image_total += @intCast(planned_urls);
    log.info("enqueueImageFetch tid={d} urls={d} queue_len={d} total={d}", .{ thread_id, planned_urls, state.image_queue_len - state.image_queue_head, state.image_total });
}

/// Per-frame: spawn the next image job when idle, and tear down a
/// completed one. Mirrors `drainSync`'s shape. Safe to call every
/// frame even when no work is pending.
pub fn drainImageQueue(frame: *Frame) void {
    const state = frame.state;

    // Reap a finished job first so we can chain into the next.
    if (state.image_active) |opaque_job| {
        const job: *ImageJob = @ptrCast(@alignCast(opaque_job));
        const phase: ImageJobPhase = @enumFromInt(job.phase.load(.acquire));
        if (phase == .done) {
            // Worker is exiting — detach so the OS reaps the thread.
            // (Already detached at spawn; nothing to join.)
            log.info("drainImageQueue: tid={d} job done", .{job.thread_id});

            // If the user is on the detail page for this tid, dump the
            // slide / thumb caches so the freshly-fetched bytes show
            // up on the next paint instead of the cached placeholders.
            if (state.slide_cache_thread == job.thread_id) {
                freeSlideCache(state, frame.lib.alloc);
            }
            if (state.thumb_cache_thread == job.thread_id) {
                freeThumbCache(state, frame.lib.alloc);
            }

            // Free job-owned memory. `name` may be the empty literal
            // fallback when dupe failed — skip the free in that case.
            for (job.urls) |u| job.alloc.free(u);
            job.alloc.free(job.urls);
            if (job.name.len > 0) job.alloc.free(job.name);
            job.alloc.free(job.covers_dir);
            job.alloc.destroy(job);
            state.image_active = null;
            state.image_active_name_len = 0;
        } else {
            // Still running — wait for next frame.
            return;
        }
    }

    // If the user cancelled, drop the rest of the queue NOW (after the
    // active job has been reaped) and reset counters/cancel flag.
    if (state.image_cancel.load(.acquire)) {
        if (state.image_queue) |q| {
            frame.lib.alloc.free(q);
            state.image_queue = null;
            state.image_queue_cap = 0;
        }
        state.image_queue_head = 0;
        state.image_queue_len = 0;
        state.image_total = 0;
        state.image_done.store(0, .release);
        state.image_cancel.store(false, .release);
        log.info("drainImageQueue: cancelled, queue cleared", .{});
        return;
    }

    // Pop next pending tid.
    if (state.image_queue == null) return;
    if (state.image_queue_head >= state.image_queue_len) {
        // Drained. Free buffer, reset counters so the banner row
        // disappears on the next frame.
        frame.lib.alloc.free(state.image_queue.?);
        state.image_queue = null;
        state.image_queue_head = 0;
        state.image_queue_len = 0;
        state.image_queue_cap = 0;
        state.image_total = 0;
        state.image_done.store(0, .release);
        log.info("drainImageQueue: batch complete", .{});
        return;
    }

    const tid = state.image_queue.?[state.image_queue_head];
    state.image_queue_head += 1;

    // Look up the game row to read its screenshot URL list.
    var target: ?*const library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == tid) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        log.info("drainImageQueue: tid={d} not in games list, skipping", .{tid});
        return;
    };

    const urls_src = game.screenshots;
    if (urls_src.len == 0) {
        // No screenshots advertised — nothing to fetch. Skip cleanly;
        // we already charged `image_total` for this tid at enqueue
        // time. (We over-charged; subtract back so the bar stays
        // honest. enqueueImageFetch returned early when urls==0, so
        // this only triggers if the DB lost shots between enqueue and
        // drain — exotic but worth handling.)
        log.info("drainImageQueue: tid={d} has 0 screenshots, skipping", .{tid});
        return;
    }

    // Spawn the worker. URLs + name + covers_dir all live on the job's
    // allocator (lib.alloc) so the heap stays single-source.
    const job = frame.lib.alloc.create(ImageJob) catch {
        log.warn("drainImageQueue: ImageJob alloc failed for tid={d}", .{tid});
        return;
    };
    var alloc_failed = false;
    const urls_dup = blk: {
        const outer = frame.lib.alloc.alloc([]const u8, urls_src.len) catch {
            alloc_failed = true;
            break :blk @as([]const []const u8, &.{});
        };
        var n: usize = 0;
        for (urls_src) |u| {
            const dup = frame.lib.alloc.dupe(u8, u) catch {
                alloc_failed = true;
                break;
            };
            outer[n] = dup;
            n += 1;
        }
        if (alloc_failed) {
            for (outer[0..n]) |u| frame.lib.alloc.free(u);
            frame.lib.alloc.free(outer);
            break :blk @as([]const []const u8, &.{});
        }
        break :blk @as([]const []const u8, outer);
    };
    if (alloc_failed) {
        frame.lib.alloc.destroy(job);
        log.warn("drainImageQueue: URL dup failed for tid={d}", .{tid});
        return;
    }
    const name_dup = frame.lib.alloc.dupe(u8, game.name) catch "";
    const covers_dup = frame.lib.alloc.dupe(u8, frame.info.covers_dir) catch {
        for (urls_dup) |u| frame.lib.alloc.free(u);
        frame.lib.alloc.free(@constCast(urls_dup));
        if (name_dup.len > 0) frame.lib.alloc.free(name_dup);
        frame.lib.alloc.destroy(job);
        log.warn("drainImageQueue: covers_dir dup failed for tid={d}", .{tid});
        return;
    };

    job.* = .{
        .phase = .init(@intFromEnum(ImageJobPhase.pending)),
        .thread_id = tid,
        .urls = urls_dup,
        .name = name_dup,
        .progress_done = .init(0),
        .progress_total = @intCast(urls_dup.len),
        .thr = undefined,
        .alloc = frame.lib.alloc,
        .f95_svc = frame.f95_svc,
        .win = frame.win,
        .covers_dir = covers_dup,
        .io = frame.io,
        .cancel = &state.image_cancel,
        .aggregate_done = &state.image_done,
    };

    state.image_active = job;
    state.setCurrentImageName(name_dup);

    job.thr = std.Thread.spawn(.{}, imageWorker, .{job}) catch {
        log.warn("drainImageQueue: thread spawn failed for tid={d}", .{tid});
        // Roll back the job allocation so we don't leak.
        for (urls_dup) |u| frame.lib.alloc.free(u);
        frame.lib.alloc.free(@constCast(urls_dup));
        if (name_dup.len > 0) frame.lib.alloc.free(name_dup);
        frame.lib.alloc.free(covers_dup);
        frame.lib.alloc.destroy(job);
        state.image_active = null;
        state.image_active_name_len = 0;
        return;
    };
    job.thr.detach();
    log.info("drainImageQueue: spawned tid={d} urls={d}", .{ tid, urls_dup.len });
}

// ============================================================
//  cover image — disk cache (LRU-ish FIFO with on-hit promotion)
// ============================================================

/// File path for a thread's cached cover bytes.
pub fn coverPath(buf: []u8, covers_dir: []const u8, thread_id: u64) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/{d}", .{ covers_dir, thread_id });
}

/// Look up cover THUMB bytes for `thread_id`, populating the cache on
/// miss. Returns null if the file isn't there yet (cover not synced).
///
/// Returns the THUMB (`<tid>.t`) — small, fast to decode. Library
/// screens (grid + list) use this to avoid 4 MB-per-cover RGBA blowups
/// from full-size decodes. Detail-page carousel slide 0 uses the
/// separate full-size path via `slideBytes` / direct read so it shows
/// the high-quality cover.
///
/// Cache eviction is FIFO with LRU-ish promotion: on hit, the entry is
/// swapped into the slot just before `cover_cache_next`.
pub fn coverBytes(frame: *Frame, thread_id: u64) ?[]const u8 {
    const state = frame.state;
    const cap = state.cover_cache.len;
    // Fast path: cache hit. Promote on hit.
    for (&state.cover_cache, 0..) |*slot_ptr, idx| {
        if (slot_ptr.*) |slot| {
            if (slot.thread_id == thread_id) {
                const recent = (state.cover_cache_next + cap - 1) % cap;
                if (idx != recent) {
                    const tmp = state.cover_cache[idx];
                    state.cover_cache[idx] = state.cover_cache[recent];
                    state.cover_cache[recent] = tmp;
                }
                return state.cover_cache[recent].?.bytes;
            }
        }
    }

    // Miss — read the thumb file straight from disk. No lazy
    // fallback: image work all happens at sync time. Pre-thumb
    // games render the placeholder until they're re-synced (or a
    // future "Fix images" button regenerates them).
    var thumb_buf: [256]u8 = undefined;
    const thumb_path = std.fmt.bufPrint(&thumb_buf, "{s}/{d}.t", .{ frame.info.covers_dir, thread_id }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        frame.io,
        thumb_path,
        frame.lib.alloc,
        .limited(2 * 1024 * 1024),
    ) catch return null;

    // Insert into the round-robin slot, evicting whatever's there.
    const idx = state.cover_cache_next;
    state.cover_cache_next = (idx + 1) % cap;
    if (state.cover_cache[idx]) |old| frame.lib.alloc.free(old.bytes);
    state.cover_cache[idx] = .{ .thread_id = thread_id, .bytes = bytes };
    return bytes;
}

/// Read full-size cover bytes for the detail-page carousel slide 0.
/// Bypasses the thumb-bound `cover_cache`. Caller does NOT free —
/// the bytes are managed via `slide_cache_bytes` (single-slot,
/// reused across frames while the user stays on slide 0).
pub fn coverFullBytes(frame: *Frame, thread_id: u64) ?[]const u8 {
    const state = frame.state;
    // Reuse the same single-slot slide cache. Slide 0 marker is
    // (thread_id, 0). Slides 1..N use (thread_id, n).
    const same = state.slide_cache_thread == thread_id and state.slide_cache_idx == 0;
    if (same) return state.slide_cache_bytes;
    if (state.slide_cache_bytes) |old| frame.lib.alloc.free(old);
    state.slide_cache_bytes = null;
    state.slide_cache_thread = thread_id;
    state.slide_cache_idx = 0;
    var buf: [256]u8 = undefined;
    const path = coverPath(&buf, frame.info.covers_dir, thread_id) catch return null;
    state.slide_cache_bytes = std.Io.Dir.cwd().readFileAlloc(
        frame.io,
        path,
        frame.lib.alloc,
        .limited(16 * 1024 * 1024),
    ) catch null;
    return state.slide_cache_bytes;
}

/// Drop the cache entry for `thread_id` (sync just rewrote the file).
pub fn invalidateCover(state: *State, alloc: std.mem.Allocator, thread_id: u64) void {
    for (&state.cover_cache) |*slot_ptr| {
        if (slot_ptr.*) |slot| {
            if (slot.thread_id == thread_id) {
                alloc.free(slot.bytes);
                slot_ptr.* = null;
                return;
            }
        }
    }
}

pub fn freeCoverCache(state: *State, alloc: std.mem.Allocator) void {
    for (&state.cover_cache) |*slot_ptr| {
        if (slot_ptr.*) |slot| {
            alloc.free(slot.bytes);
            slot_ptr.* = null;
        }
    }
}

// ============================================================
//  cover pre-warmer — populate OS page cache on a worker thread
// ============================================================
//
// Cold-cache: the very first frame of the library screen calls
// `coverBytes` for every visible card, each one doing a sync
// `readFileAlloc`. With 32 cards × few-ms-per-read that's a visible
// stall.
//
// We don't want to share the in-memory `state.cover_cache` across
// threads (would need a lock on every UI access), so this worker just
// touches the files: it reads + immediately frees the bytes. That's
// enough to populate the OS page cache, so the subsequent UI-thread
// reads through `coverBytes` hit memcpy-speed instead of disk.
//
// Caller-owned: nothing. The worker is detached and frees its own job.

const PrewarmJob = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    covers_dir: []u8,
    thread_ids: []u64,
};

/// Spawn a detached worker that reads the first `cap` cover files
/// referenced by `games` to warm the OS page cache. No-op if `games`
/// is empty.
pub fn spawnCoverPrewarm(
    alloc: std.mem.Allocator,
    io: std.Io,
    covers_dir: []const u8,
    games: []const library.Game,
    cap: usize,
) void {
    const n = @min(games.len, cap);
    if (n == 0) return;

    const job = alloc.create(PrewarmJob) catch return;
    const ids = alloc.alloc(u64, n) catch {
        alloc.destroy(job);
        return;
    };
    for (games[0..n], 0..) |g, i| ids[i] = g.f95_thread_id;

    const dir_owned = alloc.dupe(u8, covers_dir) catch {
        alloc.free(ids);
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .covers_dir = dir_owned, .thread_ids = ids };

    const thr = std.Thread.spawn(.{}, prewarmWorker, .{job}) catch {
        alloc.free(dir_owned);
        alloc.free(ids);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

fn prewarmWorker(job: *PrewarmJob) void {
    defer {
        job.alloc.free(job.covers_dir);
        job.alloc.free(job.thread_ids);
        job.alloc.destroy(job);
    }
    var buf: [256]u8 = undefined;
    for (job.thread_ids) |tid| {
        const path = coverPath(&buf, job.covers_dir, tid) catch continue;
        // Read + immediately free. The file content lives in the OS
        // page cache after this; the UI thread's later `readFileAlloc`
        // serves from there.
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            job.io,
            path,
            job.alloc,
            .limited(8 * 1024 * 1024),
        ) catch continue;
        job.alloc.free(bytes);
    }
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
        startUpdateCheck(frame);
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
    startUpdateCheck(frame);
}

fn persistTextFile(io: std.Io, path: []const u8, text: []const u8) !void {
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
fn friendlyError(name: []const u8) []const u8 {
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
//  bookmarks pull (worker thread + drain)
// ============================================================
//
// Walks `/watched/threads` paginated under the user's session cookie,
// extracts every thread id, then bulk-inserts via
// `Library.insertIfMissing`. New rows show up as `(unsynced)`; the
// existing post-import auto-sync then scrapes each one.
//
// Network walk runs on a worker so the UI keeps drawing during the
// (rate-limited) pagination — 100 bookmarks across 5 pages = ~7.5s.

pub const BookmarksJobPhase = enum(u8) { pending, done, failed };

pub const BookmarksJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    f95_svc: *f95.Service,
    win: *dvui.Window,
    /// Page progress — worker writes, UI thread reads each frame.
    progress_current: std.atomic.Value(u32) = .init(0),
    progress_total: std.atomic.Value(u32) = .init(0),
    /// UI sets this true to ask the worker to stop. Worker checks
    /// between pages, exits cleanly with `Cancelled`, frees its
    /// partial state.
    cancel: std.atomic.Value(bool) = .init(false),
    /// Bookmark entries (alloc-owned). Filled on `.done`. Carries the
    /// title in addition to the thread id, so drainBookmarks can seed
    /// the row with a real name (parsed via `parseTitleParts`) instead
    /// of "(unsynced)".
    entries: ?[]f95.BookmarkEntry = null,
    /// Static error name on `.failed`.
    err_name: ?[]const u8 = null,
    thr: std.Thread,

    // ---- live-insert staging ----
    //
    // The worker's `on_page` callback dupes each page's entries here
    // under `staged_mu`. The UI thread's `drainBookmarks` pulls the
    // new tail every frame, inserts into Library, and bumps
    // `staged_drained`. Both sides honor the mutex; no work happens
    // on the UI thread while the worker is mid-append (cheap; only
    // ~50 entries per page).
    staged: std.ArrayList(f95.BookmarkEntry) = .empty,
    staged_mu: std.Io.Mutex = .init,
    staged_drained: usize = 0,
    /// Running totals visible in the progress message during the pull.
    live_inserted: std.atomic.Value(u32) = .init(0),
    live_skipped: std.atomic.Value(u32) = .init(0),
    live_dropped: std.atomic.Value(u32) = .init(0),
};

/// `on_page` callback — runs on the worker. Wakes the dvui loop AND
/// dupes this page's entries onto the job's staging buffer so the UI
/// thread can insert them mid-pull.
fn bookmarksOnPage(ctx: ?*anyopaque, page_entries: []const f95.BookmarkEntry) void {
    const win_or_job = ctx orelse return;
    const job: *BookmarksJob = @ptrCast(@alignCast(win_or_job));

    if (page_entries.len > 0) {
        const io = job.f95_svc.client.io;
        job.staged_mu.lockUncancelable(io);
        defer job.staged_mu.unlock(io);
        for (page_entries) |e| {
            // Dupe inner strings — the source list may realloc between
            // pages, invalidating these pointers.
            const tid = job.alloc.dupe(u8, e.thread_id) catch continue;
            errdefer job.alloc.free(tid);
            const title = job.alloc.dupe(u8, e.title) catch {
                job.alloc.free(tid);
                continue;
            };
            errdefer job.alloc.free(title);
            const url = job.alloc.dupe(u8, e.url) catch {
                job.alloc.free(tid);
                job.alloc.free(title);
                continue;
            };
            job.staged.append(job.alloc, .{
                .thread_id = tid,
                .title = title,
                .url = url,
            }) catch {
                job.alloc.free(tid);
                job.alloc.free(title);
                job.alloc.free(url);
            };
        }
    }
    dvui.refresh(job.win, @src(), null);
}

/// Set the cancel flag on the in-flight bookmarks pull (if any).
/// The worker observes it between pages and exits with the
/// `Cancelled` error path, which frees any partial state cleanly.
pub fn cancelBookmarks(frame: *Frame) void {
    const opaque_job = frame.state.pending_bookmarks orelse return;
    const job: *BookmarksJob = @ptrCast(@alignCast(opaque_job));
    job.cancel.store(true, .release);
    log.info("cancelBookmarks: cancel flag set", .{});
}

pub fn startPullBookmarks(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_bookmarks != null) return;
    if (frame.f95_svc.client.cookie == null) {
        state.setBookmarksMsg("not logged in — log in first");
        return;
    }
    log.info("startPullBookmarks: walking watched threads", .{});

    const alloc = frame.lib.alloc;
    const job = alloc.create(BookmarksJob) catch {
        state.setBookmarksMsg("internal error: job alloc");
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(BookmarksJobPhase.pending)),
        .alloc = alloc,
        .f95_svc = frame.f95_svc,
        .win = frame.win,
        .thr = undefined,
    };

    job.thr = std.Thread.spawn(.{}, bookmarksWorker, .{job}) catch {
        alloc.destroy(job);
        state.setBookmarksMsg("internal error: thread spawn");
        return;
    };
    job.thr.detach();

    state.setBookmarksMsg("fetching watched threads…");
    state.pending_bookmarks = job;
}

fn bookmarksWorker(job: *BookmarksJob) void {
    const entries = job.f95_svc.fetchBookmarks(.{
        .current = &job.progress_current,
        .total = &job.progress_total,
        .on_page = bookmarksOnPage,
        // ctx is the job itself now — bookmarksOnPage needs access to
        // the staging buffer + window, both on `job`.
        .ctx = job,
        .cancel = &job.cancel,
    }) catch |e| {
        job.err_name = @errorName(e);
        job.phase.store(@intFromEnum(BookmarksJobPhase.failed), .release);
        dvui.refresh(job.win, @src(), null);
        return;
    };
    // Transfer ownership of the entries slice (and its inner strings)
    // onto the job. drainBookmarks frees via `f95.bookmarks.freeAll`
    // after the bulk insert.
    job.entries = entries;
    job.phase.store(@intFromEnum(BookmarksJobPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

/// Per-frame drain. On done: walk the ids and `insertIfMissing` each;
/// trigger a reload + auto-sync-all so the new rows populate without
/// another click. While pending, mirror the worker's progress atomics
/// into `State` so the progress bar widget can read plain ints.
pub fn drainBookmarks(frame: *Frame) void {
    const state = frame.state;
    const opaque_job = state.pending_bookmarks orelse return;
    const job: *BookmarksJob = @ptrCast(@alignCast(opaque_job));

    // Always mirror progress so the widget sees fresh numbers without
    // having to know about the BookmarksJob layout.
    state.bookmarks_progress_current = job.progress_current.load(.acquire);
    state.bookmarks_progress_total = job.progress_total.load(.acquire);

    // **Live drain**: the worker's `bookmarksOnPage` callback has been
    // staging this pull's entries since page 1. Insert any newly-
    // staged rows into the library every frame — the user sees the
    // grid populate as pages come in, not all at once on .done.
    drainStagedBookmarks(frame, job);

    const phase: BookmarksJobPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;

    defer {
        if (job.entries) |entries| f95.bookmarks.freeAll(job.alloc, entries);
        // Free anything still in the staged buffer (already-inserted
        // copies — we duped on stage; the worker's `entries` slice is
        // independent and gets freed via freeAll above).
        for (job.staged.items) |e| {
            job.alloc.free(e.thread_id);
            job.alloc.free(e.title);
            job.alloc.free(e.url);
        }
        job.staged.deinit(job.alloc);
        job.alloc.destroy(job);
        state.pending_bookmarks = null;
        state.bookmarks_progress_current = 0;
        state.bookmarks_progress_total = 0;
    }

    if (phase == .failed) {
        // User-initiated cancel is not an error — just silence the
        // banner. The cancel flag is set by `cancelBookmarks`; the
        // worker propagates it as a `Cancelled` error. Either signal
        // counts as "intended stop".
        const user_cancelled = job.cancel.load(.acquire) or
            (job.err_name != null and std.mem.eql(u8, job.err_name.?, "Cancelled"));
        if (user_cancelled) {
            state.bookmarks_msg_len = 0;
            return;
        }
        const friendly = friendlyError(job.err_name orelse "?");
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "pull failed: {s}", .{friendly}) catch "pull failed";
        state.setBookmarksMsg(m);
        return;
    }

    // Final summary: counters were maintained during live drain.
    const imported = job.live_inserted.load(.acquire);
    const skipped = job.live_skipped.load(.acquire);
    const dropped_nongame = job.live_dropped.load(.acquire);
    const total = imported + skipped + dropped_nongame;

    var msg_buf: [192]u8 = undefined;
    const m = if (dropped_nongame > 0)
        std.fmt.bufPrint(
            &msg_buf,
            "pulled {d}: {d} new, {d} existing, {d} non-game dropped",
            .{ total, imported, skipped, dropped_nongame },
        ) catch "pulled bookmarks"
    else
        std.fmt.bufPrint(
            &msg_buf,
            "pulled {d}: {d} new, {d} already in library",
            .{ total, imported, skipped },
        ) catch "pulled bookmarks";
    state.setBookmarksMsg(m);

    if (imported > 0) {
        // Auto-sync was already kicked per-page during live drain; we
        // don't re-trigger here because the auto-sync queue would
        // restart from scratch.
        state.reload_requested = true;
    }
}

/// Insert any newly-staged entries from the bookmark worker into the
/// library. Called every frame from `drainBookmarks`; the worker
/// stages entries page-by-page under `staged_mu`. After insert we
/// bump `staged_drained` so we don't re-process the same rows.
fn drainStagedBookmarks(frame: *Frame, job: *BookmarksJob) void {
    const state = frame.state;

    // Snapshot the new tail under the mutex; insert outside the lock.
    job.staged_mu.lockUncancelable(frame.io);
    const new_count = job.staged.items.len - job.staged_drained;
    if (new_count == 0) {
        job.staged_mu.unlock(frame.io);
        return;
    }
    const new_slice = job.staged.items[job.staged_drained .. job.staged_drained + new_count];
    job.staged_drained += new_count;
    job.staged_mu.unlock(frame.io);

    var any_inserted = false;
    for (new_slice) |e| {
        const tid = std.fmt.parseInt(u64, e.thread_id, 10) catch {
            _ = job.live_skipped.fetchAdd(1, .release);
            continue;
        };

        // 1. Decode HTML entities (&#039;, &amp;, &nbsp;, …) in the
        //    raw anchor text BEFORE parsing.
        var decoded_buf: [512]u8 = undefined;
        const decoded = f95.thread.decodeHtmlEntities(&decoded_buf, e.title);

        // 2. Strip "Thread: " / "Thread - " prefix.
        const stripped = stripThreadPrefix(decoded);

        // 3. Parse engine/version/developer + clean name.
        const parts = f95.thread.parseTitleParts(stripped);
        const name: []const u8 = if (parts.name.len > 0) parts.name else "(unsynced)";

        // 4. Filter out non-game admin threads.
        if (isLikelyNonGameTitle(name)) {
            _ = job.live_dropped.fetchAdd(1, .release);
            continue;
        }

        const g = library.Game{
            .f95_thread_id = tid,
            .name = name,
            .developer = parts.developer,
            .latest_version = parts.version,
        };
        const inserted = frame.lib.insertIfMissing(&g) catch {
            _ = job.live_skipped.fetchAdd(1, .release);
            continue;
        };
        if (inserted) {
            _ = job.live_inserted.fetchAdd(1, .release);
            any_inserted = true;
        } else {
            _ = job.live_skipped.fetchAdd(1, .release);
        }
    }

    if (any_inserted) {
        // Trigger reload so the grid picks up the new rows on the
        // next frame. We deliberately do NOT auto-queue syncs here
        // — sync is a user-initiated action. The freshly-imported
        // rows land as "(unsynced)" placeholders; the user picks
        // when to scrape them via Sync All / Updates / per-game Sync.
        state.reload_requested = true;
    }
}

/// Pure. Strip a leading "Thread: " or "Thread - " prefix from a
/// bookmark anchor text. F95 occasionally prepends this on the
/// thread-list page; the rest of our parser expects the bare title.
fn stripThreadPrefix(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (std.mem.startsWith(u8, t, "Thread: ")) return std.mem.trim(u8, t["Thread: ".len..], " \t");
    if (std.mem.startsWith(u8, t, "Thread - ")) return std.mem.trim(u8, t["Thread - ".len..], " \t");
    if (std.mem.startsWith(u8, t, "Thread ")) return std.mem.trim(u8, t["Thread ".len..], " \t");
    return t;
}

/// Pure. Match known admin / non-game thread titles that occasionally
/// show up in a bookmark dump. Conservative — only the exact-match
/// case-insensitive titles we've seen, so we don't accidentally hide
/// a game called "Forum Rules: Director's Cut" or similar.
fn isLikelyNonGameTitle(name: []const u8) bool {
    const noise = [_][]const u8{
        "Forum Rules",
        "Forum Announcement",
        "Latest Updates",
        "F95zone Premium",
        "F95Zone Premium",
        "F95zone Plus",
        "Pinned Announcements",
    };
    for (noise) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

// ---- tests ----

test "slugifyRecipeId: lowercases + hyphenates" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("some-mod-v1-2", slugifyRecipeId(&out, "Some Mod V1.2"));
    try std.testing.expectEqualStrings("ren-py-mod-loader", slugifyRecipeId(&out, "Ren'Py Mod Loader"));
    try std.testing.expectEqualStrings("mod", slugifyRecipeId(&out, "!!!"));
    try std.testing.expectEqualStrings("a-b-c", slugifyRecipeId(&out, "  a    b\nc  "));
}

test "parseF95Thread: picks the last all-numeric segment" {
    try std.testing.expectEqual(@as(u64, 0), parseF95Thread(""));
    try std.testing.expectEqual(@as(u64, 0), parseF95Thread("https://example.com/mods/cool"));
    // `/post-12345` keeps the dash in-token; parseUnsigned skips it,
    // so the thread id (`123`) is correctly returned.
    try std.testing.expectEqual(
        @as(u64, 123),
        parseF95Thread("https://f95zone.to/threads/summertime-saga.123/post-12345"),
    );
    try std.testing.expectEqual(
        @as(u64, 123),
        parseF95Thread("https://f95zone.to/threads/summertime-saga.123/"),
    );
}

test "stripThreadPrefix variants" {
    try std.testing.expectEqualStrings("My Game", stripThreadPrefix("Thread: My Game"));
    try std.testing.expectEqualStrings("My Game", stripThreadPrefix("Thread - My Game"));
    try std.testing.expectEqualStrings("My Game", stripThreadPrefix("Thread My Game"));
    try std.testing.expectEqualStrings("Regular", stripThreadPrefix("Regular"));
    try std.testing.expectEqualStrings("Thread", stripThreadPrefix("Thread"));
}

test "isLikelyNonGameTitle" {
    try std.testing.expect(isLikelyNonGameTitle("Forum Rules"));
    try std.testing.expect(isLikelyNonGameTitle("forum rules"));
    try std.testing.expect(isLikelyNonGameTitle("Latest Updates"));
    try std.testing.expect(!isLikelyNonGameTitle("Summertime Saga"));
    try std.testing.expect(!isLikelyNonGameTitle("Forum Rules: Director's Cut"));
}

// ============================================================
//  F95 login / logout
// ============================================================

/// Synchronous login from the UI thread. Blocks for ~1-2s while the
/// GET-token + POST-creds dance runs. Phase 6+ moves this onto a
/// worker thread with the same atomic-flag pattern as `syncGame`.
///
/// Persists the cookie to `frame.info.cookie_path` on success so the
/// next launch comes up authenticated.
pub fn doLogin(frame: *Frame, username: []const u8, password: []const u8) void {
    const state = frame.state;
    if (username.len == 0 or password.len == 0) {
        state.login_status = .err;
        state.setLoginMsg("username and password required");
        return;
    }
    log.info("doLogin start (user='{s}')", .{username});
    state.login_status = .logging_in;
    state.setLoginMsg("contacting F95Zone…");

    const cookie = frame.f95_svc.login(frame.io, .{
        .username = username,
        .password = password,
    }) catch |e| {
        state.login_status = .err;
        const friendly: []const u8 = switch (e) {
            error.AuthRequired => "incorrect username or password (or 2FA — not supported yet)",
            error.NetworkError => "network error — check connection",
            error.HttpStatusError => "F95Zone returned an unexpected status",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "login failed: {s}", .{friendly}) catch "login failed";
        state.setLoginMsg(m);
        return;
    };
    defer frame.lib.alloc.free(cookie);

    persistCookie(frame.io, frame.info.cookie_path, cookie) catch |e| {
        std.log.scoped(.ui).warn("could not persist cookie: {s}", .{@errorName(e)});
    };

    // Wipe the password buffer so it doesn't linger in State.
    @memset(&state.f95_pass_buf, 0);
    state.login_status = .logged_in;
    state.setLoginMsg("logged in");
}

pub fn doLogout(frame: *Frame) void {
    const state = frame.state;
    // Wipe in-memory cookie on the f95 client.
    if (frame.f95_svc.client.cookie) |old| {
        frame.lib.alloc.free(old);
        frame.f95_svc.client.cookie = null;
    }
    // Best-effort delete the on-disk cookie.
    std.Io.Dir.cwd().deleteFile(frame.io, frame.info.cookie_path) catch {};
    @memset(&state.f95_user_buf, 0);
    @memset(&state.f95_pass_buf, 0);
    state.login_status = .logged_out;
    state.setLoginMsg("logged out");
}

// ============================================================
//  RPDL login — mirrors doLogin / doLogout but for dl.rpdl.net
// ============================================================

pub fn doRpdlLogin(frame: *Frame, username: []const u8, password: []const u8) void {
    const state = frame.state;
    if (username.len == 0 or password.len == 0) {
        state.rpdl_status = .err;
        state.setRpdlMsg("username and password required");
        return;
    }
    log.info("doRpdlLogin start (user='{s}')", .{username});
    state.rpdl_status = .logging_in;
    state.setRpdlMsg("contacting RPDL…");

    const token = downloads.rpdl.login(frame.lib.alloc, frame.io, username, password) catch |e| {
        state.rpdl_status = .err;
        const friendly: []const u8 = switch (e) {
            error.AuthRequired => "incorrect username or password",
            error.NetworkError => "network error — check connection",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "login failed: {s}", .{friendly}) catch "login failed";
        state.setRpdlMsg(m);
        return;
    };

    persistRpdlToken(frame.io, frame.info.rpdl_token_path, token) catch |e| {
        std.log.scoped(.ui).warn("could not persist rpdl token: {s}", .{@errorName(e)});
    };

    // Drop any prior token + take ownership of the new one.
    if (state.rpdl_token) |old| frame.lib.alloc.free(old);
    state.rpdl_token = token;

    @memset(&state.rpdl_pass_buf, 0);
    state.rpdl_status = .logged_in;
    state.setRpdlMsg("logged in");
}

pub fn doRpdlLogout(frame: *Frame) void {
    const state = frame.state;
    if (state.rpdl_token) |old| {
        frame.lib.alloc.free(old);
        state.rpdl_token = null;
    }
    std.Io.Dir.cwd().deleteFile(frame.io, frame.info.rpdl_token_path) catch {};
    @memset(&state.rpdl_user_buf, 0);
    @memset(&state.rpdl_pass_buf, 0);
    state.rpdl_status = .logged_out;
    state.setRpdlMsg("logged out");
}

fn persistRpdlToken(io: std.Io, path: []const u8, token: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [1024]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var tmp = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer tmp.close(io);
    try tmp.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    var fw_buf: [4096]u8 = undefined;
    var fw = tmp.writer(io, &fw_buf);
    try fw.interface.writeAll(token);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Atomically write the cookie to disk with mode 0600. Tmp+rename
/// keeps a half-written file from confusing the next startup.
fn persistCookie(io: std.Io, path: []const u8, cookie: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer f.close(io);
    var fw_buf: [1024]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    try fw.interface.writeAll(cookie);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

// ============================================================
//  delete game (DB row + cover file + cache eviction)
// ============================================================

pub fn deleteGameAndReturn(frame: *Frame, thread_id: u64) void {
    const state = frame.state;
    frame.lib.deleteGame(thread_id) catch {};

    // Best-effort cover-file removal — silently ignore if missing.
    var path_buf: [256]u8 = undefined;
    if (coverPath(&path_buf, frame.info.covers_dir, thread_id)) |path| {
        std.Io.Dir.cwd().deleteFile(frame.io, path) catch {};
    } else |_| {}

    invalidateCover(state, frame.lib.alloc, thread_id);

    state.confirm_delete = false;
    state.selected_thread = null;
    state.screen = .library;
    state.reload_requested = true;
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
    resetAttempt(frame, game.f95_thread_id);
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

fn enqueueOneSource(
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

// ============================================================
//  per-game launch — recipe + sandbox
// ============================================================

/// Resolve the recipe for `game`, ensure the placeholder install dir
/// + per-game sandbox HOME exist, then ask the sandbox backend to
/// launch the recipe's `launch.linux` executable.
///
/// Layout (until Phase 7 installer lands a real version-keyed layout):
///   - install dir:  `<library_root>/<thread_id>/`
///   - sandbox HOME: `<library_root>/<thread_id>/.f69-home/`
///
/// On failure: writes a one-line message to `state.launch_msg_buf`.
/// On success: same buffer reports the PID.
pub fn doLaunchGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // ---- 1. install_path ----
    // Resolve which install row Launch acts on:
    //   1. Honour `state.detail_picker_install_id` — whatever the
    //      detail-page dropdown currently shows is what runs.
    //   2. Fall back to the newest install (top of version-desc list)
    //      when the picker hasn't recorded a choice yet (e.g. detail
    //      page opened then Launch hit from a keybind before paint).
    //   3. Last-ditch fallback: legacy `<library_root>/<tid>/` for the
    //      pre-multi-install layout — keeps Launch alive for installs
    //      that predate the installs table.
    var fallback_buf: [640]u8 = undefined;
    const installs_owned: ?[]library.Install = frame.lib.listInstalls(game.f95_thread_id) catch null;
    defer if (installs_owned) |list| frame.lib.freeInstalls(list);
    const picked_install: ?*const library.Install = blk: {
        const list = installs_owned orelse break :blk null;
        if (list.len == 0) break :blk null;
        if (state.detail_picker_install_id) |sel| {
            for (list) |*inst| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
            }
        }
        break :blk &list[0];
    };
    const install_path: []const u8 = if (picked_install) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Install path buffer overflow.");
            return;
        };
    std.Io.Dir.cwd().access(frame.io, install_path, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No install at {s}. Download the game first.", .{install_path}) catch "No install dir.";
        state.setLaunchMsg(msg);
        return;
    };

    // ---- 2. sandbox HOME ----
    // Only built when the effective sandbox decision says "sandboxed".
    // For host-mode launches we pass an empty `sandbox_home` to
    // signal NoSandbox to keep the host's own HOME in the env.
    const want_sandbox = shouldSandbox(state, game);
    var home_buf: [640]u8 = undefined;
    var sandbox_home: []const u8 = "";
    if (want_sandbox) {
        sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Sandbox HOME buffer overflow.");
            return;
        };
        std.Io.Dir.cwd().createDirPath(frame.io, sandbox_home) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to create sandbox HOME: {s}", .{@errorName(e)}) catch "createDirPath failed";
            state.setLaunchMsg(msg);
            return;
        };
    }

    // ---- 3. resolve executable ----
    // Launcher resolution: heuristic-only. We used to honor a recipe
    // `launch.linux` pin, but that field has been retired — the
    // heuristic finder catches the canonical cases and any pin
    // belongs in a per-game settings override (future work).
    //
    // Auto-convert before launch when nothing Linux-runnable is on
    // disk yet. The convert preset matcher figures out the spec from
    // the detected engine; `.none` means "nothing to do."
    var exe_buf: [512]u8 = undefined;
    var exe_storage: []const u8 = "";
    if (findLinuxLauncher(frame.io, alloc, install_path, &exe_buf) == null) {
        const conv_spec = resolveConvertSpec(frame, install_path);
        if (conv_spec != .none) {
            state.setLaunchMsg("Converting before launch...");
            frame.convert_svc.convert(install_path, conv_spec, false) catch |e| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Auto-convert failed: {s}", .{@errorName(e)}) catch "Auto-convert failed";
                state.setLaunchMsg(msg);
                return;
            };
        }
    }

    // Second pass post-convert (or first pass when no convert was
    // needed). The launcher should exist now if everything worked.
    if (findLinuxLauncher(frame.io, alloc, install_path, &exe_buf)) |found| {
        exe_storage = found;
        log.info("launch: auto-picked launcher '{s}' under {s}", .{ found, install_path });
    } else {
        // Nothing Linux-native on disk. Look for a Windows .exe so we
        // can give an actionable message.
        if (findWindowsExe(frame.io, alloc, install_path, &exe_buf)) |win_exe| {
            var buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "Found Windows binary ({s}) — click Convert to translate it for Linux first.",
                .{win_exe},
            ) catch "Windows build — click Convert first.";
            state.notifyErr(msg);
        } else {
            var buf: [384]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "No runnable found under {s}. Either the archive didn't extract cleanly (re-download), or the install layout is non-standard (open the folder and check what's there).",
                .{install_path},
            ) catch "No runnable found in the install dir.";
            state.notifyErr(msg);
        }
        return;
    }

    // Sandbox config used to pull `network` / `bind_extra` from the
    // recipe. Those are local-user decisions; default to safe (net
    // on, no extra binds). Per-game overrides will move to a DB
    // settings table when needed.
    const net: bool = true;

    // ---- 3.5. Compose env_extra from any compat fixes applied to
    //           this install. Pre-merges prepend-mode pairs with the
    //           host environ so the sandbox sees plain `SET KEY VAL`.
    //           The compat resource dir is bound into the sandbox via
    //           `bind_extra` so env paths pointing at it actually
    //           resolve inside the bwrap namespace.
    const compat_envs: []sandbox_mod.EnvOverride = blk: {
        if (picked_install) |inst| {
            break :blk composeCompatEnv(frame, &inst.id) catch |e| switch (e) {
                else => {
                    log.warn("compat env compose failed: {s}", .{@errorName(e)});
                    break :blk &.{};
                },
            };
        }
        break :blk &.{};
    };
    defer freeCompatEnv(frame.lib.alloc, compat_envs);
    const bind_extra: []const []const u8 = compatBindExtra(frame, compat_envs) catch &.{};
    defer freeCompatBindExtra(frame.lib.alloc, bind_extra);

    // ---- 4. SandboxConfig + launch ----
    // `want_sandbox` chose the route back in step 2. The sandboxed
    // path uses `frame.sandbox` (bwrap on Linux, sandboxie on Windows,
    // fallback NoSandbox elsewhere); the host path uses the always-
    // available `frame.host_launcher` with an empty `sandbox_home`
    // so the game sees the real `$HOME`.
    const cfg = sandbox_mod.SandboxConfig{
        .network = net,
        .bind_extra = bind_extra,
        .sandbox_home = sandbox_home,
        .install_path = install_path,
        .executable = exe_storage,
        .host = frame.info.host,
        .env_extra = compat_envs,
    };
    const backend_name: []const u8 = if (want_sandbox) frame.sandbox.backendName() else "host";
    const result = (if (want_sandbox)
        frame.sandbox.launch(alloc, cfg)
    else
        frame.host_launcher.launch(alloc, cfg)) catch |e| {
        // Sandbox backends stash the detail string for the most
        // recent failure. Surface it verbatim — `LaunchFailed` alone
        // is not informative ("permission denied"/"file not found"/
        // "argv too long" all collapse to the same enum value).
        const detail = if (want_sandbox) frame.sandbox.lastError() else frame.host_launcher.lastError();
        const hint = launchFailureHint(detail, backend_name);
        var buf: [512]u8 = undefined;
        const msg = if (hint.len > 0 and detail.len > 0)
            std.fmt.bufPrint(&buf, "Launch failed (backend={s}): {s}\n{s}", .{ backend_name, detail, hint }) catch "Launch failed"
        else if (detail.len > 0)
            std.fmt.bufPrint(&buf, "Launch failed (backend={s}): {s}", .{ backend_name, detail }) catch "Launch failed"
        else
            std.fmt.bufPrint(&buf, "Launch failed: {s} (backend={s})", .{ @errorName(e), backend_name }) catch "Launch failed";
        state.notifyErr(msg);
        return;
    };

    if (result.pid > 0) {
        runningGamesMap(frame).put(game.f95_thread_id, result.pid) catch {};
    }
    var ok_buf: [128]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Launched (pid {d}, {s})", .{
        result.pid,
        backend_name,
    }) catch "Launched";
    state.setLaunchMsg(ok_msg);
}

// ============================================================
//  compat env composition for launch
// ============================================================

/// Read the install's applied compat fixes, replay each recipe's
/// `env_prepend`/`env_set` actions, pre-merge prepend values with the
/// host environ, and return a freshly allocated []EnvOverride for the
/// sandbox. Caller frees via `freeCompatEnv`.
fn composeCompatEnv(frame: *Frame, install_id_ptr: *const [36]u8) ![]sandbox_mod.EnvOverride {
    const alloc = frame.lib.alloc;
    const install_id: []const u8 = install_id_ptr[0..];

    const applied = try frame.lib.listAppliedCompat(install_id);
    defer frame.lib.freeAppliedCompatList(applied);
    if (applied.len == 0) return &.{};

    // Collect recipe ids that point at recipes the repo still knows
    // about. Stale rows (recipe removed) are just skipped here; the
    // launch path doesn't take that as failure.
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (applied) |row| {
        ids.append(alloc, row.recipe_id) catch return error.OutOfMemory;
    }

    var outcome = try frame.compat_svc.composeEnv(ids.items);
    defer outcome.deinit();
    if (outcome.env_pairs.items.len == 0) return &.{};

    var overrides: std.ArrayList(sandbox_mod.EnvOverride) = .empty;
    errdefer freeOverridesList(alloc, &overrides);
    // Host environ getter — the frame doesn't carry an environ
    // reference, but the host_launcher does. We pull from there.
    //
    // For LD_LIBRARY_PATH specifically we ALSO pre-pend the GPU
    // driver dir (NixOS: /run/opengl-driver/lib). Without it,
    // libglvnd-based libGL.so.1 in our bundle can't find the
    // vendor implementation (libGLX_nvidia / libGLX_mesa) and
    // silently falls back to software rendering — a big perf hit
    // for anything that uses OpenGL.
    const gpu_driver_lib: ?[]const u8 = detectGpuDriverLib(frame);
    for (outcome.env_pairs.items) |p| {
        const name_owned = alloc.dupe(u8, p.name) catch return error.OutOfMemory;
        errdefer alloc.free(name_owned);
        const is_ld_path = std.mem.eql(u8, p.name, "LD_LIBRARY_PATH");
        const value_owned: []const u8 = if (p.prepend) blk: {
            const existing = frame.host_launcher.environ.getAlloc(alloc, p.name) catch null;
            defer if (existing) |e| alloc.free(e);
            // Format: <recipe value><sep><gpu driver><sep><existing>
            // Each part skipped when empty. Driver injection only
            // happens for LD_LIBRARY_PATH.
            const gpu_part: []const u8 = if (is_ld_path) (gpu_driver_lib orelse "") else "";
            const exist_str: []const u8 = if (existing) |e| e else "";
            const parts = [_][]const u8{ p.value, gpu_part, exist_str };
            const sep = p.sep;
            // Pre-compute total length + accumulate joining non-empty parts.
            var nonempty_count: usize = 0;
            var total: usize = 0;
            for (parts) |part| if (part.len > 0) {
                if (nonempty_count > 0) total += sep.len;
                total += part.len;
                nonempty_count += 1;
            };
            if (total == 0) break :blk alloc.dupe(u8, "") catch return error.OutOfMemory;
            const out = alloc.alloc(u8, total) catch return error.OutOfMemory;
            var idx: usize = 0;
            var written: usize = 0;
            for (parts) |part| if (part.len > 0) {
                if (written > 0) {
                    @memcpy(out[idx .. idx + sep.len], sep);
                    idx += sep.len;
                }
                @memcpy(out[idx .. idx + part.len], part);
                idx += part.len;
                written += 1;
            };
            break :blk out;
        } else alloc.dupe(u8, p.value) catch return error.OutOfMemory;
        log.info("compat: env override {s} (len {d})", .{ name_owned, value_owned.len });
        overrides.append(alloc, .{
            .name = name_owned,
            .value = value_owned,
        }) catch return error.OutOfMemory;
    }

    // GLX vendor hint — only when the env hasn't already set it and
    // we can confidently pick from /dev. This lives outside the
    // recipe because it depends on the host's GPU layout, not on
    // any specific recipe.
    if (detectGlxVendor(frame)) |vendor| blk: {
        const existing = frame.host_launcher.environ.getAlloc(alloc, "__GLX_VENDOR_LIBRARY_NAME") catch null;
        defer if (existing) |e| alloc.free(e);
        if (existing != null and existing.?.len > 0) break :blk;
        const name = alloc.dupe(u8, "__GLX_VENDOR_LIBRARY_NAME") catch return error.OutOfMemory;
        errdefer alloc.free(name);
        const value = alloc.dupe(u8, vendor) catch return error.OutOfMemory;
        errdefer alloc.free(value);
        log.info("compat: GLX vendor hint -> {s}", .{vendor});
        overrides.append(alloc, .{ .name = name, .value = value }) catch return error.OutOfMemory;
    }

    return overrides.toOwnedSlice(alloc) catch error.OutOfMemory;
}

/// Return the absolute path of the host's GPU-driver lib dir if one
/// looks plausible. Currently only handles NixOS's
/// `/run/opengl-driver/lib`; other distros' libGL lives in the
/// standard loader path and needs no injection.
fn detectGpuDriverLib(frame: *Frame) ?[]const u8 {
    const candidate = "/run/opengl-driver/lib";
    std.Io.Dir.cwd().access(frame.io, candidate, .{}) catch return null;
    return candidate;
}

/// libglvnd asks the X server "which GLX vendor for this screen?"
/// On XWayland + NVIDIA the answer is sometimes wrong (XWayland
/// advertises Mesa) so libglvnd loads libGLX_mesa and Mesa falls
/// back to llvmpipe (software). Overriding via
/// `__GLX_VENDOR_LIBRARY_NAME` skips that probe and forces the
/// vendor we want. Detection is best-effort:
///   - `/dev/nvidia0` present  → nvidia
///   - else `/dev/dri/card*`   → mesa
///   - else                    → null (let libglvnd decide)
fn detectGlxVendor(frame: *Frame) ?[]const u8 {
    std.Io.Dir.cwd().access(frame.io, "/dev/nvidia0", .{}) catch {
        std.Io.Dir.cwd().access(frame.io, "/dev/dri", .{}) catch return null;
        return "mesa";
    };
    return "nvidia";
}

fn freeCompatEnv(alloc: std.mem.Allocator, env: []sandbox_mod.EnvOverride) void {
    for (env) |o| {
        alloc.free(o.name);
        alloc.free(o.value);
    }
    if (env.len > 0) alloc.free(env);
}

/// Build a `bind_extra` slice that exposes the compat resource dir
/// inside the bwrap sandbox. Without this, env vars pointing at
/// `<data_root>/compat-resources/...` resolve to a path that doesn't
/// exist inside the sandbox's filesystem namespace. No-op when there
/// are no compat overrides to support. Caller frees via
/// `freeCompatBindExtra`.
///
/// Also includes `/run/opengl-driver` (NixOS) when present so the
/// bundled libGL dispatcher can find the vendor implementation.
fn compatBindExtra(frame: *Frame, env_extra: []const sandbox_mod.EnvOverride) ![]const []const u8 {
    if (env_extra.len == 0) return &.{};
    const alloc = frame.lib.alloc;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }
    const resources_path = try std.fmt.allocPrint(alloc, "{s}/compat-resources", .{frame.info.data_root});
    try list.append(alloc, resources_path);
    if (detectGpuDriverLib(frame) != null) {
        const gpu_path = try alloc.dupe(u8, "/run/opengl-driver");
        try list.append(alloc, gpu_path);
    }
    return list.toOwnedSlice(alloc) catch error.OutOfMemory;
}

fn freeCompatBindExtra(alloc: std.mem.Allocator, bind_extra: []const []const u8) void {
    for (bind_extra) |p| alloc.free(p);
    if (bind_extra.len > 0) alloc.free(bind_extra);
}

fn freeOverridesList(alloc: std.mem.Allocator, list: *std.ArrayList(sandbox_mod.EnvOverride)) void {
    for (list.items) |o| {
        alloc.free(o.name);
        alloc.free(o.value);
    }
    list.deinit(alloc);
}

// ============================================================
//  compat issue surface — scan + apply + undo helpers
// ============================================================
//
// Callable from any UI button. The result of `scanCompatForInstall`
// is owned by the caller and freed via the matching free helper.
// `applyCompatFix` and `undoCompatFix` persist their changes to the
// library DB so subsequent launches consult the updated state.

/// Scan an install's tree against every loaded compat recipe.
/// Returned slice is owned by the caller; free with
/// `freeCompatIssues`. Status field reflects whether a FixRecord for
/// the recipe is already present in the library for this install.
pub fn scanCompatForInstall(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
) ![]compat_mod.Issue {
    const id_slice: []const u8 = install_id[0..];
    const applied = try frame.lib.listAppliedCompat(id_slice);
    defer frame.lib.freeAppliedCompatList(applied);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(frame.lib.alloc);
    for (applied) |row| ids.append(frame.lib.alloc, row.recipe_id) catch return error.OutOfMemory;
    return frame.compat_svc.scan(install_root, ids.items);
}

pub fn freeCompatIssues(frame: *Frame, issues: []compat_mod.Issue) void {
    frame.compat_svc.freeIssues(issues);
}

/// Apply one fix and persist the FixRecord. Errors propagate from
/// the service (resource missing, snapshot failure, etc.). Caller is
/// responsible for surfacing the error message in the UI.
pub fn applyCompatFix(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
    recipe_id: []const u8,
) !void {
    const alloc = frame.lib.alloc;
    const entry = frame.compat_svc.repo.byId(recipe_id) orelse return error.RecipeNotFound;
    const id_slice: []const u8 = install_id[0..];
    const fix = try frame.compat_svc.apply(id_slice, install_root, entry);
    defer {
        alloc.free(fix.recipe_id);
        alloc.free(fix.recipe_sha256);
        for (fix.backups) |b| frame.compat_svc.backups.freeRecord(b);
        if (fix.backups.len > 0) alloc.free(fix.backups);
    }
    const backups_json = try compat_mod.serializeBackups(alloc, fix.backups);
    defer alloc.free(backups_json);
    try frame.lib.upsertAppliedCompat(id_slice, fix.recipe_id, fix.recipe_sha256, fix.applied_at, backups_json);
}

/// Reverse an applied fix and remove its row from the DB. Errors
/// propagate from restore. A failed restore leaves the FixRecord
/// row in place so the user can retry.
pub fn undoCompatFix(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
    recipe_id: []const u8,
) !void {
    const id_slice: []const u8 = install_id[0..];
    const applied = try frame.lib.listAppliedCompat(id_slice);
    defer frame.lib.freeAppliedCompatList(applied);
    var match_idx: ?usize = null;
    for (applied, 0..) |row, i| if (std.mem.eql(u8, row.recipe_id, recipe_id)) {
        match_idx = i;
        break;
    };
    const row = applied[match_idx orelse return error.NotApplied];
    const backups = try compat_mod.deserializeBackups(frame.lib.alloc, row.backups_json);
    defer {
        for (backups) |b| {
            frame.lib.alloc.free(b.sha256);
            frame.lib.alloc.free(b.relpath);
            if (b.symlink_target) |t| frame.lib.alloc.free(t);
        }
        if (backups.len > 0) frame.lib.alloc.free(backups);
    }
    const fix_record = compat_mod.FixRecord{
        .recipe_id = row.recipe_id,
        .recipe_sha256 = row.recipe_sha256,
        .applied_at = row.applied_at,
        .backups = backups,
    };
    try frame.compat_svc.undo(id_slice, install_root, fix_record);
    try frame.lib.deleteAppliedCompat(id_slice, recipe_id);
}

/// Pick a one-line "what to try next" hint for the most common launch
/// failures, by sniffing the backend's error detail string. Empty
/// return = no known suggestion; the verbatim error is then on its
/// own. Patterns are conservative — better to stay silent than guess
/// wrong and send the user chasing the wrong fix.
fn launchFailureHint(detail: []const u8, backend: []const u8) []const u8 {
    if (detail.len == 0) return "";
    // bwrap-specific failures we see often on NixOS / hardened kernels.
    if (std.mem.eql(u8, backend, "bwrap")) {
        if (std.mem.indexOf(u8, detail, "user namespaces") != null or
            std.mem.indexOf(u8, detail, "unshare") != null or
            std.mem.indexOf(u8, detail, "EPERM") != null)
        {
            return "Tip: kernel.unprivileged_userns_clone may be off. Enable user namespaces (sysctl -w kernel.unprivileged_userns_clone=1) or turn sandbox off for this game.";
        }
        if (std.mem.indexOf(u8, detail, "not found") != null) {
            return "Tip: bwrap binary missing. Install it (NixOS: `nix profile add nixpkgs#bubblewrap`) or set Sandbox=Never for this game.";
        }
    }
    // Anywhere: a permission-denied on the executable means the install
    // dropped the +x bit. `chmod_x` recipe steps may have been skipped.
    if (std.mem.indexOf(u8, detail, "Permission denied") != null or
        std.mem.indexOf(u8, detail, "EACCES") != null)
    {
        return "Tip: executable missing the +x bit. `chmod +x` the launcher, or re-run Convert to redo the install's chmod step.";
    }
    if (std.mem.indexOf(u8, detail, "No such file") != null or
        std.mem.indexOf(u8, detail, "ENOENT") != null)
    {
        return "Tip: launcher path no longer exists. The install dir may have moved or been emptied — re-download / re-import.";
    }
    return "";
}

/// Resolve the effective sandbox decision for `game`. Per-game
/// `SandboxOverride` (`.always` / `.never`) wins; `.use_default`
/// consults `state.sandbox_default` (the global toggle in Settings).
pub fn shouldSandbox(state: *const State, game: *const library.Game) bool {
    return switch (game.sandbox) {
        .always => true,
        .never => false,
        .use_default => state.sandbox_default,
    };
}

/// Resolve the effective auto-update decision for `game`. Twin of
/// `shouldSandbox`: `.always` / `.never` wins; `.use_default` falls
/// back to `state.auto_update_default`.
pub fn shouldAutoUpdate(state: *const State, game: *const library.Game) bool {
    return switch (game.auto_update) {
        .always => true,
        .never => false,
        .use_default => state.auto_update_default,
    };
}

/// True iff a recipe exists for `game_id` AND it carries at least one
/// auto-fetchable source (RPDL torrent or DDL URL). Mirror entries
/// are link-lists, not auto-fetchable. Hits disk via the recipe
/// repo — keep call sites gated on a cheap pre-check (e.g. only
/// inside the recap-push branch, where version bumps are rare).
pub fn hasAutoFetchableSource(frame: *Frame, game_id: u64) bool {
    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return false;
    var parsed = parsed_opt orelse return false;
    defer parsed.deinit();
    for (parsed.recipe.sources) |s| switch (s) {
        .rpdl, .ddl => return true,
        .mirror => continue,
    };
    return false;
}

/// Auto-update readiness for a single game. Bundles two disk-hitting
/// checks into one recipe lookup:
///   1. Recipe has at least one auto-fetchable source (RPDL / DDL).
///   2. Recipe version is canonically equivalent to F95's
///      `latest_version` — i.e. the recipe knows about this build.
///      A stale recipe (still pinned to v0.20 while F95 ships v0.21)
///      would re-download the same old archive and label it the new
///      version; skip those silently and let the recipe-repo catch
///      up out-of-band.
/// Returns `true` only when both checks pass. Used as the auto-update
/// gate inside `drainSync`.
pub fn recipeReadyForAutoUpdate(frame: *Frame, game_id: u64, target_version: []const u8) bool {
    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return false;
    var parsed = parsed_opt orelse return false;
    defer parsed.deinit();
    var has_fetchable = false;
    for (parsed.recipe.sources) |s| switch (s) {
        .rpdl, .ddl => {
            has_fetchable = true;
            break;
        },
        .mirror => continue,
    };
    if (!has_fetchable) return false;
    return version_mod.equivalent(parsed.recipe.version, target_version);
}

/// Open the manual-install panel pre-filled with `latest_version` so
/// the user can point at a new archive to satisfy the update. No-op
/// on the version pre-fill when the buffer is already non-empty —
/// don't clobber whatever the user typed.
/// Look up a recipe-recorded version by SHA-256 of the user-picked
/// archive. Used by the manual-install panel to pre-fill the
/// Version field when the local recipe set happens to know this
/// file. Sync hash compute — capped at 500 MB so the UI thread
/// doesn't freeze on multi-GB game archives (the filename heuristic
/// covers larger files).
///
/// Returns the matching `recipe.version`, allocator-owned by
/// `frame.lib.alloc`, or null when:
///   - file > size cap
///   - file unreadable
///   - no recipe source's sha256 matches
const HASH_LOOKUP_MAX_BYTES: u64 = 500 * 1024 * 1024;

pub fn lookupVersionFromArchiveSha(frame: *Frame, file_path: []const u8) ?[]u8 {
    var f = std.Io.Dir.cwd().openFile(frame.io, file_path, .{ .mode = .read_only }) catch return null;
    defer f.close(frame.io);
    const st = f.stat(frame.io) catch return null;
    if (st.size > HASH_LOOKUP_MAX_BYTES) return null;

    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(frame.io, &rd_buf);
    var hasher = downloads.Hasher.init();
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const got = fr.interface.readSliceShort(&chunk) catch return null;
        if (got == 0) break;
        hasher.update(chunk[0..got]);
    }
    const sha_bytes = hasher.finalize();
    const hex = std.fmt.bytesToHex(sha_bytes, .lower);

    return frame.recipe_repo.findVersionByArchiveSha256(&hex) catch null;
}

pub fn openManualInstallForUpdate(state: *State, latest_version: []const u8) void {
    state.manual_install_open = true;
    const cur = state.manualInstallVersionSlice();
    if (cur.len == 0 and latest_version.len > 0) {
        const n = @min(latest_version.len, state.manual_install_version_buf.len - 1);
        @memcpy(state.manual_install_version_buf[0..n], latest_version[0..n]);
        state.manual_install_version_buf[n] = 0;
    }
}

/// Walk `install_path` (up to a depth of 3) looking for a launchable
/// Linux file. Priority order:
///   1. `<game>.sh` at the root — Ren'Py / Linux ports universally
///      drop their launch script here.
///   2. Any `.sh` anywhere (search depth-limited).
///   3. Any `.AppImage` file.
/// Returns the path *relative to install_path* in `buf`. Null when
/// nothing matches.
fn findLinuxLauncher(io: std.Io, alloc: std.mem.Allocator, install_path: []const u8, buf: []u8) ?[]const u8 {
    _ = alloc;
    // Pass 1: shallow root scan first — that's where Ren'Py / native
    // Linux ports put their `.sh`. Cheap.
    var root = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch return null;
    defer root.close(io);

    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".sh") or
            std.mem.endsWith(u8, entry.name, ".AppImage"))
        {
            return std.fmt.bufPrint(buf, "{s}", .{entry.name}) catch null;
        }
    }

    // Pass 2: one level deeper. Many extracted archives wrap the
    // game in a single subdir.
    var it2 = root.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var sub_path_buf: [320]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (std.mem.endsWith(u8, sub_entry.name, ".sh") or
                std.mem.endsWith(u8, sub_entry.name, ".AppImage"))
            {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null;
            }
        }
    }
    return null;
}

/// Same shape as `findLinuxLauncher`, but for `.exe`. Used to give
/// the user an actionable "needs conversion" message instead of just
/// "nothing runnable found".
fn findWindowsExe(io: std.Io, alloc: std.mem.Allocator, install_path: []const u8, buf: []u8) ?[]const u8 {
    _ = alloc;
    var root = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".exe")) {
            return std.fmt.bufPrint(buf, "{s}", .{entry.name}) catch null;
        }
    }
    var it2 = root.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var sub_path_buf: [320]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (std.mem.endsWith(u8, sub_entry.name, ".exe")) {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null;
            }
        }
    }
    return null;
}

// ============================================================
//  per-game convert — recipe + ConvertService
// ============================================================

/// Resolve the recipe for `game`, build a `convert.ConvertSpec` from
/// its `convert_linux` block, then ask the service to apply it against
/// `<library_root>/<thread_id>/` (the same placeholder install dir
/// the Launch action uses). Idempotent — re-clicking after a
/// successful convert reports "already converted".
pub fn doConvertGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    // Convert operates against whatever the *latest* install is. If
    // there's no DB row yet, fall back to the legacy placeholder dir.
    var fallback_buf: [640]u8 = undefined;
    const install_opt = frame.lib.latestInstallForGame(game.f95_thread_id) catch null;
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install_path: []const u8 = if (install_opt) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setConvertMsg("Install path buffer overflow.");
            return;
        };

    // Convert spec from the preset matcher — engine-keyed dispatch
    // over the merged built-in + `<data_root>/convert-presets/` pool.
    const spec = resolveConvertSpec(frame, install_path);
    if (spec == .none) {
        state.setConvertMsg("No convert needed (engine not detected, or already Linux-native).");
        return;
    }

    frame.convert_svc.convert(install_path, spec, false) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Convert failed: {s}", .{@errorName(e)}) catch "Convert failed";
        state.setConvertMsg(msg);
        return;
    };

    state.setConvertMsg("Converted. Try Launch.");
}

// ============================================================
//  per-mod install — enqueue mod archive download, post-install applies
// ============================================================

/// True iff the per-install tracker carries any entry for this mod —
/// i.e. apply has already happened. Used by the detail screen to
/// flip the row's Install ↔ Uninstall button.
pub fn isModInstalled(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) bool {
    const alloc = frame.lib.alloc;
    const install_opt = resolveModsPageInstall(frame, parent_game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse return false;

    const layout = modTrackerLayout(frame.io, alloc, install.install_path) catch return false;
    defer freeModTrackerLayout(alloc, layout);
    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch return false;
    defer log_obj.deinit(alloc);

    var mod_id_buf: [32]u8 = undefined;
    const mod_id_str = std.fmt.bufPrint(&mod_id_buf, "{d}", .{mod_recipe.f95_thread}) catch return false;
    for (log_obj.entries) |e| {
        if (std.mem.eql(u8, e.mod_id, mod_id_str)) return true;
    }
    return false;
}

/// Click handler for the per-mod Uninstall button. Enqueues an
/// uninstall job; the worker thread runs `installer.uninstallMod` so a
/// big uninstall doesn't block the UI.
pub fn doUninstallMod(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) void {
    const state = frame.state;
    if (frame.mod_jobs.isModBusy(parent_game.f95_thread_id, mod_recipe.f95_thread)) {
        state.setDownloadMsg("This mod already has a job in flight.");
        return;
    }
    const install_opt = resolveModsPageInstall(frame, parent_game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse {
        state.setDownloadMsg("No install to uninstall from.");
        return;
    };
    enqueueModJob(frame, .uninstall, parent_game, mod_recipe, null, install.id[0..], .none) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to enqueue: {s}", .{@errorName(e)}) catch "Failed to enqueue uninstall";
        state.setDownloadMsg(msg);
    };
}

/// Runner the queue invokes from its worker thread. Owns all the work
/// `doInstallMod` / `doUninstallMod` used to do synchronously. Lives in
/// the UI layer because it needs Library + Repo handles. `ctx` is the
/// runner-context pointer set at queue init — we stash a `RunnerCtx`
/// there so the worker can reach lib/io.
pub const RunnerCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    lib: *library.Library,
    repo: *recipe.Repo,
};

pub fn modJobRunner(ctx: ?*anyopaque, job: *mod_job_queue.Job) void {
    const c: *RunnerCtx = @ptrCast(@alignCast(ctx orelse return));
    runOneModJob(c, job) catch |e| {
        // runOneModJob already set err_buf/len on the job before
        // returning; fall through to phase=err.
        log.warn("mod job {d} failed: {s}", .{ job.id, @errorName(e) });
    };
    // Final phase: ensure terminal state is set. runOneModJob sets
    // .done on success; on error path we set .err here unless the
    // worker already flipped it.
    const p = job.currentPhase();
    if (p != .done and p != .canceled and p != .err) {
        job.phase.store(@intFromEnum(mod_job_queue.Phase.err), .release);
    }
}

fn runOneModJob(ctx: *RunnerCtx, job: *mod_job_queue.Job) !void {
    job.phase.store(@intFromEnum(mod_job_queue.Phase.preparing), .release);
    job.progress_done.store(0, .release);
    job.progress_total.store(0, .release);

    const alloc = ctx.alloc;
    const io = ctx.io;

    // Resolve the install row by pinned id. Latest fallback would be
    // wrong here: jobs can queue while the user installs new versions,
    // and we want each job's target stable.
    const install_opt = findInstallById(ctx.lib, job.game_thread_id, job.installId());
    defer if (install_opt) |i| ctx.lib.freeInstall(i);
    const install = install_opt orelse {
        setJobErr(job, "Install row vanished.") catch {};
        return;
    };

    const layout = modTrackerLayout(io, alloc, install.install_path) catch {
        setJobErr(job, "Failed to resolve install root.") catch {};
        return;
    };
    defer freeModTrackerLayout(alloc, layout);

    var mod_id_buf: [32]u8 = undefined;
    const mod_id_str = std.fmt.bufPrint(&mod_id_buf, "{d}", .{job.mod_thread_id}) catch {
        setJobErr(job, "Mod id too long.") catch {};
        return;
    };

    switch (job.kind) {
        .install => try runInstall(ctx, job, layout, mod_id_str),
        .uninstall => try runUninstall(ctx, job, layout, mod_id_str),
    }

    // Don't promote to `.done` if the sub-runner already flipped the
    // job to `.err` / `.canceled` via setJobErr — that was the bug
    // that made every uninstall look like a success.
    const cur: mod_job_queue.Phase = @enumFromInt(job.phase.load(.monotonic));
    if (cur != .err and cur != .canceled) {
        job.phase.store(@intFromEnum(mod_job_queue.Phase.done), .release);
    }
}

fn runInstall(
    ctx: *RunnerCtx,
    job: *mod_job_queue.Job,
    layout: ModTrackerLayout,
    mod_id_str: []const u8,
) !void {
    const archive_path = job.archive_path orelse return setJobErr(job, "Install job has no archive path.");

    // Lookup the recipe so we can honor its install-step list (if any).
    // Falls through to a flat overlay when the recipe is gone or has
    // no custom steps.
    var parsed_mod_opt = ctx.repo.findMod(job.mod_recipe_id) catch null;
    defer if (parsed_mod_opt) |*p| p.deinit();

    job.phase.store(@intFromEnum(mod_job_queue.Phase.staging), .release);

    var tracker = installer_mod.Tracker.init(ctx.alloc, ctx.io, layout.tracker_path);
    defer tracker.deinit();
    var existing = installer_mod.Tracker.load(ctx.alloc, ctx.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer existing.deinit(ctx.alloc);
    for (existing.entries) |e| tracker.record(e) catch {};

    job.phase.store(@intFromEnum(mod_job_queue.Phase.applying), .release);

    const apply_opts: installer_mod.ApplyOpts = .{
        .backup_mode = job.backup_mode,
        .progress_cb = jobProgressCb,
        .progress_ctx = job,
        .cancel = &job.cancel_flag,
    };

    const apply_err: ?anyerror = if (parsed_mod_opt) |*pm| blk: {
        if (pm.recipe.install.len > 0) {
            installer_mod.applyModRecipe(
                ctx.alloc,
                ctx.io,
                mod_id_str,
                archive_path,
                layout.game_root,
                pm.recipe.install,
                &tracker,
                apply_opts,
            ) catch |e| break :blk e;
            break :blk null;
        }
        installer_mod.applyModArchive(
            ctx.alloc,
            ctx.io,
            mod_id_str,
            archive_path,
            layout.game_root,
            &tracker,
            apply_opts,
        ) catch |e| break :blk e;
        break :blk null;
    } else blk: {
        installer_mod.applyModArchive(
            ctx.alloc,
            ctx.io,
            mod_id_str,
            archive_path,
            layout.game_root,
            &tracker,
            apply_opts,
        ) catch |e| break :blk e;
        break :blk null;
    };

    if (apply_err) |e| switch (e) {
        error.Canceled => {
            job.phase.store(@intFromEnum(mod_job_queue.Phase.canceled), .release);
            return;
        },
        else => {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Install failed: {s}", .{@errorName(e)}) catch "Install failed";
            return setJobErr(job, msg);
        },
    };

    job.phase.store(@intFromEnum(mod_job_queue.Phase.flushing), .release);
    tracker.flush() catch return setJobErr(job, "Tracker flush failed.");
}

fn runUninstall(
    ctx: *RunnerCtx,
    job: *mod_job_queue.Job,
    layout: ModTrackerLayout,
    mod_id_str: []const u8,
) !void {
    job.phase.store(@intFromEnum(mod_job_queue.Phase.applying), .release);

    var log_obj = installer_mod.Tracker.load(ctx.alloc, ctx.io, layout.tracker_path) catch return setJobErr(job, "Tracker load failed.");
    defer log_obj.deinit(ctx.alloc);

    installer_mod.uninstallMod(ctx.io, layout.game_root, mod_id_str, &log_obj) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Uninstall failed: {s}", .{@errorName(e)}) catch "Uninstall failed";
        return setJobErr(job, msg);
    };

    job.phase.store(@intFromEnum(mod_job_queue.Phase.flushing), .release);

    var tracker = installer_mod.Tracker.init(ctx.alloc, ctx.io, layout.tracker_path);
    defer tracker.deinit();
    for (log_obj.entries) |e| tracker.record(e) catch {};
    tracker.removeMod(mod_id_str);
    tracker.flush() catch return setJobErr(job, "Tracker flush failed.");
}

fn jobProgressCb(ctx: ?*anyopaque, done: u32, total: u32) void {
    const job: *mod_job_queue.Job = @ptrCast(@alignCast(ctx orelse return));
    job.progress_done.store(done, .monotonic);
    if (total != 0) job.progress_total.store(total, .monotonic);
}

fn setJobErr(job: *mod_job_queue.Job, msg: []const u8) error{}!void {
    const n = @min(msg.len, job.err_buf.len);
    @memcpy(job.err_buf[0..n], msg[0..n]);
    job.err_len = @intCast(n);
    job.phase.store(@intFromEnum(mod_job_queue.Phase.err), .release);
}

/// Lookup a specific install row by id. Returns alloc-owned Install;
/// caller frees with `lib.freeInstall`. Other rows in the listInstalls
/// result are freed inline so the returned Install is the sole owner
/// of its strings.
fn findInstallById(lib: *library.Library, game_thread_id: u64, install_id: []const u8) ?library.Install {
    const installs = lib.listInstalls(game_thread_id) catch return null;
    if (installs.len == 0) return null;

    var match_idx: ?usize = null;
    for (installs, 0..) |i, idx| {
        if (std.mem.eql(u8, i.id[0..], install_id)) {
            match_idx = idx;
            break;
        }
    }
    const idx = match_idx orelse {
        lib.freeInstalls(installs);
        return null;
    };

    const matched = installs[idx];
    for (installs, 0..) |inst, j| {
        if (j == idx) continue;
        lib.freeInstall(inst);
    }
    lib.alloc.free(installs);
    return matched;
}

/// Boot-time recovery. Read the persisted queue, for each "was running"
/// job: roll back any partial tracker entries it left behind so the
/// retry starts from a clean slate. Then re-enqueue every persisted
/// job (running + queued) in the original order. Called once from
/// `runMainLoop` before the worker starts.
pub fn recoverModJobsFromDisk(
    queue: *mod_job_queue.Queue,
    lib: *library.Library,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    var recovered = queue.loadPersisted() catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return,
    } orelse return;
    defer recovered.deinit(alloc);

    mod_job_queue.adoptRecoveredNextId(queue, recovered.next_id);

    for (recovered.jobs) |*r| {
        if (r.was_running) rollbackInterruptedJob(lib, alloc, io, r) catch |e| {
            log.warn("rollback failed for thread {d}: {s}", .{ r.mod_thread_id, @errorName(e) });
        };

        const ap_owned: ?[]u8 = if (r.archive_path) |a|
            alloc.dupe(u8, a) catch return error.OutOfMemory
        else
            null;
        errdefer if (ap_owned) |x| alloc.free(x);
        const rid_owned = alloc.dupe(u8, r.mod_recipe_id) catch return error.OutOfMemory;
        errdefer alloc.free(rid_owned);
        const disp_owned = alloc.dupe(u8, r.display) catch return error.OutOfMemory;
        errdefer alloc.free(disp_owned);

        _ = queue.enqueue(
            r.kind,
            r.game_thread_id,
            r.mod_thread_id,
            rid_owned,
            disp_owned,
            ap_owned,
            r.backup_mode,
            r.install_id,
        ) catch |e| {
            alloc.free(rid_owned);
            alloc.free(disp_owned);
            if (ap_owned) |x| alloc.free(x);
            return e;
        };
    }
}

/// Roll back whatever a crashed install partially recorded in the
/// tracker. The same `uninstallMod` path the user invokes on a clean
/// uninstall — it walks the partial entries and reverses them
/// (delete added_file, restore modified_file from .f69-backups when
/// backup_mode was .copy, leave warn-and-keep entries alone).
fn rollbackInterruptedJob(
    lib: *library.Library,
    alloc: std.mem.Allocator,
    io: std.Io,
    rec: *const mod_job_queue.RecoveredJob,
) !void {
    const install_opt = findInstallById(lib, rec.game_thread_id, rec.install_id);
    defer if (install_opt) |i| lib.freeInstall(i);
    const install = install_opt orelse return;

    const layout = modTrackerLayout(io, alloc, install.install_path) catch return;
    defer freeModTrackerLayout(alloc, layout);

    var mod_id_buf: [32]u8 = undefined;
    const mod_id_str = std.fmt.bufPrint(&mod_id_buf, "{d}", .{rec.mod_thread_id}) catch return;

    var log_obj = installer_mod.Tracker.load(alloc, io, layout.tracker_path) catch return;
    defer log_obj.deinit(alloc);

    installer_mod.uninstallMod(io, layout.game_root, mod_id_str, &log_obj) catch |e| {
        log.warn("rollback: uninstallMod for {d} failed: {s}", .{ rec.mod_thread_id, @errorName(e) });
        return;
    };

    // Rewrite the tracker without the rolled-back mod's entries so a
    // fresh install doesn't see them.
    var tracker = installer_mod.Tracker.init(alloc, io, layout.tracker_path);
    defer tracker.deinit();
    for (log_obj.entries) |e| tracker.record(e) catch {};
    tracker.removeMod(mod_id_str);
    tracker.flush() catch {};
}

/// Per-frame drain: pop terminal jobs, push a success / error toast.
pub fn drainModJobs(frame: *Frame) void {
    const state = frame.state;
    frame.mod_jobs.lock();
    // Toast on terminal transitions: scan for jobs we haven't yet
    // toasted, then drop them. Snapshot the job's kind alongside the
    // phase so the toast verb matches what actually happened
    // ("Uninstalled X" vs "Installed X"; previously every .done job
    // said "Installed" regardless of kind).
    const TerminalSnap = struct {
        phase: mod_job_queue.Phase,
        kind: mod_job_queue.Kind,
        display: [128]u8,
        display_len: u8,
        err: [128]u8,
        err_len: u8,
    };
    var to_toast: [8]TerminalSnap = undefined;
    var toast_n: usize = 0;
    {
        const jobs = frame.mod_jobs.jobsLocked();
        for (jobs) |j| {
            const p = j.currentPhase();
            if (p != .done and p != .err and p != .canceled) continue;
            if (toast_n >= to_toast.len) break;
            const dlen = @min(j.display.len, to_toast[toast_n].display.len);
            @memcpy(to_toast[toast_n].display[0..dlen], j.display[0..dlen]);
            to_toast[toast_n].display_len = @intCast(dlen);
            to_toast[toast_n].phase = p;
            to_toast[toast_n].kind = j.kind;
            const elen = @min(j.errMessage().len, to_toast[toast_n].err.len);
            @memcpy(to_toast[toast_n].err[0..elen], j.errMessage()[0..elen]);
            to_toast[toast_n].err_len = @intCast(elen);
            toast_n += 1;
        }
    }
    frame.mod_jobs.unlock();

    for (to_toast[0..toast_n]) |t| {
        const disp = t.display[0..t.display_len];
        var buf: [256]u8 = undefined;
        const verb: []const u8 = if (t.kind == .install) "Installed" else "Uninstalled";
        const msg = switch (t.phase) {
            .done => std.fmt.bufPrint(&buf, "{s} `{s}`.", .{ verb, disp }) catch "Mod job done.",
            .err => blk: {
                const e = t.err[0..t.err_len];
                break :blk std.fmt.bufPrint(&buf, "`{s}`: {s}", .{ disp, e }) catch "Mod job failed.";
            },
            .canceled => std.fmt.bufPrint(&buf, "`{s}` canceled.", .{disp}) catch "Mod job canceled.",
            else => unreachable,
        };
        const toast_kind: state_mod.ToastKind = switch (t.phase) {
            .done => .success,
            .err => .err,
            .canceled => .warn,
            else => .info,
        };
        state.pushToast(toast_kind, msg);
    }

    // Any terminal mod-job transition (install / uninstall, success or
    // failure) may have mutated the install tracker — drop the
    // mods-page render cache so the next frame reads fresh installed/
    // load_index state.
    if (toast_n > 0) freeModsPageCacheState(state, frame.lib.alloc);

    frame.mod_jobs.drainFinished();
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

    state.import_job = @ptrCast(job);
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
    const opaque_ptr = state.import_job orelse return;
    const job: *import_job.Job = @ptrCast(@alignCast(opaque_ptr));

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

/// Click handler for the legacy per-recipe "Add modfile…" button.
/// Adds the file to the per-game store and links it to the mod recipe
/// id in one shot — preserves the click-to-install UX while the
/// Modfiles tab is being built out.
pub fn doRegisterModArchive(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
    src_path: []const u8,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const res = ma.addForGame(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        src_path,
    ) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Add modfile failed: {s}", .{@errorName(e)}) catch "Add modfile failed";
        state.setDownloadMsg(msg);
        return;
    };

    switch (res) {
        .added => |m| {
            defer ma.freeModfile(alloc, m);
            ma.linkRecipe(
                alloc,
                frame.io,
                frame.info.mod_archives_dir,
                parent_game.f95_thread_id,
                m.id,
                mod_recipe.id,
            ) catch |e| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Link failed: {s}", .{@errorName(e)}) catch "Link failed";
                state.setDownloadMsg(msg);
                return;
            };
            // Even when the recipe is being authored alongside the
            // archive (wizard finishing in the same flow), record the
            // detected preset id so a later "what pattern is this?"
            // query — or a future Save-as-preset round-trip — has the
            // attribution. Failures are best-effort.
            const dest_path = ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, m) catch null;
            defer if (dest_path) |p| alloc.free(p);
            if (dest_path) |path| {
                detectAndPinPreset(frame, parent_game, m.id, path);
            }

            var ok_buf: [256]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&ok_buf, "Mod archive stored — ready to install `{s}`.", .{mod_recipe.name}) catch "Mod archive stored.";
            state.setDownloadMsg(ok_msg);
        },
        .duplicate => |d| {
            defer ma.freeModfile(alloc, d.existing);
            // Same content already managed — append-link to this recipe.
            // `linkRecipe` is idempotent so the existing links survive.
            if (d.game_thread_id == parent_game.f95_thread_id) {
                ma.linkRecipe(
                    alloc,
                    frame.io,
                    frame.info.mod_archives_dir,
                    parent_game.f95_thread_id,
                    d.existing.id,
                    mod_recipe.id,
                ) catch {};
                state.setDownloadMsg("Already managed - linked to this recipe.");
            } else {
                var buf: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Already managed as `{s}` (game {d}).", .{ d.existing.filename, d.game_thread_id }) catch "Already managed.";
                state.setDownloadMsg(msg);
            }
        },
    }
}

/// Locate the disk path of the modfile linked to this mod recipe.
/// Returns allocator-owned path or null.
pub fn findRegisteredModArchive(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) ?[]u8 {
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;
    const found = ma.findByRecipe(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        mod_recipe.id,
    ) catch return null;
    if (found == null) return null;
    defer ma.freeModfile(alloc, found.?);
    return ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, found.?) catch null;
}

// ============================================================
//  Modfiles tab — per-game modfile store management
// ============================================================
//
// State.modfile_cache is an opaque pointer to a heap-allocated
// `ModfileCache` struct that owns the loaded list. We use `*anyopaque`
// in state.zig to avoid pulling installer types into that file.

const ModfileCache = struct {
    mods: []installer_mod.mod_archives.Modfile,
};

fn castModfileCache(p: *anyopaque) *ModfileCache {
    return @ptrCast(@alignCast(p));
}

/// Free + null the cached modfile list, if any.
pub fn dropModfileCache(frame: *Frame) void {
    freeModfileCacheState(frame.state, frame.lib.alloc);
}

/// State-only variant used by the shutdown teardown path (where no
/// Frame is constructed). Idempotent.
pub fn freeModfileCacheState(state: *State, alloc: std.mem.Allocator) void {
    if (state.modfile_cache) |p| {
        const cache = castModfileCache(p);
        installer_mod.mod_archives.freeModfileList(alloc, cache.mods);
        alloc.destroy(cache);
        state.modfile_cache = null;
        state.modfile_cache_thread = null;
    }
    // The mods-page cache piggybacks on the modfile cache's lifetime:
    // every mutating action that calls `refreshModfileCache` /
    // `dropModfileCache` already invalidates this too. Free here so
    // shutdown paths don't leak the parsed-recipe arenas.
    freeModsPageCacheState(state, alloc);
}

// ----- Mods page render-data cache -----
// Built once per (thread_id, install_id) and reused across frames
// until a mutating action drops it. Lets the mouse-move-driven
// rerenders skip the full recipes-dir scan + per-mod tracker load.

pub const ModsTabCounts = struct {
    installed: usize = 0,
    ready: usize = 0,
    needs_archive: usize = 0,
    needs_recipe: usize = 0,
};

pub const ModsPageCache = struct {
    /// nullable: null when no `.game.zon` exists for this thread_id.
    game_parsed: ?recipe.ParsedGame,
    /// Parsed mod recipes targeting `game_parsed.recipe.id`. Empty
    /// when `game_parsed == null` or there genuinely are none.
    mods: []recipe.ParsedMod,
    /// Pre-computed counters for the four tab labels.
    counts: ModsTabCounts,
    /// Parallel to `mods` — each flag answers the same predicates
    /// the row renderer asks (`have_archive`, `installed`,
    /// `load_index` from the resolver). Owned by `alloc`.
    have_archive: []bool,
    archive_paths: []?[]u8,
    installed: []bool,
    load_index: []?u32,
    alloc: std.mem.Allocator,
};

fn castModsPageCache(p: *anyopaque) *ModsPageCache {
    return @ptrCast(@alignCast(p));
}

pub fn dropModsPageCache(frame: *Frame) void {
    freeModsPageCacheState(frame.state, frame.lib.alloc);
}

pub fn freeModsPageCacheState(state: *State, alloc: std.mem.Allocator) void {
    if (state.mods_page_cache) |p| {
        const c = castModsPageCache(p);
        // Recipe arenas + duped strings.
        if (c.game_parsed) |*gp| gp.deinit();
        for (c.mods) |*pm| pm.deinit();
        if (c.mods.len > 0) alloc.free(c.mods);
        // Parallel arrays — archive_paths owns its strings.
        for (c.archive_paths) |maybe_p| if (maybe_p) |s| alloc.free(s);
        if (c.archive_paths.len > 0) alloc.free(c.archive_paths);
        if (c.have_archive.len > 0) alloc.free(c.have_archive);
        if (c.installed.len > 0) alloc.free(c.installed);
        if (c.load_index.len > 0) alloc.free(c.load_index);
        alloc.destroy(c);
        state.mods_page_cache = null;
        state.mods_page_cache_thread = null;
        state.mods_page_cache_install_id_len = 0;
    }
}

/// Build (or rebuild) the mods page cache for `(game, current install)`.
/// Always returns a valid pointer — on disk-iter errors it falls back
/// to an empty cache (counts.needs_recipe still counts orphan archives,
/// which are read from the already-cached modfile list).
pub fn modsPageCache(frame: *Frame, game: *const library.Game) *ModsPageCache {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Resolve current install (used as cache key + for installed/load_index).
    const install_opt = resolveModsPageInstall(frame, game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install_id_slice: []const u8 = if (install_opt) |i| i.id[0..] else &[_]u8{};

    // Cache hit check: same thread + same install id.
    if (state.mods_page_cache) |p| {
        const cached = castModsPageCache(p);
        const same_thread = (state.mods_page_cache_thread orelse 0) == game.f95_thread_id and
            state.mods_page_cache_thread != null;
        const cached_install = state.mods_page_cache_install_id_buf[0..state.mods_page_cache_install_id_len];
        if (same_thread and std.mem.eql(u8, cached_install, install_id_slice)) {
            return cached;
        }
        // Different game / install — drop and rebuild.
        freeModsPageCacheState(state, alloc);
    }

    const cache = alloc.create(ModsPageCache) catch return makeEmptyModsPageCache(state, alloc);
    cache.* = .{
        .game_parsed = null,
        .mods = &.{},
        .counts = .{},
        .have_archive = &.{},
        .archive_paths = &.{},
        .installed = &.{},
        .load_index = &.{},
        .alloc = alloc,
    };

    // Orphan archive count is recipe-independent — read from the
    // (already-cached) modfile list.
    const modfiles = modfilesForGame(frame, game);
    for (modfiles) |m| {
        if (m.recipe_ids.len == 0) cache.counts.needs_recipe += 1;
    }

    // Load game recipe + mod recipes.
    cache.game_parsed = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch null;
    if (cache.game_parsed) |gp| {
        cache.mods = frame.recipe_repo.listModsForGame(gp.recipe.id) catch blk: {
            const empty: []recipe.ParsedMod = &.{};
            break :blk empty;
        };

        if (cache.mods.len > 0) {
            cache.have_archive = alloc.alloc(bool, cache.mods.len) catch &.{};
            cache.archive_paths = alloc.alloc(?[]u8, cache.mods.len) catch &.{};
            cache.installed = alloc.alloc(bool, cache.mods.len) catch &.{};
            cache.load_index = alloc.alloc(?u32, cache.mods.len) catch &.{};
            // Defaults — any alloc that returned `&.{}` is detected by
            // checking length; we tolerate length-mismatch downstream
            // by treating empty arrays as "all false / null".
            if (cache.have_archive.len == cache.mods.len) @memset(cache.have_archive, false);
            if (cache.archive_paths.len == cache.mods.len) @memset(cache.archive_paths, null);
            if (cache.installed.len == cache.mods.len) @memset(cache.installed, false);
            if (cache.load_index.len == cache.mods.len) @memset(cache.load_index, null);

            // Archive presence per mod (also captures path so row
            // renderer can show it without another disk scan).
            for (cache.mods, 0..) |*pm, i| {
                if (findRegisteredModArchive(frame, game, &pm.recipe)) |path| {
                    if (cache.archive_paths.len == cache.mods.len) cache.archive_paths[i] = path else alloc.free(path);
                    if (cache.have_archive.len == cache.mods.len) cache.have_archive[i] = true;
                }
            }

            // Install-dependent: tracker load (once) + resolver run.
            var any_installed: bool = false;
            if (install_opt) |install| {
                const layout_opt = modTrackerLayout(frame.io, alloc, install.install_path) catch null;
                defer if (layout_opt) |l| freeModTrackerLayout(alloc, l);
                if (layout_opt) |layout| {
                    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
                    defer log_obj.deinit(alloc);
                    for (log_obj.entries) |e| {
                        if (e.mod_id.len == 0) continue;
                        const tid = std.fmt.parseUnsigned(u64, e.mod_id, 10) catch continue;
                        for (cache.mods, 0..) |*pm, i| {
                            if (pm.recipe.f95_thread == tid) {
                                if (cache.installed.len == cache.mods.len and !cache.installed[i]) {
                                    cache.installed[i] = true;
                                    any_installed = true;
                                }
                                break;
                            }
                        }
                    }
                }

                if (any_installed) {
                    // Throwaway arena for resolver scratch.
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    const aalloc = arena.allocator();

                    var requested: std.ArrayList(recipe.ModRecipe) = .empty;
                    var available: std.ArrayList(recipe.ModRecipe) = .empty;
                    for (cache.mods, 0..) |*pm, i| {
                        available.append(aalloc, pm.recipe) catch {};
                        if (cache.installed.len == cache.mods.len and cache.installed[i]) {
                            requested.append(aalloc, pm.recipe) catch {};
                        }
                    }
                    var result = resolver.solveExplained(aalloc, .{
                        .requested = requested.items,
                        .available = available.items,
                        .game_version = install.version,
                    }) catch null;
                    if (result) |*r| {
                        switch (r.*) {
                            .ok => |plan| {
                                for (plan.steps) |step| {
                                    // Match by recipe.id back to the cache slot.
                                    for (cache.mods, 0..) |*pm2, j| {
                                        if (std.mem.eql(u8, pm2.recipe.id, step.mod_id)) {
                                            if (cache.load_index.len == cache.mods.len) cache.load_index[j] = step.load_index;
                                            break;
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                        r.deinit(aalloc);
                    }
                }
            }

            // Tab counts roll up the flags.
            for (cache.mods, 0..) |_, i| {
                const inst = cache.installed.len == cache.mods.len and cache.installed[i];
                const have = cache.have_archive.len == cache.mods.len and cache.have_archive[i];
                if (inst) {
                    cache.counts.installed += 1;
                } else if (have) {
                    cache.counts.ready += 1;
                } else {
                    cache.counts.needs_archive += 1;
                }
            }
        }
    }

    // Publish to state + remember cache keys.
    state.mods_page_cache = cache;
    state.mods_page_cache_thread = game.f95_thread_id;
    const n = @min(install_id_slice.len, state.mods_page_cache_install_id_buf.len);
    @memcpy(state.mods_page_cache_install_id_buf[0..n], install_id_slice[0..n]);
    state.mods_page_cache_install_id_len = n;
    return cache;
}

/// Fallback path for OOM during cache build — returns a stub cache
/// that's harmless to render against. NOT published to state so the
/// next frame will try to rebuild.
fn makeEmptyModsPageCache(state: *State, alloc: std.mem.Allocator) *ModsPageCache {
    _ = state;
    const c = alloc.create(ModsPageCache) catch unreachable;
    c.* = .{
        .game_parsed = null,
        .mods = &.{},
        .counts = .{},
        .have_archive = &.{},
        .archive_paths = &.{},
        .installed = &.{},
        .load_index = &.{},
        .alloc = alloc,
    };
    return c;
}

/// Unlink any modfile index entry whose `recipe_id` no longer points
/// at a real `.mod.zon` on disk. Called from `refreshModfileCache`
/// so stale "linked: …" labels disappear after the user manually
/// removes a recipe file from the recipes dir (or our own
/// `doDeleteModRecipe` runs).
fn pruneOrphanRecipeLinks(frame: *Frame, parent_game: *const library.Game) void {
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;
    const mods = ma.loadIndex(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id) catch return;
    defer ma.freeModfileList(alloc, mods);

    for (mods) |m| {
        for (m.recipe_ids) |rid| {
            var p = frame.recipe_repo.findMod(rid) catch |e| {
                log.warn("pruneOrphanRecipeLinks: findMod({s}) failed: {s}", .{ rid, @errorName(e) });
                continue;
            };
            if (p) |*pp| {
                pp.deinit();
                continue;
            }
            // Recipe is gone — unlink this id from the modfile's
            // list. Other links stay intact.
            ma.unlinkRecipe(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, m.id, rid) catch |e| {
                log.warn("pruneOrphanRecipeLinks: unlink {s} failed: {s}", .{ m.id, @errorName(e) });
                continue;
            };
            log.info("pruneOrphanRecipeLinks: cleared orphan link modfile={s} recipe={s}", .{ m.id, rid });
        }
    }
}

/// Refresh the per-game modfile list cache. Loads the index from disk.
pub fn refreshModfileCache(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    // Clear orphan recipe links *before* dropping the cache so the
    // post-refresh listing reflects the cleanup in one round trip.
    pruneOrphanRecipeLinks(frame, parent_game);
    dropModfileCache(frame);

    const mods = installer_mod.mod_archives.loadIndex(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
    ) catch {
        state.setDownloadMsg("Failed to load modfile index.");
        return;
    };

    const cache = alloc.create(ModfileCache) catch {
        installer_mod.mod_archives.freeModfileList(alloc, mods);
        return;
    };
    cache.* = .{ .mods = mods };
    state.modfile_cache = cache;
    state.modfile_cache_thread = parent_game.f95_thread_id;
}

/// Returns the cached modfile list, refreshing if it belongs to a
/// different game or hasn't been loaded yet.
pub fn modfilesForGame(frame: *Frame, parent_game: *const library.Game) []const installer_mod.mod_archives.Modfile {
    const state = frame.state;
    const need_reload = state.modfile_cache_thread == null or
        state.modfile_cache_thread.? != parent_game.f95_thread_id or
        state.modfile_cache == null;
    if (need_reload) refreshModfileCache(frame, parent_game);
    if (state.modfile_cache) |p| return castModfileCache(p).mods;
    return &.{};
}

/// Picker → add archive (file picker is opened by screens.zig; this
/// just consumes the picked path). Source file is copied, not moved.
pub fn doAddModfile(frame: *Frame, parent_game: *const library.Game, src_path: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const res = ma.addForGame(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        src_path,
    ) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Add modfile failed: {s}", .{@errorName(e)}) catch "Add modfile failed";
        state.setDownloadMsg(msg);
        return;
    };

    switch (res) {
        .added => |m| {
            defer ma.freeModfile(alloc, m);
            // Auto-detect install preset by peeking at archive contents.
            // Best-effort — failures log a warning but don't block the
            // add. The user can still author a recipe manually.
            const dest_path = ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, m) catch null;
            defer if (dest_path) |p| alloc.free(p);
            if (dest_path) |path| {
                detectAndPinPreset(frame, parent_game, m.id, path);
            }

            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Added `{s}` ({d} bytes).", .{ m.filename, m.size_bytes }) catch "Added.";
            state.setDownloadMsg(msg);
        },
        .duplicate => |d| {
            defer ma.freeModfile(alloc, d.existing);
            var buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Already managed as `{s}` for game {d}.", .{ d.existing.filename, d.game_thread_id }) catch "Already managed.";
            state.setDownloadMsg(msg);
        },
    }
    refreshModfileCache(frame, parent_game);
}

// ============================================================
//  Test install (real) — backgrounded worker
// ============================================================

const TestInstallPhase = enum(u8) { pending, done, failed };

pub const TestInstallJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,

    /// Source archive on disk. Owned.
    archive_path: []u8,
    /// Scratch dir under /tmp. Owned; deleted by drain after final state.
    scratch: []u8,
    /// Arena owning the install_steps slice + per-step string copies.
    /// Deinit'd by drain.
    steps_arena: std.heap.ArenaAllocator,
    steps: []const recipe.InstallStep,

    /// Filled by the worker on success.
    file_count: usize = 0,
    total_bytes: u64 = 0,
    /// Filled on failure (worker-side static string — alloc'd into the
    /// steps_arena so the lifetime matches the job).
    err_name: ?[]const u8 = null,
};

/// Import a `.mod.zon` from anywhere on disk into the user's recipes
/// dir. Parses + validates first so a corrupt or unsafe file never
/// lands. Surfaces success/failure as a toast.
pub fn doImportModRecipe(frame: *Frame, src_path: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // 1. Load + validate the source file.
    var parsed = recipe.loadMod(frame.io, alloc, src_path) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Import: parse failed: {s}", .{@errorName(e)}) catch "Import: parse failed";
        state.pushToast(.err, msg);
        return;
    };
    defer parsed.deinit();

    const wrapped: recipe.Recipe = .{ .mod = parsed.recipe };
    recipe.validate(&wrapped) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Import: validator: {s}", .{@errorName(e)}) catch "Import: validator failed";
        state.pushToast(.err, msg);
        return;
    };

    // 2. Save into the user's recipes dir. saveMod's atomic tmp+rename
    //    handles the case where a same-id file already exists — that
    //    overwrite is intentional ("re-import updates the recipe").
    frame.recipe_repo.saveMod(&parsed.recipe) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Import: save failed: {s}", .{@errorName(e)}) catch "Import: save failed";
        state.pushToast(.err, msg);
        return;
    };

    var ok_buf: [240]u8 = undefined;
    const ok = std.fmt.bufPrint(&ok_buf, "Imported recipe `{s}`.", .{parsed.recipe.id}) catch "Recipe imported.";
    state.pushToast(.success, ok);
}

/// Resolve which install the Mods page is currently operating on.
/// Honours `state.mods_page_install_id` when set (user explicitly
/// picked a version from the page header dropdown) and falls back to
/// `latestInstallForGame` otherwise. Returns null when no install
/// exists for this game.
///
/// Caller frees with `frame.lib.freeInstall`.
pub fn resolveModsPageInstall(frame: *Frame, thread_id: u64) ?library.Install {
    const state = frame.state;
    if (state.mods_page_install_id) |sel| {
        // listInstalls returns alloc-owned rows. We keep the one we
        // want by detaching its index from the slice (so freeInstalls
        // skips it) and freeing the rest manually.
        const installs = frame.lib.listInstalls(thread_id) catch return frame.lib.latestInstallForGame(thread_id) catch null;
        if (installs.len > 0) {
            var match_idx: ?usize = null;
            for (installs, 0..) |inst, i| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                    match_idx = i;
                    break;
                }
            }
            if (match_idx) |hit| {
                // Free siblings; keep the matched row.
                for (installs, 0..) |inst, i| {
                    if (i == hit) continue;
                    frame.lib.freeInstall(inst);
                }
                const out = installs[hit];
                frame.lib.alloc.free(installs);
                return out;
            }
            // Stale id — drop the whole list and fall back below.
            frame.lib.freeInstalls(installs);
        }
    }
    return frame.lib.latestInstallForGame(thread_id) catch null;
}

/// Pick a convert spec for `game` by detecting the engine of the
/// install dir, then matching against the merged convert-preset set
/// (built-ins + `<data_root>/convert-presets/`). Returns `.none` when
/// the engine isn't detectable (game is Linux-native or unknown) so
/// callers can short-circuit cleanly. Replaces the old
/// `recipe.convert_linux` block — convert is engine-keyed dispatch,
/// not per-game data.
pub fn resolveConvertSpec(frame: *Frame, install_dir: []const u8) convert_mod.ConvertSpec {
    const detected = convert_mod.detectEngine(frame.io, install_dir);
    if (detected == .unknown) return .none;

    var bundle = convert_mod.loadMergedPresets(frame.lib.alloc, frame.io, frame.info.convert_presets_dir) catch return .none;
    defer bundle.deinit();
    const matched = convert_mod.pickPresetForEngine(bundle.presets, detected) orelse return .none;
    return matched.preset.spec;
}

/// File / dir names that strongly indicate "this is the game's
/// install root" — used by `resolveGameRoot` to peel away wrapper
/// folders that archives commonly ship at the top level.
const GAME_ROOT_TELLTALES = [_][]const u8{
    "www",                  // RPGM MV/MZ
    "game",                 // Ren'Py / Unity assets
    "BepInEx",              // Unity mod loader
    "renpy",                // Ren'Py SDK dir
    "nw.exe",               // RPGM MV Windows launcher
    "nw",                   // RPGM MV Linux launcher
    "nw.dll",               // RPGM MV Windows DLL
    "data.win",             // GameMaker
    "package.json",         // RPGM (sometimes)
};

/// Inspect `install_dir` looking for the actual game root. Many F95
/// archives ship a wrapper folder (`Game_v1.2/...`) so the bare
/// install dir is one level too shallow for the mod plan to land in
/// the right place. We probe for telltale files / dirs at depth 0;
/// if absent, we descend one level when there's exactly one
/// candidate subdir.
///
/// Caller frees the returned string. Returns a fresh dupe even when
/// no descent happens — uniform ownership for the caller.
pub fn resolveGameRoot(
    io: std.Io,
    install_dir: []const u8,
    alloc: std.mem.Allocator,
) ![]u8 {
    if (hasGameTelltale(io, install_dir)) {
        return alloc.dupe(u8, install_dir);
    }

    // Descend one level if there's exactly one non-hidden subdir.
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .iterate = true }) catch {
        return alloc.dupe(u8, install_dir);
    };
    defer dir.close(io);

    var found_name: ?[]u8 = null;
    var multiple = false;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue; // skip .f69-home etc.
        if (found_name != null) {
            multiple = true;
            break;
        }
        found_name = alloc.dupe(u8, entry.name) catch null;
    }
    defer if (found_name) |n| alloc.free(n);

    if (multiple or found_name == null) return alloc.dupe(u8, install_dir);

    const candidate = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, found_name.? }) catch {
        return alloc.dupe(u8, install_dir);
    };
    if (hasGameTelltale(io, candidate)) return candidate;
    alloc.free(candidate);
    return alloc.dupe(u8, install_dir);
}

fn hasGameTelltale(io: std.Io, path: []const u8) bool {
    for (GAME_ROOT_TELLTALES) |name| {
        var probe_buf: [1024]u8 = undefined;
        const probe = std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ path, name }) catch continue;
        if ((std.Io.Dir.cwd().access(io, probe, .{}) catch null) != null) return true;
    }
    // Fallback: any .exe / .sh / .x86_64 at this level → likely a root.
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".exe")) return true;
        if (std.mem.endsWith(u8, entry.name, ".sh")) return true;
        if (std.mem.endsWith(u8, entry.name, ".x86_64")) return true;
        if (std.mem.endsWith(u8, entry.name, ".AppImage")) return true;
    }
    return false;
}

/// Resolved on-disk layout for the per-install mod tracker. `doInstallMod`
/// writes the file inside `game_root` (the peeled wrapper folder) — every
/// reader must resolve the same way or it'll look in the wrong directory
/// and miss installed mods. This helper centralises that and returns both
/// paths so callers can also feed `game_root` to `uninstallMod`'s file
/// resolver, which is rooted at the same place.
pub const ModTrackerLayout = struct {
    game_root: []u8,
    tracker_path: []u8,
};

pub fn modTrackerLayout(
    io: std.Io,
    alloc: std.mem.Allocator,
    install_path: []const u8,
) !ModTrackerLayout {
    const game_root = try resolveGameRoot(io, install_path, alloc);
    errdefer alloc.free(game_root);
    const tracker_path = try std.fmt.allocPrint(alloc, "{s}/.f69-mods.json", .{game_root});
    return .{ .game_root = game_root, .tracker_path = tracker_path };
}

pub fn freeModTrackerLayout(alloc: std.mem.Allocator, layout: ModTrackerLayout) void {
    alloc.free(layout.game_root);
    alloc.free(layout.tracker_path);
}

/// "Test install (real)" — kicks off a worker thread that runs the
/// actual installer against a throwaway scratch dir. Verifies the
/// plan extracts cleanly against a real filesystem. UI stays
/// responsive while it runs; `drainTestInstall` per-frame posts the
/// success / failure toast when the worker finishes.
pub fn doTestInstallPreview(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const w = &(state.wizard orelse return);

    // Only one test at a time. Second click while one is running is a
    // soft no-op (the button label already says "Testing…").
    if (state.test_install_job != null) return;

    // 1. Archive path.
    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    const archive_path_opt = modfileArchivePath(frame, parent_game, modfile_id);
    const archive_path = archive_path_opt orelse {
        state.pushToast(.err, "Test install: no archive registered for this mod.");
        return;
    };

    // 2. Scratch dir under /tmp.
    var nonce: [16]u8 = undefined;
    frame.io.randomSecure(&nonce) catch frame.io.random(&nonce);
    const scratch = std.fmt.allocPrint(alloc, "/tmp/f69-preview-{x}", .{std.fmt.bytesToHex(nonce, .lower)}) catch {
        alloc.free(archive_path);
        state.pushToast(.err, "Test install: out of memory.");
        return;
    };
    std.Io.Dir.cwd().createDirPath(frame.io, scratch) catch {
        alloc.free(archive_path);
        alloc.free(scratch);
        state.pushToast(.err, "Test install: failed to create scratch dir.");
        return;
    };

    // 3. Deep-copy install_steps + strings into a job-owned arena.
    //    The wizard's buffers can mutate after spawn; we need a
    //    stable snapshot.
    var steps_arena = std.heap.ArenaAllocator.init(alloc);
    const aalloc = steps_arena.allocator();

    var steps: std.ArrayList(recipe.InstallStep) = .empty;
    var bi: usize = 0;
    while (bi < w.block_count) : (bi += 1) {
        const b = &w.blocks[bi];
        const a_src = sliceFromBuf(&b.a_buf);
        const b_src = sliceFromBuf(&b.b_buf);
        const a = aalloc.dupe(u8, a_src) catch {
            steps_arena.deinit();
            alloc.free(archive_path);
            alloc.free(scratch);
            state.pushToast(.err, "Test install: out of memory.");
            return;
        };
        const bs = if (b_src.len > 0) (aalloc.dupe(u8, b_src) catch {
            steps_arena.deinit();
            alloc.free(archive_path);
            alloc.free(scratch);
            state.pushToast(.err, "Test install: out of memory.");
            return;
        }) else "";
        const step: recipe.InstallStep = switch (b.kind) {
            .extract => .{ .extract = .{ .to = a, .strip = b.strip } },
            .extract_inner => .{ .extract_inner = .{ .archive = a, .to = bs, .strip = b.strip } },
            .copy => .{ .copy = .{ .src = a, .dest = bs } },
            .move => .{ .move = .{ .src = a, .dest = bs } },
            .delete => .{ .delete = .{ .path = a } },
            .chmod_x => blk: {
                const paths_arr = aalloc.alloc([]const u8, 1) catch {
                    steps_arena.deinit();
                    alloc.free(archive_path);
                    alloc.free(scratch);
                    state.pushToast(.err, "Test install: out of memory.");
                    return;
                };
                paths_arr[0] = a;
                break :blk .{ .chmod_x = .{ .paths = paths_arr } };
            },
        };
        steps.append(aalloc, step) catch {
            steps_arena.deinit();
            alloc.free(archive_path);
            alloc.free(scratch);
            state.pushToast(.err, "Test install: out of memory.");
            return;
        };
    }
    const steps_slice = steps.toOwnedSlice(aalloc) catch {
        steps_arena.deinit();
        alloc.free(archive_path);
        alloc.free(scratch);
        state.pushToast(.err, "Test install: out of memory.");
        return;
    };

    // 4. Build the job, spawn the thread.
    const job = alloc.create(TestInstallJob) catch {
        steps_arena.deinit();
        alloc.free(archive_path);
        alloc.free(scratch);
        state.pushToast(.err, "Test install: out of memory.");
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(TestInstallPhase.pending)),
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .archive_path = archive_path,
        .scratch = scratch,
        .steps_arena = steps_arena,
        .steps = steps_slice,
    };
    job.thr = std.Thread.spawn(.{}, testInstallWorker, .{job}) catch {
        job.steps_arena.deinit();
        alloc.free(job.archive_path);
        alloc.free(job.scratch);
        alloc.destroy(job);
        state.pushToast(.err, "Test install: failed to spawn worker thread.");
        return;
    };
    state.test_install_job = @ptrCast(job);
    log.info("test install spawned → scratch {s}", .{job.scratch});
}

fn testInstallWorker(job: *TestInstallJob) void {
    var failed = false;
    const aalloc = job.steps_arena.allocator();

    // Tracker pointing into the scratch.
    const tracker_path = std.fmt.allocPrint(aalloc, "{s}/.f69-mods.json", .{job.scratch}) catch {
        job.err_name = "out of memory";
        job.phase.store(@intFromEnum(TestInstallPhase.failed), .release);
        dvui.refresh(job.win, @src(), null);
        return;
    };
    var tracker = installer_mod.Tracker.init(job.alloc, job.io, tracker_path);
    defer tracker.deinit();

    installer_mod.applyModRecipe(
        job.alloc,
        job.io,
        "test-preview",
        job.archive_path,
        job.scratch,
        job.steps,
        &tracker,
        .{},
    ) catch |e| {
        failed = true;
        job.err_name = std.fmt.allocPrint(aalloc, "{s}", .{@errorName(e)}) catch "apply failed";
    };

    if (!failed) {
        // Walk the scratch to compute file count + total bytes.
        var root = std.Io.Dir.cwd().openDir(job.io, job.scratch, .{ .iterate = true, .access_sub_paths = true }) catch null;
        if (root) |*dir| {
            defer dir.close(job.io);
            var walker = dir.walk(job.alloc) catch null;
            if (walker) |*w| {
                defer w.deinit();
                while (w.next(job.io) catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (std.mem.endsWith(u8, entry.path, ".f69-mods.json")) continue;
                    job.file_count += 1;
                    var sub_path_buf: [1024]u8 = undefined;
                    const full = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ job.scratch, entry.path }) catch continue;
                    const stat = std.Io.Dir.cwd().statFile(job.io, full, .{}) catch continue;
                    job.total_bytes += stat.size;
                }
            }
        }
    }

    const final: TestInstallPhase = if (failed) .failed else .done;
    job.phase.store(@intFromEnum(final), .release);
    // Wake the UI loop so the drain runs promptly.
    dvui.refresh(job.win, @src(), null);
}

/// Per-frame drain: checks the in-flight test-install job's phase, on
/// completion posts the success / failure toast, cleans up the scratch
/// tree, frees the job. Called from `guiFrame` alongside the other
/// worker drains.
pub fn drainTestInstall(frame: *Frame) void {
    const state = frame.state;
    const raw = state.test_install_job orelse return;
    const job: *TestInstallJob = @ptrCast(@alignCast(raw));

    const phase: TestInstallPhase = @enumFromInt(job.phase.load(.acquire));
    if (phase == .pending) return;

    job.thr.join();

    if (phase == .done) {
        var size_buf: [32]u8 = undefined;
        const size_txt = humanBytesActions(&size_buf, job.total_bytes);
        var msg_buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Test install OK: {d} file(s), {s}.", .{ job.file_count, size_txt }) catch "Test install OK.";
        state.pushToast(.success, msg);
        log.info("test install done: {d} files, {s} to {s}", .{ job.file_count, size_txt, job.scratch });
    } else {
        var msg_buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Test install failed: {s}", .{job.err_name orelse "unknown"}) catch "Test install failed";
        state.pushToast(.err, msg);
    }

    // Cleanup scratch. Best-effort.
    std.Io.Dir.cwd().deleteTree(frame.io, job.scratch) catch |e| {
        log.warn("test install scratch cleanup failed for {s}: {s}", .{ job.scratch, @errorName(e) });
    };

    // Free job memory. Arena owns the step strings + err_name; the
    // outer allocator owns archive_path / scratch / the job struct.
    job.steps_arena.deinit();
    job.alloc.free(job.archive_path);
    job.alloc.free(job.scratch);
    job.alloc.destroy(job);
    state.test_install_job = null;
}

/// True when a test install is in flight. Used by the wizard's
/// Review-step button to swap its label to "Testing…" and refuse
/// repeat clicks until drain runs.
pub fn isTestInstallRunning(state: *const State) bool {
    return state.test_install_job != null;
}

/// Shutdown-time cleanup: if a test install is mid-run, join the
/// worker, free the job, drop the scratch. Called from `ui.zig`'s
/// teardown defer alongside the other shutdown cleanups.
pub fn freeTestInstallJob(state: *State, io: std.Io) void {
    const raw = state.test_install_job orelse return;
    const job: *TestInstallJob = @ptrCast(@alignCast(raw));
    job.thr.join();
    std.Io.Dir.cwd().deleteTree(io, job.scratch) catch {};
    job.steps_arena.deinit();
    job.alloc.free(job.archive_path);
    job.alloc.free(job.scratch);
    job.alloc.destroy(job);
    state.test_install_job = null;
}

fn humanBytesActions(buf: []u8, n: u64) []const u8 {
    const KB: f32 = 1024.0;
    const MB: f32 = 1024.0 * 1024.0;
    const GB: f32 = 1024.0 * 1024.0 * 1024.0;
    const f: f32 = @floatFromInt(n);
    if (f >= GB) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / GB}) catch "?";
    if (f >= MB) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / MB}) catch "?";
    if (f >= KB) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / KB}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

/// Resolve a modfile id to its archive's on-disk path. Caller owns
/// the returned slice (lib alloc). Returns null when the modfile
/// isn't in the per-game index. Used by the simulator and by the
/// Browse… popups on wizard path fields.
pub fn modfileArchivePath(
    frame: *Frame,
    parent_game: *const library.Game,
    modfile_id: []const u8,
) ?[]u8 {
    const ma = installer_mod.mod_archives;
    const alloc = frame.lib.alloc;
    if (modfile_id.len == 0) return null;
    const mods = modfilesForGame(frame, parent_game);
    for (mods) |m| {
        if (!std.mem.eql(u8, m.id, modfile_id)) continue;
        return ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, m) catch null;
    }
    return null;
}

/// Sorted, deduped list of top-level directory names present in
/// `archive_path`. Used to seed the Browse… menu on `to` / `dest`
/// fields — most mods install into one of a handful of well-known
/// roots (`game/`, `BepInEx/`, etc.), so the picker gives the user
/// real labels to pick instead of asking them to remember paths.
///
/// Caller frees with `freeTopDirs`.
pub fn archiveTopDirs(frame: *Frame, archive_path: []const u8) ?[][]u8 {
    const archive = installer_mod.preset_detect; // re-exports listEntries/freeEntryList
    const alloc = frame.lib.alloc;
    const entries = archive.listEntries(alloc, archive_path) catch return null;
    defer archive.freeEntryList(alloc, entries);

    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        seen.deinit();
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    for (entries) |e| {
        const slash = std.mem.indexOfScalar(u8, e, '/') orelse continue;
        if (slash == 0) continue;
        const top = e[0..slash];
        if (seen.contains(top)) continue;
        const owned_key = alloc.dupe(u8, top) catch continue;
        seen.put(owned_key, {}) catch {
            alloc.free(owned_key);
            continue;
        };
        const for_out = alloc.dupe(u8, top) catch continue;
        out.append(alloc, for_out) catch {
            alloc.free(for_out);
            continue;
        };
    }
    // Lexicographic sort so the menu ordering is stable across paints.
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc) catch null;
}

pub fn freeTopDirs(alloc: std.mem.Allocator, dirs: [][]u8) void {
    for (dirs) |d| alloc.free(d);
    if (dirs.len > 0) alloc.free(dirs);
}

/// Sorted, deduped first-level directory names from the game's install
/// dir. Lets the wizard's Browse… menu suggest real install-side paths
/// (`game/`, `lib/`, `renpy/`, etc.) for destination fields.
///
/// Uses the latest install row's `install_path` — same source as
/// `doLaunchGame`'s fallback. Caller frees with `freeTopDirs`.
pub fn installTopDirs(frame: *Frame, parent_game: *const library.Game) ?[][]u8 {
    const alloc = frame.lib.alloc;
    const install_opt = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
    const install = install_opt orelse return null;
    defer frame.lib.freeInstall(install);

    // Suggestions reflect the game-root view, not the bare extract,
    // so users see the same dirs the installer will actually target.
    const root = resolveGameRoot(frame.io, install.install_path, alloc) catch null;
    const probe = root orelse install.install_path;
    defer if (root) |r| alloc.free(r);

    var dir = std.Io.Dir.cwd().openDir(frame.io, probe, .{ .iterate = true }) catch return null;
    defer dir.close(frame.io);

    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        seen.deinit();
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }

    var iter = dir.iterate();
    while (iter.next(frame.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // Skip f69's own bookkeeping subdirs so they don't pollute
        // the Browse menu.
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        if (seen.contains(entry.name)) continue;
        const key = alloc.dupe(u8, entry.name) catch continue;
        seen.put(key, {}) catch {
            alloc.free(key);
            continue;
        };
        const for_out = alloc.dupe(u8, entry.name) catch continue;
        out.append(alloc, for_out) catch {
            alloc.free(for_out);
            continue;
        };
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc) catch null;
}

/// Build a SimulationResult for the wizard's current state. Returns
/// null on lookup failure (no modfile, no install dir, no archive
/// readable). Caller owns the returned `SimulationResult` and must
/// call `deinit`. Cheap enough (~sub-ms for typical mods) to invoke
/// every paint of the install-blocks / Review steps.
pub fn simulateCurrentPlan(frame: *Frame, parent_game: *const library.Game) ?installer_mod.SimulationResult {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const w = &(state.wizard orelse return null);

    // 1. Locate the archive on disk via modfile lookup.
    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    if (modfile_id.len == 0) return null;
    const mods = modfilesForGame(frame, parent_game);
    var disk_name: []const u8 = "";
    for (mods) |m| {
        if (std.mem.eql(u8, m.id, modfile_id)) {
            disk_name = m.disk_name;
            break;
        }
    }
    if (disk_name.len == 0) return null;
    const archive_path = std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        disk_name,
    }) catch return null;
    defer alloc.free(archive_path);

    // 2. Resolve the install dir from the wizard's picked version,
    //    falling back to `latestInstallForGame` when the buffer is
    //    empty (e.g. before the user touched the version dropdown).
    var install_buf: [768]u8 = undefined;
    const for_game_version = w.for_game_version_buf[0..std.mem.indexOfScalar(u8, &w.for_game_version_buf, 0) orelse w.for_game_version_buf.len];
    const raw_install: []const u8 = blk: {
        if (for_game_version.len > 0) {
            const installs = frame.lib.listInstalls(parent_game.f95_thread_id) catch break :blk "";
            defer if (installs.len > 0) frame.lib.freeInstalls(installs);
            for (installs) |inst| {
                if (std.mem.eql(u8, inst.version, for_game_version)) {
                    break :blk std.fmt.bufPrint(&install_buf, "{s}", .{inst.install_path}) catch break :blk "";
                }
            }
        }
        const latest = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
        if (latest) |i| {
            defer frame.lib.freeInstall(i);
            break :blk std.fmt.bufPrint(&install_buf, "{s}", .{i.install_path}) catch break :blk "";
        }
        break :blk "";
    };
    if (raw_install.len == 0) return null;

    // 2.5 Resolve the game root inside the install dir. F95 archives
    //     commonly nest the game one folder deep (`Game_v1.2/www/...`);
    //     mods target the game's content tree, not the bare extract.
    //     The simulator preview shows the resolved root in its header
    //     so the user can sanity-check.
    const game_root = resolveGameRoot(frame.io, raw_install, alloc) catch return null;
    defer alloc.free(game_root);

    // 3. Tracker path is conventional — `<game_root>/.f69-mods.json`.
    var tracker_buf: [1024]u8 = undefined;
    const tracker_path = std.fmt.bufPrint(&tracker_buf, "{s}/.f69-mods.json", .{game_root}) catch null;

    // 4. Materialize the plan from wizard blocks. We use a scratch
    //    arena so cleanup is single-deinit; the simulator copies any
    //    strings it needs into its own arena.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const scratch_alloc = scratch.allocator();

    var steps: std.ArrayList(recipe.InstallStep) = .empty;
    var i: usize = 0;
    while (i < w.block_count) : (i += 1) {
        const b = &w.blocks[i];
        const a = sliceFromBuf(&b.a_buf);
        const b_s = sliceFromBuf(&b.b_buf);
        const step: recipe.InstallStep = switch (b.kind) {
            .extract => .{ .extract = .{ .to = a, .strip = b.strip } },
            .extract_inner => .{ .extract_inner = .{ .archive = a, .to = b_s, .strip = b.strip } },
            .copy => .{ .copy = .{ .src = a, .dest = b_s } },
            .move => .{ .move = .{ .src = a, .dest = b_s } },
            .delete => .{ .delete = .{ .path = a } },
            .chmod_x => blk: {
                const paths_arr = scratch_alloc.alloc([]const u8, 1) catch return null;
                paths_arr[0] = a;
                break :blk .{ .chmod_x = .{ .paths = paths_arr } };
            },
        };
        steps.append(scratch_alloc, step) catch return null;
    }

    // 5. Run against the resolved game root, not the bare install dir.
    return installer_mod.simulateInstall(alloc, frame.io, archive_path, steps.items, game_root, tracker_path) catch null;
}

/// Two-click delete on a user preset. First call arms; second call on
/// the same id executes. Any other action between the two clears the
/// arm via `state.clearPresetDeleteArm()`. Mirrors the modfile /
/// mod-recipe delete UX.
pub fn doDeleteUserPresetArmed(frame: *Frame, preset_id: []const u8) void {
    const state = frame.state;
    const armed = state.presetPendingDeleteSlice();
    if (!std.mem.eql(u8, armed, preset_id)) {
        // First click for this id — arm and bail. Row re-renders with
        // "Confirm delete preset" label next frame.
        state.armPresetDelete(preset_id);
        return;
    }
    // Second click — clear the arm + actually delete.
    state.clearPresetDeleteArm();
    deleteUserPresetNow(frame, preset_id);
}

fn deleteUserPresetNow(frame: *Frame, preset_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const path = std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{
        frame.info.mod_presets_dir,
        preset_id,
        recipe.PRESET_FILE_SUFFIX,
    }) catch return;
    defer alloc.free(path);

    std.Io.Dir.cwd().deleteFile(frame.io, path) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Delete preset failed: {s}", .{@errorName(e)}) catch "Delete preset failed";
        state.pushToast(.err, msg);
        return;
    };
    invalidatePresetCache(state);
    var ok: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&ok, "Deleted preset `{s}`.", .{preset_id}) catch "Preset deleted.";
    state.pushToast(.success, msg);
}

/// Lazily-loaded merged preset set. First call parses built-ins +
/// scans `<data_root>/mod-presets/`; subsequent calls reuse the cache
/// until `invalidatePresetCache` is invoked (after save / delete).
/// Returns null when load fails (rare — embedded data is the only
/// load that has to succeed).
///
/// Memory model: the bundle's arena owns all preset strings AND the
/// outer `MergedPresetSet` struct itself (allocated inside the arena
/// after load). Single `bundle.deinit()` reclaims everything; no
/// trailing lib-allocator outer-struct to track.
pub fn getMergedPresets(frame: *Frame) ?*recipe.MergedPresetSet {
    const state = frame.state;
    if (state.preset_cache) |raw| {
        return @ptrCast(@alignCast(raw));
    }
    var bundle = recipe.loadMergedPresets(frame.lib.alloc, frame.io, frame.info.mod_presets_dir) catch return null;
    // Move the bundle into its own arena so the outer struct's
    // lifetime matches the inner arena's. After this move, calling
    // `bundle.deinit()` (via the cached pointer) frees the struct +
    // every preset payload in one shot.
    const bundle_ptr = bundle.arena.allocator().create(recipe.MergedPresetSet) catch {
        bundle.deinit();
        return null;
    };
    bundle_ptr.* = bundle;
    state.preset_cache = @ptrCast(bundle_ptr);
    return bundle_ptr;
}

/// Tear down the cached preset bundle. Next `getMergedPresets` call
/// rebuilds. Call after any `<data_root>/mod-presets/` write so the
/// next read sees the new disk state.
pub fn invalidatePresetCache(state: *State) void {
    if (state.preset_cache) |raw| {
        const bundle: *recipe.MergedPresetSet = @ptrCast(@alignCast(raw));
        bundle.deinit(); // arena dies → bundle_ptr's memory dies too
        state.preset_cache = null;
    }
}

/// Set / clear the preset attribution on a modfile. Pass `null` for
/// `preset_id` to clear (e.g. user picked "None" in the row dropdown).
/// Surfaces a toast only on failure — happy-path is silent because
/// the row will visually reflect the new value on next paint.
pub fn doSetModfilePreset(
    frame: *Frame,
    parent_game: *const library.Game,
    modfile_id: []const u8,
    preset_id: ?[]const u8,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;
    ma.setPresetId(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, modfile_id, preset_id) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Update preset failed: {s}", .{@errorName(e)}) catch "Update preset failed";
        state.pushToast(.err, msg);
        return;
    };
    refreshModfileCache(frame, parent_game);
}

/// Derive a user preset from a working mod recipe + its registered
/// archive. Samples the archive's top-level dirs to build a
/// `requires` pattern list, copies the recipe's `install` steps
/// verbatim, and writes the result to `<data_root>/mod-presets/`.
/// Surfaces a toast on success/failure.
pub fn doSaveModRecipeAsPreset(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // 1. Locate the archive — needed to sample paths for `requires`.
    const archive_path_opt = findRegisteredModArchive(frame, parent_game, mod_recipe);
    const archive_path = archive_path_opt orelse {
        state.pushToast(.err, "Save as preset: no archive registered for this mod.");
        return;
    };
    defer alloc.free(archive_path);

    // 2. List entries; build a sorted set of distinct first-segment
    // directory names (e.g. {"game", "BepInEx"} for an archive that
    // ships both). Routed through `preset_detect` so the UI module
    // doesn't grow a direct util_archive dep.
    const pd = installer_mod.preset_detect;
    const entries = pd.listEntries(alloc, archive_path) catch {
        state.pushToast(.err, "Save as preset: failed to read archive contents.");
        return;
    };
    defer pd.freeEntryList(alloc, entries);

    var top_dirs: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = top_dirs.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        top_dirs.deinit();
    }
    for (entries) |e| {
        const slash = std.mem.indexOfScalar(u8, e, '/') orelse continue;
        if (slash == 0) continue;
        const top = e[0..slash];
        if (top_dirs.contains(top)) continue;
        const dup = alloc.dupe(u8, top) catch continue;
        top_dirs.put(dup, {}) catch {
            alloc.free(dup);
            continue;
        };
    }

    // 3. Build the Preset in an arena so writing + stringifying is
    // single-deinit cleanup.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const preset_id = std.fmt.allocPrint(aalloc, "{s}-pattern", .{mod_recipe.id}) catch {
        state.pushToast(.err, "Save as preset: out of memory.");
        return;
    };
    const preset_name = std.fmt.allocPrint(aalloc, "User: {s}", .{mod_recipe.name}) catch mod_recipe.name;

    var requires_list: std.ArrayList([]const u8) = .empty;
    var it = top_dirs.iterator();
    while (it.next()) |e| {
        const pat = std.fmt.allocPrint(aalloc, "{s}/**/*", .{e.key_ptr.*}) catch continue;
        requires_list.append(aalloc, pat) catch break;
    }
    const requires_slice = requires_list.toOwnedSlice(aalloc) catch &[_][]const u8{};

    const preset: recipe.Preset = .{
        .id = preset_id,
        .name = preset_name,
        .description = "Derived from a working user recipe via Save as preset",
        .engine_hint = libEngineToRecipe(parent_game.engine),
        .match = .{
            .requires = requires_slice,
            .forbids = &.{},
            .min_confidence = if (requires_slice.len > 0) 0.5 else 0.0,
        },
        .install = mod_recipe.install,
        // Weight 1.5 → wins over the bundled built-ins (weight 1.0)
        // when both match, so the user's authored pattern is preferred.
        .weight = 1.5,
    };

    recipe.saveUserPreset(alloc, frame.io, frame.info.mod_presets_dir, &preset) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save as preset failed: {s}", .{@errorName(e)}) catch "Save as preset failed";
        state.pushToast(.err, msg);
        return;
    };
    invalidatePresetCache(state);

    var buf: [240]u8 = undefined;
    const ok = std.fmt.bufPrint(&buf, "Saved preset `{s}` ({d} pattern(s)).", .{ preset_id, requires_slice.len }) catch "Preset saved.";
    state.pushToast(.success, ok);
    log.info("user preset saved: {s} ({d} requires patterns)", .{ preset_id, requires_slice.len });
}

/// Deep-link to a specific Settings tab. Wraps the two-line
/// "set tab then flip screen" so callers don't have to remember the
/// order (and the intent reads cleanly at the call site).
pub fn openSettingsTab(state: *State, tab: state_mod.SettingsTab) void {
    state.settings_tab = tab;
    state.screen = .settings;
}

/// Idempotently ensure that a `<thread_id>.game.zon` exists on disk
/// for this game. Auto-derives from the scraped live `library.Game`
/// (name + version + engine — same payload `deriveLiveRecipe` builds
/// for the Recipe tab) and writes via `recipe_repo.saveGame`. No-op
/// when a recipe is already present. The goal is to remove the
/// manual "Save the recipe before adding mods" step — once the user
/// adds a mod, intent is clear enough to commit a stub.
fn ensureGameRecipeOnDisk(frame: *Frame, game: *const library.Game) !void {
    var existing = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch null;
    if (existing) |*p| {
        p.deinit();
        return;
    }

    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const engine = libEngineToRecipe(game.engine);
    const version = game.latest_version orelse "0";
    const derived = try recipe.derive.deriveGameRecipe(aalloc, .{
        .thread_id = game.f95_thread_id,
        .name = game.name,
        .version = version,
        .download_links = &.{},
        .engine = engine,
        .engine_version = null,
    });
    try frame.recipe_repo.saveGame(&derived);
    log.info("auto-saved game recipe for thread {d}", .{game.f95_thread_id});
}

/// Map a library-side engine enum to the (narrower) recipe-side one.
/// `library.Engine` is closed-set; the recipe enum collapses anything
/// outside the explicit list to `.unknown`. The matcher then treats
/// `.unknown` as "no engine hint" → only `engine_hint = null` presets
/// fire (notably the generic catch-all).
fn libEngineToRecipe(e: library.Engine) recipe.Engine {
    return switch (e) {
        .renpy => .renpy,
        .rpgm_mv => .rpgm_mv,
        .rpgm_mz => .rpgm_mz,
        .unity => .unity,
        else => .unknown,
    };
}

/// Run preset detection on `archive_path`, pin the matched preset id
/// (if any) on the modfile in the per-game index. Best-effort: failures
/// log and return silently — the user can still author a recipe.
fn detectAndPinPreset(
    frame: *Frame,
    parent_game: *const library.Game,
    modfile_id: []const u8,
    archive_path: []const u8,
) void {
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const engine_recipe: ?recipe.Engine = blk: {
        const mapped = libEngineToRecipe(parent_game.engine);
        if (mapped == .unknown) break :blk null;
        break :blk mapped;
    };

    const detection_opt = installer_mod.preset_detect.detect(
        alloc,
        frame.io,
        archive_path,
        frame.info.mod_presets_dir,
        engine_recipe,
    ) catch |e| {
        log.warn("preset detect failed for {s}: {s}", .{ archive_path, @errorName(e) });
        return;
    };
    if (detection_opt) |d| {
        defer d.deinit(alloc);
        ma.setPresetId(
            alloc,
            frame.io,
            frame.info.mod_archives_dir,
            parent_game.f95_thread_id,
            modfile_id,
            d.preset_id,
        ) catch |e| {
            log.warn("setPresetId({s}) failed: {s}", .{ d.preset_id, @errorName(e) });
            return;
        };
        log.info("preset detected: {s} (confidence={d:.2}) for modfile {s}", .{
            d.preset_id,
            d.confidence,
            modfile_id[0..@min(12, modfile_id.len)],
        });
    } else {
        log.info("no preset matched for modfile {s}", .{modfile_id[0..@min(12, modfile_id.len)]});
    }
}

/// "Scan mods folder" — walks the per-game subdir, ingests anything
/// not yet indexed. Runs synchronously today; UI calls this on click,
/// which means large dirs block until done. (TODO: worker thread once
/// the dvui async story matures.)
pub fn doScanModfiles(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    state.modfile_scan_busy = true;
    defer state.modfile_scan_busy = false;

    var report = ma.scanForGame(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
    ) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Scan failed: {s}", .{@errorName(e)}) catch "Scan failed";
        state.setDownloadMsg(msg);
        return;
    };
    defer report.deinit(alloc);

    const summary = std.fmt.bufPrint(&state.modfile_scan_msg_buf, "Added {d}, unchanged {d}, duplicate skipped {d}, non-archive skipped {d}, removed missing {d}", .{
        report.added.len,
        report.unchanged,
        report.duplicates_skipped.len,
        report.non_archive_skipped.len,
        report.removed_missing,
    }) catch state.modfile_scan_msg_buf[0..0];
    state.modfile_scan_msg_len = summary.len;

    refreshModfileCache(frame, parent_game);
}

/// Two-click delete: first click arms the row, second click performs
/// the delete. The arming id lives in `state.modfile_pending_delete_id_*`.
pub fn doDeleteModfile(frame: *Frame, parent_game: *const library.Game, modfile_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const pending = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
    if (!std.mem.eql(u8, pending, modfile_id)) {
        // First click — arm.
        const n = @min(modfile_id.len, state.modfile_pending_delete_id_buf.len);
        @memcpy(state.modfile_pending_delete_id_buf[0..n], modfile_id[0..n]);
        state.modfile_pending_delete_id_len = n;
        return;
    }

    // Second click — confirm.
    state.modfile_pending_delete_id_len = 0;

    ma.deleteForGame(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, modfile_id) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Delete failed: {s}", .{@errorName(e)}) catch "Delete failed";
        state.setDownloadMsg(msg);
        return;
    };
    state.setDownloadMsg("Modfile deleted.");
    refreshModfileCache(frame, parent_game);
}

/// Clear the pending-delete arming state. Called when the user clicks
/// any other button on the Modfiles tab (so the arming doesn't outlive
/// the intent). Clears the preset-delete arm too — same lifetime rule.
pub fn clearPendingDelete(frame: *Frame) void {
    frame.state.modfile_pending_delete_id_len = 0;
    frame.state.clearPresetDeleteArm();
}

/// Delete a mod recipe `<id>.mod.zon` from the user's local recipes
/// dir, and unlink any modfile index entries that referenced it. The
/// archive itself stays — the user can re-author or link it to a new
/// recipe later. No two-click confirm here yet (caller-side responsibility).
pub fn doDeleteModRecipe(frame: *Frame, parent_game: *const library.Game, recipe_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Delete the `.mod.zon` from disk.
    var path_buf: [768]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mod.zon", .{ frame.recipe_repo.local_dir, recipe_id }) catch {
        state.pushToast(.err, "Recipe path too long.");
        return;
    };
    std.Io.Dir.cwd().deleteFile(frame.io, path) catch |e| switch (e) {
        error.FileNotFound => {}, // already gone — proceed to cleanup
        else => {
            var buf: [240]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Delete recipe failed: {s}", .{@errorName(e)}) catch "Delete recipe failed";
            state.pushToast(.err, msg);
            return;
        },
    };
    log.info("doDeleteModRecipe: removed {s}", .{path});

    // Unlink every modfile index entry pointing at this recipe. This
    // is the cleanup pruneOrphanRecipeLinks would do anyway, but we
    // do it eagerly so the next render shows the row as "no recipe"
    // immediately.
    const ma = installer_mod.mod_archives;
    const mods = ma.loadIndex(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id) catch {
        state.pushToast(.success, "Recipe deleted (index cleanup deferred).");
        refreshModfileCache(frame, parent_game);
        return;
    };
    defer ma.freeModfileList(alloc, mods);
    var unlinked: u32 = 0;
    for (mods) |m| {
        for (m.recipe_ids) |rid| {
            if (!std.mem.eql(u8, rid, recipe_id)) continue;
            ma.unlinkRecipe(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, m.id, recipe_id) catch break;
            unlinked += 1;
            break;
        }
    }
    log.info("doDeleteModRecipe: unlinked {d} modfile(s) from recipe '{s}'", .{ unlinked, recipe_id });

    var ok_buf: [192]u8 = undefined;
    const ok = std.fmt.bufPrint(&ok_buf, "Recipe '{s}' deleted (unlinked {d} modfile(s)).", .{ recipe_id, unlinked }) catch "Recipe deleted.";
    state.pushToast(.success, ok);

    refreshModfileCache(frame, parent_game);
}

/// Two-click delete arming for the Mods tab recipe rows. First click
/// loads the recipe id into the same `modfile_pending_delete_id_*`
/// buffer used for modfile deletes (they never coexist on the same
/// row); second click on the same row dispatches the delete.
pub fn doDeleteModRecipeArmed(frame: *Frame, parent_game: *const library.Game, recipe_id: []const u8) void {
    const state = frame.state;
    const pending = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
    if (!std.mem.eql(u8, pending, recipe_id)) {
        const n = @min(recipe_id.len, state.modfile_pending_delete_id_buf.len);
        @memcpy(state.modfile_pending_delete_id_buf[0..n], recipe_id[0..n]);
        state.modfile_pending_delete_id_len = n;
        return;
    }
    state.modfile_pending_delete_id_len = 0;
    doDeleteModRecipe(frame, parent_game, recipe_id);
}

// ============================================================
//  Recipe wizard — orchestration entry points
// ============================================================

/// Open the recipe wizard, pre-filled with sensible defaults derived
/// from the current game + modfile. The wizard struct lives in
/// `state.wizard`; closing it nulls the field. The wizard is modal
/// (rendered by screens.zig over the detail page).
pub fn openWizardForModfile(frame: *Frame, parent_game: *const library.Game, modfile_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    _ = alloc;

    // Auto-promote the game recipe to disk if it isn't already there.
    // Removes the "you have to Save on the Recipe tab first" friction
    // the user flagged: once they're adding mods, the recipe stub is
    // no longer a lie — they've indicated intent to mod this game.
    ensureGameRecipeOnDisk(frame, parent_game) catch |e| {
        log.warn("auto-save game recipe for {d} failed: {s}", .{ parent_game.f95_thread_id, @errorName(e) });
        // Fall through — if save failed, findGameByThread below will
        // still surface the underlying "no recipe" toast.
    };

    // Look up the game recipe id; needed for the output's `for_game`.
    var game_parsed = frame.recipe_repo.findGameByThread(parent_game.f95_thread_id) catch null orelse {
        state.pushToast(.err, "Could not author or load the game's recipe.");
        return;
    };
    defer game_parsed.deinit();

    // Mods are versioned against a CONCRETE install; you can't author
    // a recipe that "applies to game X v0.21" if v0.21 isn't on disk
    // for the user to test against. Refuse upfront so the wizard
    // doesn't open and immediately fail at save with a confusing
    // validator error.
    const installs = frame.lib.listInstalls(parent_game.f95_thread_id) catch blk: {
        // Treat lookup failure same as "no installs" so the toast
        // below explains the user-visible reason rather than a DB
        // error string.
        const empty: []library.Install = &.{};
        break :blk empty;
    };
    defer if (installs.len > 0) frame.lib.freeInstalls(installs);
    if (installs.len == 0) {
        state.pushToast(.err, "Install the base game first — recipes need a target version.");
        return;
    }

    // `return_screen` is captured up front so we never construct a
    // WizardState without a known origin (the field has no default).
    var w = state_mod.WizardState{ .return_screen = state.screen };
    w.game_thread_id = parent_game.f95_thread_id;

    const id_n = @min(modfile_id.len, w.modfile_id_buf.len);
    @memcpy(w.modfile_id_buf[0..id_n], modfile_id[0..id_n]);
    w.modfile_id_len = id_n;

    const for_game_n = @min(game_parsed.recipe.id.len, w.for_game_buf.len);
    @memcpy(w.for_game_buf[0..for_game_n], game_parsed.recipe.id[0..for_game_n]);
    w.for_game_len = for_game_n;

    // Capture install versions for the meta-page dropdown. listInstalls
    // already returns newest-first, so installs[0] is the default
    // pick (typical "the user wants to mod the build they just
    // installed" case).
    const cap = @min(installs.len, w.install_versions_buf.len);
    var seen: usize = 0;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        const v = installs[i].version;
        if (v.len == 0) continue;
        // Dedupe — two installs sharing a version (e.g. vanilla +
        // modded) shouldn't produce two identical dropdown rows.
        var dup = false;
        var j: usize = 0;
        while (j < seen) : (j += 1) {
            const prev = w.install_versions_buf[j];
            const prev_end = std.mem.indexOfScalar(u8, &prev, 0) orelse prev.len;
            if (std.mem.eql(u8, prev[0..prev_end], v)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const n = @min(v.len, w.install_versions_buf[seen].len);
        @memcpy(w.install_versions_buf[seen][0..n], v[0..n]);
        seen += 1;
    }
    w.install_versions_count = seen;
    w.install_versions_pick = 0;

    // Mirror the default pick into the for_game_version_buf so save
    // works even if the user never opens the dropdown.
    if (seen > 0) {
        const v0 = w.install_versions_buf[0];
        const end = std.mem.indexOfScalar(u8, &v0, 0) orelse v0.len;
        const n = @min(end, w.for_game_version_buf.len);
        @memcpy(w.for_game_version_buf[0..n], v0[0..n]);
    }

    // Pre-fill install blocks from the detected preset, if any.
    // Falls back to the "extract . strip 1" generic default when the
    // modfile has no preset attribution (detection failed / no match).
    var prefilled = false;
    const mods = modfilesForGame(frame, parent_game);
    for (mods) |m| {
        if (!std.mem.eql(u8, m.id, modfile_id)) continue;

        // Pre-fill name with the modfile basename (less extension).
        const base = m.filename;
        const stem_end = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        const stem = base[0..stem_end];
        const stem_n = @min(stem.len, w.name_buf.len);
        @memcpy(w.name_buf[0..stem_n], stem[0..stem_n]);

        if (m.preset_id) |pid| {
            prefilled = prefillWizardBlocksFromPreset(frame, &w, pid);
        }
        break;
    }
    if (!prefilled) {
        // Generic default. Same fall-back the wizard previously hardcoded.
        w.blocks[0] = .{ .kind = .extract };
        const dot_str = ".";
        @memcpy(w.blocks[0].a_buf[0..dot_str.len], dot_str);
        w.blocks[0].strip = 1;
        w.block_count = 1;
    }

    // `return_screen` was set at WizardState construction — see the
    // `var w = …` line above. closeWizard / wizardSave use it to
    // bounce back to the right page.
    state.wizard = w;
    // Navigate to the full-page recipe editor. The modal wizard has
    // been retired — the editor is its own screen so the preview pane
    // can breathe and the user has room to scroll.
    state.screen = .recipe_editor;
}

/// Hydrate the wizard's block list from a saved preset's `install`.
/// Returns true on success (caller skips the generic default).
/// Reasons to return false: preset id not found in the merged set,
/// load failure, or zero install steps to copy.
fn prefillWizardBlocksFromPreset(frame: *Frame, w: *state_mod.WizardState, preset_id: []const u8) bool {
    const alloc = frame.lib.alloc;
    var bundle = recipe.loadMergedPresets(alloc, frame.io, frame.info.mod_presets_dir) catch return false;
    defer bundle.deinit();

    var matched: ?*const recipe.Preset = null;
    for (bundle.presets) |*p| {
        if (std.mem.eql(u8, p.id, preset_id)) {
            matched = p;
            break;
        }
    }
    const preset = matched orelse return false;
    if (preset.install.len == 0) return false;

    var n: usize = 0;
    for (preset.install) |step| {
        if (n >= w.blocks.len) break;
        switch (step) {
            .extract => |x| {
                w.blocks[n] = .{ .kind = .extract, .strip = x.strip };
                copyToBuf(&w.blocks[n].a_buf, x.to);
                n += 1;
            },
            .extract_inner => |x| {
                w.blocks[n] = .{ .kind = .extract_inner, .strip = x.strip };
                copyToBuf(&w.blocks[n].a_buf, x.to);
                copyToBuf(&w.blocks[n].b_buf, x.archive);
                n += 1;
            },
            .copy => |x| {
                w.blocks[n] = .{ .kind = .copy };
                copyToBuf(&w.blocks[n].a_buf, x.src);
                copyToBuf(&w.blocks[n].b_buf, x.dest);
                n += 1;
            },
            .move => |x| {
                w.blocks[n] = .{ .kind = .move };
                copyToBuf(&w.blocks[n].a_buf, x.src);
                copyToBuf(&w.blocks[n].b_buf, x.dest);
                n += 1;
            },
            .delete => |x| {
                w.blocks[n] = .{ .kind = .delete };
                copyToBuf(&w.blocks[n].a_buf, x.path);
                n += 1;
            },
            .chmod_x => |x| {
                // Wizard's block carries one path field; emit one block
                // per path in the preset's chmod_x list.
                for (x.paths) |p| {
                    if (n >= w.blocks.len) break;
                    w.blocks[n] = .{ .kind = .chmod_x };
                    copyToBuf(&w.blocks[n].a_buf, p);
                    n += 1;
                }
            },
        }
    }
    w.block_count = n;
    return n > 0;
}

fn copyToBuf(buf: []u8, src: []const u8) void {
    @memset(buf, 0);
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
}

/// Close + free the wizard. Called on Cancel / after a successful Save.
/// Restores whichever screen the user was on when the editor opened
/// (Mods page, or — as a fallback — Detail).
pub fn closeWizard(frame: *Frame) void {
    const state = frame.state;
    const return_to: state_mod.Screen = if (state.wizard) |*w| w.return_screen else .detail;
    state.wizard = null;
    if (state.screen == .recipe_editor) state.screen = return_to;
}

/// Append a new block to the wizard's install list. Picks a safe
/// default for `a_buf`. Caller should populate fields after.
pub fn wizardAddBlock(frame: *Frame, kind: state_mod.WizardBlockKind) void {
    const w = &(frame.state.wizard orelse return);
    if (w.block_count >= w.blocks.len) return;
    w.blocks[w.block_count] = .{ .kind = kind };
    w.block_count += 1;
}

/// Remove the block at `idx`, shifting subsequent blocks down.
pub fn wizardRemoveBlock(frame: *Frame, idx: usize) void {
    const w = &(frame.state.wizard orelse return);
    if (idx >= w.block_count) return;
    var i: usize = idx;
    while (i + 1 < w.block_count) : (i += 1) {
        w.blocks[i] = w.blocks[i + 1];
    }
    w.block_count -= 1;
}

/// Finalize the wizard: validate, serialize a `.mod.zon`, save it,
/// link the modfile to the new recipe id. On success, closes the
/// wizard and refreshes caches.
pub fn wizardSave(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const w = &(state.wizard orelse return);

    // ---- collect text fields ----
    const name_slice = sliceFromBuf(&w.name_buf);
    const version_slice = sliceFromBuf(&w.version_buf);
    const post_url_slice = sliceFromBuf(&w.post_url_buf);
    const for_game_version_slice = sliceFromBuf(&w.for_game_version_buf);
    const for_game_slice = w.for_game_buf[0..w.for_game_len];
    const modfile_id_slice = w.modfile_id_buf[0..w.modfile_id_len];

    if (name_slice.len == 0 or version_slice.len == 0) {
        setWizardErr(w, "Name and Version are required.");
        return;
    }

    // ---- derive recipe id from name (lowercased, hyphenated) ----
    var id_buf: [128]u8 = undefined;
    const recipe_id = slugifyRecipeId(&id_buf, name_slice);

    // ---- parse f95_thread from post URL if possible ----
    const f95_thread = parseF95Thread(post_url_slice);

    // ---- build install steps from blocks ----
    var steps: std.ArrayList(recipe.InstallStep) = .empty;
    defer steps.deinit(alloc);
    // Defer the chmod_x.paths free BEFORE the loop so a mid-loop
    // failure still runs it. (Previously declared after the loop —
    // if `append` failed on iteration N>0 the prior chmod_x paths
    // would leak.)
    defer for (steps.items) |s| switch (s) {
        .chmod_x => |x| alloc.free(x.paths),
        else => {},
    };
    var i: usize = 0;
    while (i < w.block_count) : (i += 1) {
        // Pointer into the wizard's heap-allocated state so the
        // slices we build remain valid through saveMod. Capturing by
        // value (`const b = w.blocks[i]`) would put a_buf/b_buf on
        // the iteration stack, and the slices into them would dangle
        // after the iteration ends.
        const b = &w.blocks[i];
        const a = sliceFromBuf(&b.a_buf);
        const b_s = sliceFromBuf(&b.b_buf);
        const step: recipe.InstallStep = switch (b.kind) {
            .extract => .{ .extract = .{ .to = a, .strip = b.strip } },
            .extract_inner => .{ .extract_inner = .{ .archive = a, .to = b_s, .strip = b.strip } },
            .copy => .{ .copy = .{ .src = a, .dest = b_s } },
            .move => .{ .move = .{ .src = a, .dest = b_s } },
            .delete => .{ .delete = .{ .path = a } },
            .chmod_x => blk: {
                const paths_arr = alloc.alloc([]const u8, 1) catch return setWizardErr(w, "Out of memory.");
                paths_arr[0] = a;
                break :blk .{ .chmod_x = .{ .paths = paths_arr } };
            },
        };
        steps.append(alloc, step) catch {
            // append failed — clean up the just-built step's payload
            // (only chmod_x carries an alloc'd slice).
            switch (step) {
                .chmod_x => |x| alloc.free(x.paths),
                else => {},
            }
            return setWizardErr(w, "Out of memory.");
        };
    }

    // ---- build relations slices ----
    const requires = buildRelations(alloc, w.requires_buf[0..w.requires_len]) catch return setWizardErr(w, "Out of memory.");
    defer alloc.free(requires);
    const conflicts = buildStringList(alloc, w.conflicts_buf[0..w.conflicts_len]) catch return setWizardErr(w, "Out of memory.");
    defer alloc.free(conflicts);
    const load_after = buildStringList(alloc, w.load_after_buf[0..w.load_after_len]) catch return setWizardErr(w, "Out of memory.");
    defer alloc.free(load_after);

    // ---- assemble + validate ----
    const mod = recipe.ModRecipe{
        .id = recipe_id,
        .name = name_slice,
        .f95_thread = f95_thread,
        .post_url = if (post_url_slice.len > 0) post_url_slice else null,
        .version = version_slice,
        .for_game = for_game_slice,
        .for_game_version = if (for_game_version_slice.len > 0) for_game_version_slice else null,
        .requires = requires,
        .conflicts = conflicts,
        .load_after = load_after,
        .install = steps.items,
    };
    const validate_recipe: recipe.Recipe = .{ .mod = mod };
    recipe.validate(&validate_recipe) catch |e| {
        var buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Validator: {s}", .{@errorName(e)}) catch "Validator failed.";
        return setWizardErr(w, msg);
    };

    // ---- save .mod.zon ----
    frame.recipe_repo.saveMod(&mod) catch |e| {
        var buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save failed: {s}", .{@errorName(e)}) catch "Save failed.";
        return setWizardErr(w, msg);
    };

    // ---- link modfile → recipe ----
    installer_mod.mod_archives.linkRecipe(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        modfile_id_slice,
        recipe_id,
    ) catch |e| {
        var buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Link failed: {s}", .{@errorName(e)}) catch "Link failed.";
        return setWizardErr(w, msg);
    };

    state.setDownloadMsg("Recipe saved + linked.");
    refreshModfileCache(frame, parent_game);
    closeWizard(frame);
}

fn setWizardErr(w: *state_mod.WizardState, msg: []const u8) void {
    const n = @min(msg.len, w.err_msg_buf.len);
    @memcpy(w.err_msg_buf[0..n], msg[0..n]);
    w.err_msg_len = n;
}

fn sliceFromBuf(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.trim(u8, buf[0..end], " \t\r\n");
}

/// "Some Mod V1.2!" → "some-mod-v1-2". Output written into `out`; the
/// returned slice borrows from it.
fn slugifyRecipeId(out: []u8, input: []const u8) []const u8 {
    var w: usize = 0;
    var prev_dash = true; // suppress leading dashes
    for (input) |c| {
        if (w >= out.len) break;
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            out[w] = lower;
            w += 1;
            prev_dash = false;
        } else if (!prev_dash) {
            out[w] = '-';
            w += 1;
            prev_dash = true;
        }
    }
    // Trim trailing dash.
    while (w > 0 and out[w - 1] == '-') : (w -= 1) {}
    if (w == 0) {
        const fallback = "mod";
        const n = @min(fallback.len, out.len);
        @memcpy(out[0..n], fallback[0..n]);
        return out[0..n];
    }
    return out[0..w];
}

/// Pull the F95 thread id out of a thread URL. Returns 0 when no
/// id-looking segment is found.
fn parseF95Thread(url: []const u8) u64 {
    // F95 thread URLs end in `.<thread_id>/...`. Walk segments and
    // pick the last numeric one as the thread id.
    var best: u64 = 0;
    var it = std.mem.tokenizeAny(u8, url, "/.?#&");
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const n = std.fmt.parseUnsigned(u64, seg, 10) catch continue;
        best = n;
    }
    return best;
}

fn buildRelations(alloc: std.mem.Allocator, raw: []const [64]u8) ![]const recipe.ModConstraint {
    const out = try alloc.alloc(recipe.ModConstraint, raw.len);
    // Capture by reference — `buf` as a value copy would live only
    // for the iteration, and the slices we hand into the recipe must
    // outlive the loop. Pointing at `raw[i]` (caller-owned, lives on
    // the wizard state heap) is safe through saveMod.
    for (raw, 0..) |*buf, i| {
        const s = sliceFromBuf(buf);
        out[i] = .{ .target = s };
    }
    return out;
}

fn buildStringList(alloc: std.mem.Allocator, raw: []const [64]u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, raw.len);
    for (raw, 0..) |*buf, i| {
        out[i] = sliceFromBuf(buf);
    }
    return out;
}

/// Click handler for the per-mod Install button. Now an enqueue — the
/// actual filesystem work happens on the queue's worker thread so the
/// UI stays responsive for big mods. Pre-flight (archive presence,
/// resolver advisory, conflict scan) runs synchronously here because
/// it's fast and the user wants the clash modal *before* the heavy
/// work starts.
pub fn doInstallMod(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    if (frame.mod_jobs.isModBusy(parent_game.f95_thread_id, mod_recipe.f95_thread)) {
        state.setDownloadMsg("This mod already has a job in flight.");
        return;
    }

    // 1. Archive must be registered.
    const archive_path_opt = findRegisteredModArchive(frame, parent_game, mod_recipe);
    if (archive_path_opt == null) {
        state.setDownloadMsg("Click \"Add modfile…\" first — we don't auto-download mods.");
        return;
    }
    const archive_path = archive_path_opt.?;

    // 2. Resolver pre-flight (advisory — never enqueues anything).
    if (!preflightResolveMod(frame, parent_game, mod_recipe)) {
        alloc.free(archive_path);
        return;
    }

    // 3. Need a live install to apply against.
    const install_opt = resolveModsPageInstall(frame, parent_game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse {
        alloc.free(archive_path);
        state.setDownloadMsg("Install the base game before adding mods.");
        return;
    };

    // 4. Declared-file conflict scan — same modal flow as before. Done
    //    on the UI thread so the modal can open synchronously.
    const conflicts = detectAllModFileConflicts(frame, install.install_path, mod_recipe) catch &.{};
    defer freeConflictList(alloc, conflicts);
    if (conflicts.len > 0) {
        var overrides = loadOverrides(frame, install.install_path) catch OverrideList{ .pairs = &.{} };
        defer overrides.deinit(alloc);
        var unresolved: usize = 0;
        for (conflicts) |c| {
            if (!overrides.contains(mod_recipe.id, c.path)) unresolved += 1;
        }
        if (unresolved > 0) {
            openClashModal(frame, mod_recipe, install.install_path, conflicts);
            state.setDownloadMsg("File conflicts detected — review modal.");
            alloc.free(archive_path);
            return;
        }
    }

    // 5. Hand to the queue. Worker resolves game_root + tracker
    //    layout + runs apply. Backup policy comes from the game row
    //    (persisted via the Mods page dropdown), translated from the
    //    library enum to the installer enum.
    const installer_backup: installer_mod.BackupMode = switch (parent_game.mod_backup_mode) {
        .none => .none,
        .copy => .copy,
    };
    enqueueModJob(frame, .install, parent_game, mod_recipe, archive_path, install.id[0..], installer_backup) catch |e| {
        alloc.free(archive_path);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to enqueue: {s}", .{@errorName(e)}) catch "Failed to enqueue install";
        state.setDownloadMsg(msg);
    };
}

/// Build a queue job from a UI click. Consumes `archive_path` on success
/// (transfers ownership to the Job); caller frees on failure.
fn enqueueModJob(
    frame: *Frame,
    kind: mod_job_queue.Kind,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
    archive_path: ?[]u8,
    install_id: []const u8,
    backup_mode: installer_mod.BackupMode,
) !void {
    const alloc = frame.lib.alloc;
    const recipe_id_owned = try alloc.dupe(u8, mod_recipe.id);
    errdefer alloc.free(recipe_id_owned);

    var disp_buf: [256]u8 = undefined;
    const disp = std.fmt.bufPrint(&disp_buf, "{s} v{s}", .{ mod_recipe.name, mod_recipe.version }) catch mod_recipe.name;
    const display_owned = try alloc.dupe(u8, disp);
    errdefer alloc.free(display_owned);

    _ = try frame.mod_jobs.enqueue(
        kind,
        parent_game.f95_thread_id,
        mod_recipe.f95_thread,
        recipe_id_owned,
        display_owned,
        archive_path,
        backup_mode,
        install_id,
    );
}

// ============================================================
//  Clash detection — multi-conflict + persistent overrides
// ============================================================

/// Heap-owned list of conflicts. Same shape as `ModFileConflict` but
/// returned as a slice rather than the first hit only.
pub const ModFileConflictAll = struct {
    /// Path that collides (relative to install root).
    path: []u8,
    /// Mod id (numeric F95 thread, as string) currently owning the path.
    with_mod_id: []u8,
};

fn freeConflictList(alloc: std.mem.Allocator, list: []const ModFileConflictAll) void {
    for (list) |c| {
        alloc.free(c.path);
        alloc.free(c.with_mod_id);
    }
    if (list.len > 0) alloc.free(list);
}

fn detectAllModFileConflicts(
    frame: *Frame,
    install_dir: []const u8,
    mod_recipe: *const recipe.ModRecipe,
) ![]const ModFileConflictAll {
    if (mod_recipe.files.len == 0) return &.{};
    const alloc = frame.lib.alloc;

    const layout = modTrackerLayout(frame.io, alloc, install_dir) catch return &.{};
    defer freeModTrackerLayout(alloc, layout);

    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer log_obj.deinit(alloc);

    var my_id_buf: [32]u8 = undefined;
    const my_id = std.fmt.bufPrint(&my_id_buf, "{d}", .{mod_recipe.f95_thread}) catch return &.{};

    var out: std.ArrayList(ModFileConflictAll) = .empty;
    errdefer freeConflictList(alloc, out.items);

    for (log_obj.entries) |e| {
        if (e.mod_id.len == 0) continue;
        if (std.mem.eql(u8, e.mod_id, my_id)) continue;
        for (mod_recipe.files) |f| {
            if (std.mem.eql(u8, e.path, f)) {
                const owned_path = try alloc.dupe(u8, e.path);
                errdefer alloc.free(owned_path);
                const owned_owner = try alloc.dupe(u8, e.mod_id);
                try out.append(alloc, .{ .path = owned_path, .with_mod_id = owned_owner });
            }
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Persistent file-clash overrides. JSON array of `{mod_id, path}` —
/// install consults this so the modal isn't re-raised forever.
const OverrideList = struct {
    pairs: []OverridePair,

    pub fn contains(self: *const OverrideList, recipe_id: []const u8, path: []const u8) bool {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p.recipe_id, recipe_id) and std.mem.eql(u8, p.path, path)) return true;
        }
        return false;
    }

    pub fn deinit(self: *OverrideList, alloc: std.mem.Allocator) void {
        for (self.pairs) |p| {
            alloc.free(p.recipe_id);
            alloc.free(p.path);
        }
        if (self.pairs.len > 0) alloc.free(self.pairs);
        self.* = undefined;
    }
};

const OverridePair = struct {
    recipe_id: []u8,
    path: []u8,
};

fn overridesPath(install_dir: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/.f69-overrides.json", .{install_dir});
}

fn loadOverrides(frame: *Frame, install_dir: []const u8) !OverrideList {
    const alloc = frame.lib.alloc;
    var pb: [768]u8 = undefined;
    const path = try overridesPath(install_dir, &pb);

    const bytes = std.Io.Dir.cwd().readFileAlloc(frame.io, path, alloc, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return OverrideList{ .pairs = &.{} },
        else => return e,
    };
    defer alloc.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return OverrideList{ .pairs = &.{} };

    var out: std.ArrayList(OverridePair) = .empty;
    errdefer {
        for (out.items) |p| {
            alloc.free(p.recipe_id);
            alloc.free(p.path);
        }
        out.deinit(alloc);
    }

    for (parsed.value.array.items) |v| {
        if (v != .object) continue;
        const rid_v = v.object.get("recipe_id") orelse continue;
        const path_v = v.object.get("path") orelse continue;
        if (rid_v != .string or path_v != .string) continue;
        // Locals so a mid-struct OOM doesn't strand the first dupe.
        const rid_d = try alloc.dupe(u8, rid_v.string);
        errdefer alloc.free(rid_d);
        const path_d = try alloc.dupe(u8, path_v.string);
        errdefer alloc.free(path_d);
        try out.append(alloc, .{
            .recipe_id = rid_d,
            .path = path_d,
        });
    }
    return OverrideList{ .pairs = try out.toOwnedSlice(alloc) };
}

fn saveOverrides(frame: *Frame, install_dir: []const u8, list: []const OverridePair) !void {
    const alloc = frame.lib.alloc;
    var pb: [768]u8 = undefined;
    const path = try overridesPath(install_dir, &pb);

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(alloc, 1024);
    defer aw.deinit();
    try aw.writer.writeAll("[");
    for (list, 0..) |p, i| {
        if (i > 0) try aw.writer.writeAll(",");
        // Recipe paths can contain `"`, `\`, etc. on POSIX; JSON-
        // escape both fields so reload doesn't choke.
        try aw.writer.writeAll("\n  {\"recipe_id\":");
        try writeJsonString(&aw.writer, p.recipe_id);
        try aw.writer.writeAll(",\"path\":");
        try writeJsonString(&aw.writer, p.path);
        try aw.writer.writeAll("}");
    }
    try aw.writer.writeAll("\n]\n");

    var tmp_buf: [832]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = std.Io.Dir.cwd().createFile(frame.io, tmp, .{ .truncate = true }) catch return error.WriteFailed;
    defer f.close(frame.io);
    var fw_buf: [4096]u8 = undefined;
    var fw = f.writer(frame.io, &fw_buf);
    fw.interface.writeAll(aw.writer.buffered()) catch return error.WriteFailed;
    fw.interface.flush() catch return error.WriteFailed;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, frame.io) catch return error.WriteFailed;
}

/// Write `s` as a JSON-quoted, escape-correct string. Recipe ids and
/// paths can contain `"`, `\`, etc. on POSIX; naïve printing into JSON
/// would corrupt `.f69-overrides.json` on reload.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ============================================================
//  Clash modal — open / accept / cancel
// ============================================================

pub const ClashModalState = struct {
    /// Recipe id of the mod being installed.
    recipe_id: []u8,
    /// F95 thread id used to re-look-up the mod recipe + game on accept.
    game_thread_id: u64,
    /// Install dir we're targeting (so the modal knows where to write
    /// overrides).
    install_dir: []u8,
    /// Conflicts to surface in the modal — paths + the owning mod.
    conflicts: []ModFileConflictAll,
};

fn castClashModal(p: *anyopaque) *ClashModalState {
    return @ptrCast(@alignCast(p));
}

pub fn clashModalState(frame: *Frame) ?*ClashModalState {
    const p = frame.state.clash_modal orelse return null;
    return castClashModal(p);
}

fn openClashModal(
    frame: *Frame,
    mod_recipe: *const recipe.ModRecipe,
    install_dir: []const u8,
    conflicts: []const ModFileConflictAll,
) void {
    const alloc = frame.lib.alloc;
    closeClashModal(frame); // drop any prior modal

    // Build each owned resource as a local with its own errdefer so a
    // mid-construction OOM unwinds cleanly. Original openClashModal
    // used `catch unreachable` for inner dupes (panic on OOM) and
    // leaked earlier copies — both fixed here.
    const recipe_id = alloc.dupe(u8, mod_recipe.id) catch return;
    errdefer alloc.free(recipe_id);

    const install_dir_d = alloc.dupe(u8, install_dir) catch return;
    errdefer alloc.free(install_dir_d);

    const copies = alloc.alloc(ModFileConflictAll, conflicts.len) catch return;
    var filled: usize = 0;
    errdefer {
        for (copies[0..filled]) |c| {
            alloc.free(c.path);
            alloc.free(c.with_mod_id);
        }
        alloc.free(copies);
    }

    for (conflicts) |c| {
        const path_d = alloc.dupe(u8, c.path) catch return;
        const owner_d = alloc.dupe(u8, c.with_mod_id) catch {
            alloc.free(path_d);
            return;
        };
        copies[filled] = .{ .path = path_d, .with_mod_id = owner_d };
        filled += 1;
    }

    const m = alloc.create(ClashModalState) catch return;
    m.* = .{
        .recipe_id = recipe_id,
        .game_thread_id = mod_recipe.f95_thread,
        .install_dir = install_dir_d,
        .conflicts = copies,
    };
    frame.state.clash_modal = m;
}

pub fn closeClashModal(frame: *Frame) void {
    freeClashModalState(frame.state, frame.lib.alloc);
}

/// State-only variant used by the shutdown teardown path. Idempotent.
pub fn freeClashModalState(state: *State, alloc: std.mem.Allocator) void {
    if (state.clash_modal) |p| {
        const m = castClashModal(p);
        freeConflictList(alloc, m.conflicts);
        alloc.free(m.recipe_id);
        alloc.free(m.install_dir);
        alloc.destroy(m);
        state.clash_modal = null;
    }
}

/// Append every active conflict to `.f69-overrides.json`, then close
/// the modal and re-invoke the install (which will now skip the
/// override-suppressed conflicts).
pub fn clashModalAcceptAll(frame: *Frame, parent_game: *const library.Game) void {
    const alloc = frame.lib.alloc;
    const state = frame.state;
    const m = clashModalState(frame) orelse return;

    var current = loadOverrides(frame, m.install_dir) catch OverrideList{ .pairs = &.{} };
    defer current.deinit(alloc);

    var next: std.ArrayList(OverridePair) = .empty;
    defer {
        for (next.items) |p| {
            alloc.free(p.recipe_id);
            alloc.free(p.path);
        }
        next.deinit(alloc);
    }
    for (current.pairs) |p| {
        const rid_d = alloc.dupe(u8, p.recipe_id) catch return;
        const path_d = alloc.dupe(u8, p.path) catch {
            alloc.free(rid_d);
            return;
        };
        next.append(alloc, .{ .recipe_id = rid_d, .path = path_d }) catch {
            alloc.free(rid_d);
            alloc.free(path_d);
            return;
        };
    }
    for (m.conflicts) |c| {
        if (current.contains(m.recipe_id, c.path)) continue;
        const rid_d = alloc.dupe(u8, m.recipe_id) catch return;
        const path_d = alloc.dupe(u8, c.path) catch {
            alloc.free(rid_d);
            return;
        };
        next.append(alloc, .{ .recipe_id = rid_d, .path = path_d }) catch {
            alloc.free(rid_d);
            alloc.free(path_d);
            return;
        };
    }

    saveOverrides(frame, m.install_dir, next.items) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save overrides failed: {s}", .{@errorName(e)}) catch "Save overrides failed";
        state.setDownloadMsg(msg);
        return;
    };

    // Re-look-up the recipe so we can call doInstallMod with the right
    // pointer (lifetime is owned by recipe_repo).
    const recipe_id_owned = alloc.dupe(u8, m.recipe_id) catch return;
    defer alloc.free(recipe_id_owned);
    closeClashModal(frame);

    var parsed = frame.recipe_repo.findMod(recipe_id_owned) catch null orelse {
        state.setDownloadMsg("Recipe vanished — refusing to re-install.");
        return;
    };
    defer parsed.deinit();
    doInstallMod(frame, parent_game, &parsed.recipe);
}

pub const ModFileConflict = struct {
    path: []u8, // declared file that collides
    with_mod_id: []u8, // mod_id that currently owns that path
};

/// Scan every existing tracker entry under `install_dir` for a path
/// that's also listed in `mod_recipe.files`. Returns the first
/// collision whose `mod_id` differs from this mod's. Re-installs of
/// the same mod are NOT conflicts.
///
/// Allocator-owned strings; caller frees both fields.
pub fn detectModFileConflicts(
    frame: *Frame,
    install_dir: []const u8,
    mod_recipe: *const recipe.ModRecipe,
) ?ModFileConflict {
    if (mod_recipe.files.len == 0) return null;
    const alloc = frame.lib.alloc;

    const layout = modTrackerLayout(frame.io, alloc, install_dir) catch return null;
    defer freeModTrackerLayout(alloc, layout);

    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer log_obj.deinit(alloc);

    var my_id_buf: [32]u8 = undefined;
    const my_id = std.fmt.bufPrint(&my_id_buf, "{d}", .{mod_recipe.f95_thread}) catch return null;

    for (log_obj.entries) |e| {
        if (e.mod_id.len == 0) continue;
        if (std.mem.eql(u8, e.mod_id, my_id)) continue;
        for (mod_recipe.files) |f| {
            if (std.mem.eql(u8, e.path, f)) {
                const owned_path = alloc.dupe(u8, e.path) catch return null;
                const owned_owner = alloc.dupe(u8, e.mod_id) catch {
                    alloc.free(owned_path);
                    return null;
                };
                return .{ .path = owned_path, .with_mod_id = owned_owner };
            }
        }
    }
    return null;
}

/// Resolver pre-flight. Never enqueues downloads — on a non-ok result
/// it just posts the explanation chain as a toast and returns false.
fn preflightResolveMod(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
) bool {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const mods = frame.recipe_repo.listModsForGame(mod_recipe.for_game) catch |e| {
        log.warn("install-mod: listModsForGame failed: {s}", .{@errorName(e)});
        return preflightSolveSingle(frame, parent_game, mod_recipe);
    };
    defer frame.recipe_repo.freeModList(mods);

    const inst_opt = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
    defer if (inst_opt) |i| frame.lib.freeInstall(i);
    const game_version: []const u8 = if (inst_opt) |i| i.version else "";

    var avail: std.ArrayList(recipe.ModRecipe) = .empty;
    defer avail.deinit(alloc);
    avail.append(alloc, mod_recipe.*) catch {
        state.setDownloadMsg("Out of memory.");
        return false;
    };
    for (mods) |pm| {
        if (std.mem.eql(u8, pm.recipe.id, mod_recipe.id)) continue;
        avail.append(alloc, pm.recipe) catch {
            state.setDownloadMsg("Out of memory.");
            return false;
        };
    }

    const requested = [_]recipe.ModRecipe{mod_recipe.*};
    var result = resolver.solveExplained(alloc, .{
        .requested = &requested,
        .available = avail.items,
        .game_version = game_version,
    }) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Resolver failed: {s}", .{@errorName(e)}) catch "Resolver failed";
        state.setDownloadMsg(msg);
        return false;
    };
    defer result.deinit(alloc);
    return reportResolverResult(state, &result);
}

fn preflightSolveSingle(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
) bool {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const inst_opt = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
    defer if (inst_opt) |i| frame.lib.freeInstall(i);
    const game_version: []const u8 = if (inst_opt) |i| i.version else "";

    const one = [_]recipe.ModRecipe{mod_recipe.*};
    var result = resolver.solveExplained(alloc, .{
        .requested = &one,
        .available = &one,
        .game_version = game_version,
    }) catch return true; // best-effort; let install try
    defer result.deinit(alloc);
    return reportResolverResult(state, &result);
}

/// Translate a non-ok `SolveResult` into a toast + return false.
/// Returns true for the `.ok` arm so the caller can proceed.
fn reportResolverResult(state: *State, result: *const resolver.SolveResult) bool {
    switch (result.*) {
        .ok => return true,
        .missing => |m| {
            var chain_buf: [256]u8 = undefined;
            const chain = resolver.formatChain(&chain_buf, m.chain);
            var msg_buf: [384]u8 = undefined;
            const msg = if (m.constraint.len > 0)
                std.fmt.bufPrint(&msg_buf, "Can't install: missing dep \"{s}\" {s} (chain: {s})", .{ m.missing_id, m.constraint, chain }) catch "Can't install: missing dep."
            else
                std.fmt.bufPrint(&msg_buf, "Can't install: missing dep \"{s}\" (chain: {s})", .{ m.missing_id, chain }) catch "Can't install: missing dep.";
            state.pushToast(.err, msg);
            return false;
        },
        .version_mismatch => |v| {
            var chain_buf: [256]u8 = undefined;
            const chain = resolver.formatChain(&chain_buf, v.chain);
            var msg_buf: [384]u8 = undefined;
            const what: []const u8 = switch (v.source) {
                .for_game_version => "game",
                .requires_version => "dep",
            };
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Can't install: {s} version {s} doesn't satisfy {s} (chain: {s})",
                .{ what, v.found_version, v.wanted_constraint, chain },
            ) catch "Can't install: version mismatch.";
            state.pushToast(.err, msg);
            return false;
        },
        .conflict => |c| {
            var chain_buf: [256]u8 = undefined;
            const chain = resolver.formatChain(&chain_buf, c.chain);
            var msg_buf: [384]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Can't install: conflict between \"{s}\" and \"{s}\" (chain: {s})",
                .{ c.a, c.b, chain },
            ) catch "Can't install: conflict.";
            state.pushToast(.err, msg);
            return false;
        },
        .cycle => {
            state.pushToast(.err, "Can't install: load-order cycle in mod graph.");
            return false;
        },
    }
}

// ============================================================
//  post-download install — auto-extract on .done transition
// ============================================================

const PostInstalledSet = std.AutoHashMap(u64, void);
const AttemptsMap = std.AutoHashMap(u64, u32);
const InstalledSet = std.AutoHashMap(u64, void);

fn postInstalledSet(frame: *Frame) *PostInstalledSet {
    if (frame.state.post_installed) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
    const set_ptr = frame.lib.alloc.create(PostInstalledSet) catch unreachable;
    set_ptr.* = PostInstalledSet.init(frame.lib.alloc);
    frame.state.post_installed = set_ptr;
    return set_ptr;
}

/// Lazy-init the installed-set. `refreshInstalledSet` repopulates it
/// from the DB; callers consult `isInstalled` per game.
fn installedSetPtr(frame: *Frame) *InstalledSet {
    if (frame.state.installed_set) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
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
    const was_donor = isDonorJob(frame, job_id);

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
            startDonorDownload(frame, g);
            return;
        }
    }
    if (std.mem.startsWith(u8, source, "rpdl:")) {
        if (target) |g| {
            log.info("retryDownload: job {d} (tid={d}) was RPDL — restarting search", .{ job_id, game_id });
            frame.dl_mgr.removeJob(job_id);
            startRpdlDownload(frame, g);
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
    if (state.installed_set) |opaque_ptr| {
        const set_ptr: *InstalledSet = @ptrCast(@alignCast(opaque_ptr));
        set_ptr.deinit();
        alloc.destroy(set_ptr);
        state.installed_set = null;
    }
}

fn attemptsMap(frame: *Frame) *AttemptsMap {
    if (frame.state.download_attempts) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
    const map_ptr = frame.lib.alloc.create(AttemptsMap) catch unreachable;
    map_ptr.* = AttemptsMap.init(frame.lib.alloc);
    frame.state.download_attempts = map_ptr;
    return map_ptr;
}

/// Record that the user just clicked Download for `game_id` — i.e. we
/// just enqueued `sources[0]` and should start counting failures from
/// index 0. Called by `doDownloadGame` before `enqueueOneSource`.
fn resetAttempt(frame: *Frame, game_id: u64) void {
    const m = attemptsMap(frame);
    m.put(game_id, 0) catch {};
}

const RunningGamesMap = std.AutoHashMap(u64, i32);

fn runningGamesMap(frame: *Frame) *RunningGamesMap {
    if (frame.state.running_games) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
    const map_ptr = frame.lib.alloc.create(RunningGamesMap) catch unreachable;
    map_ptr.* = RunningGamesMap.init(frame.lib.alloc);
    frame.state.running_games = map_ptr;
    return map_ptr;
}

/// Read-only probe — screens.zig uses this to swap Launch ↔ Stop.
pub fn isGameRunning(frame: *Frame, thread_id: u64) bool {
    if (frame.state.running_games == null) return false;
    return runningGamesMap(frame).contains(thread_id);
}

/// SIGTERM the running game for `game.f95_thread_id` and drop the
/// state entry. No-op + cleanup when the process is already dead.
pub fn doStopGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const m = runningGamesMap(frame);
    const pid = m.get(game.f95_thread_id) orelse {
        state.setLaunchMsg("Game is not tracked as running.");
        return;
    };
    std.posix.kill(@intCast(pid), .TERM) catch |e| switch (e) {
        error.ProcessNotFound => {
            // Already dead; just clean up state.
            _ = m.remove(game.f95_thread_id);
            state.setLaunchMsg("Game already exited.");
            return;
        },
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Stop failed: {s}", .{@errorName(e)}) catch "Stop failed";
            state.setLaunchMsg(msg);
            return;
        },
    };
    _ = m.remove(game.f95_thread_id);
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "SIGTERM sent to pid {d}", .{pid}) catch "Stopped";
    state.setLaunchMsg(msg);
}

/// Each guiFrame: prune entries whose pid has exited. Uses
/// `waitpid(pid, WNOHANG)` instead of `kill(pid, 0)` because the
/// launched game is f69's child — once it exits it becomes a
/// zombie, and `kill(zombie, 0)` returns success (zombies "exist"
/// until reaped). `waitpid(WNOHANG)` both detects the exit AND
/// reaps the zombie in a single non-blocking call.
pub fn drainRunningGames(frame: *Frame) void {
    if (frame.state.running_games == null) return;
    const m = runningGamesMap(frame);

    var doomed: std.ArrayList(struct { tid: u64, status: u32, pid: i32 }) = .empty;
    defer doomed.deinit(frame.lib.alloc);
    var it = m.iterator();
    while (it.next()) |entry| {
        const pid: std.c.pid_t = @intCast(entry.value_ptr.*);
        // libc waitpid(WNOHANG) returns:
        //   >0  → child exited; we just reaped it.
        //    0  → child still running.
        //   -1  → ECHILD (not our child / already reaped). Treat as
        //         exited so the stale entry doesn't pin the UI.
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        if (rc != 0) {
            log.info("running game pid={d} (tid={d}) exited (waitpid rc={d}, status=0x{x}) — clearing entry", .{
                pid, entry.key_ptr.*, rc, status,
            });
            doomed.append(frame.lib.alloc, .{
                .tid = entry.key_ptr.*,
                .status = @bitCast(status),
                .pid = pid,
            }) catch break;
        }
    }
    for (doomed.items) |d| {
        _ = m.remove(d.tid);
        // Only surface a notification when the exit code is non-zero
        // (a clean exit means the user quit the game normally). The
        // ECHILD case (rc == -1) collapses into status = 0 here so
        // it stays silent too — those are stale entries, not crashes.
        notifyOnAbnormalExit(frame, d.tid, d.status);
    }
}

/// Decode `status` from waitpid and, if it indicates an abnormal
/// exit, push a toast pointing the user at the game and (when a
/// compat scan finds anything) at the Fix Compat button.
fn notifyOnAbnormalExit(frame: *Frame, thread_id: u64, status: u32) void {
    const W = std.posix.W;
    const exited = W.IFEXITED(status);
    const signaled = W.IFSIGNALED(status);
    if (exited and W.EXITSTATUS(status) == 0) return; // clean exit
    if (!exited and !signaled) return; // stopped / continued — not interesting here

    // Find the game name so the toast is intelligible. Fall back to
    // the thread id when the library hasn't been re-queried yet.
    const name = blk: {
        for (frame.games) |*g| if (g.f95_thread_id == thread_id) break :blk g.name;
        break :blk "(unknown game)";
    };

    // Run a compat scan against the game's newest install — if it
    // matches a recipe with `.unfixed` status we mention it inline
    // so the user knows there's something to click.
    var issue_count: usize = 0;
    if (frame.lib.latestInstallForGame(thread_id) catch null) |inst| {
        defer frame.lib.freeInstall(inst);
        if (scanCompatForInstall(frame, &inst.id, inst.install_path)) |issues| {
            defer freeCompatIssues(frame, issues);
            for (issues) |is| if (is.status == .unfixed) {
                issue_count += 1;
            };
        } else |_| {}
    }

    var buf: [320]u8 = undefined;
    const msg = if (exited)
        if (issue_count > 0)
            std.fmt.bufPrint(&buf, "{s}: crashed (exit {d}). {d} compat fix(es) available — click Fix Compat.", .{ name, W.EXITSTATUS(status), issue_count }) catch "Game crashed."
        else
            std.fmt.bufPrint(&buf, "{s}: exited with error (code {d}).", .{ name, W.EXITSTATUS(status) }) catch "Game exited with error."
    else
        std.fmt.bufPrint(&buf, "{s}: killed by signal.", .{name}) catch "Game killed by signal.";
    frame.state.notifyErr(msg);
}

fn freeRunningGames(state: *State, alloc: std.mem.Allocator) void {
    if (state.running_games) |opaque_ptr| {
        const map_ptr: *RunningGamesMap = @ptrCast(@alignCast(opaque_ptr));
        map_ptr.deinit();
        alloc.destroy(map_ptr);
        state.running_games = null;
    }
}

/// Called each guiFrame. For every `.done` job that we haven't already
/// handed off AND that has a real `game_id`, kick off an async worker
/// that SHA-verifies + extracts the archive into
/// `<library_root>/<game_id>/<version>/`. The actual heavy lifting
/// (gigabyte-sized 7z/zip extracts) lives on a detached thread so the
/// UI stays responsive. `.failed` jobs go straight to the next-source
/// fallback (still synchronous — it's just an aria2 RPC + enqueue).
pub fn drainCompletedDownloads(frame: *Frame) void {
    const seen = postInstalledSet(frame);

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
                .game => startPostInstall(frame, job.id, job.game_id, job.expected_sha256) catch |e| {
                    log.warn("post-install start for game-job {d} failed: {s}", .{ job.id, @errorName(e) });
                },
                .mod => postInstallMod(frame, job.id, job.game_id, job.mod_id) catch |e| {
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
                    tryNextSource(frame, job.game_id) catch |e| {
                        log.warn("fallback for game {d} failed: {s}", .{ job.game_id, @errorName(e) });
                    };
                }
            },
            else => unreachable,
        }
    }
}

// ============================================================
//  async post-install (SHA verify + archive extract)
// ============================================================
//
// Why async: large F95 archives are 1–10 GB; the stdlib zip
// extractor can take a minute on these. Doing it inline on the UI
// thread froze the Downloads page for the duration. Now each
// terminal-.done game-job spawns a detached worker that pulls the
// file path from aria2, verifies the hash (when pinned), and runs
// the archive extractor. `drainPostInstall` (called every frame)
// picks up completed workers, does the `installs` DB upsert on the
// UI thread (SQLite isn't multi-thread-write-safe at the app
// layer), and frees the job allocation.

const PostInstallPhase = enum(u8) { pending, done, failed };

pub const PostInstallJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,
    download_job_id: u64,
    game_id: u64,
    /// All inputs heap-owned so the worker can outlive its frame.
    file_path: []u8,
    dest_dir: []u8,
    version: []u8,
    recipe_id: []u8,
    have_recipe: bool,
    expected_sha256: ?[32]u8,
    /// Worker writes one of these on terminal phase. Drain logs it.
    err_name: ?[]const u8 = null,
    /// Extract-progress estimate, 0..100. The poller thread walks the
    /// destination dir every ~250ms while the worker is blocked in
    /// `archive.extract` and writes its best guess here. The std.zip /
    /// std.tar high-level extractors don't expose a per-entry hook, so
    /// we estimate against the archive file size × 2 (uncompressed is
    /// typically ~2× compressed for Ren'Py-style content). Capped at
    /// 99 by the poller; the worker writes 100 once extract returns.
    progress_pct: std.atomic.Value(u8) = .init(0),
    /// Poller's stop flag. Worker flips this to true after extract
    /// finishes (success or fail) so the poll loop exits and joins.
    progress_stop: std.atomic.Value(bool) = .init(false),
    /// Source archive size on disk, captured at startInstall time —
    /// the denominator for the poller's pct estimate. 0 ⇒ stat failed
    /// or unknown; poller bails and the UI sees indeterminate.
    archive_size: u64 = 0,
    /// Provenance for the eventual `installs` row. RPDL downloads
    /// (label starts with `rpdl:`) record `.rpdl`; everything else
    /// (DDL, mirror, recipe-driven HTTP) falls back to `.recipe`.
    /// Manual-archive installs follow their own path
    /// (`startManualInstall`) and never touch this struct.
    source: library.InstallSource = .recipe,
};

const PostInstallJobsList = std.ArrayList(*PostInstallJob);

fn postInstallJobsList(frame: *Frame) *PostInstallJobsList {
    if (frame.state.post_install_jobs) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
    const list_ptr = frame.lib.alloc.create(PostInstallJobsList) catch unreachable;
    list_ptr.* = .empty;
    frame.state.post_install_jobs = list_ptr;
    return list_ptr;
}

pub fn freePostInstallJobs(state: *State, alloc: std.mem.Allocator) void {
    if (state.post_install_jobs) |opaque_ptr| {
        const list_ptr: *PostInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        // Detached workers can't be joined here — graceful shutdown
        // either waits them out via workersBusy/drainPostInstall or
        // hard-exits via std.process.exit(0), which reclaims memory.
        // Any leftover entries we drop are leaked; that's fine on
        // process exit.
        list_ptr.deinit(alloc);
        alloc.destroy(list_ptr);
        state.post_install_jobs = null;
    }
}

/// True iff `download_job_id` is currently being extracted by a
/// detached worker. UI uses this to render "[extracting]" instead
/// of the stale "[done]" pill while the extract is in flight.
pub fn isExtracting(frame: *Frame, download_job_id: u64) bool {
    if (frame.state.post_install_jobs == null) return false;
    const list = postInstallJobsList(frame);
    for (list.items) |pij| {
        if (pij.download_job_id != download_job_id) continue;
        const phase: PostInstallPhase = @enumFromInt(pij.phase.load(.acquire));
        return phase == .pending;
    }
    return false;
}

/// True iff the user has a `.done` (or `.seeding`) download for
/// this game whose archive hasn't been extracted into an `installs`
/// row yet. Used to gate the manual "Install" button on the detail
/// page — auto-install runs on every `.done` transition but skips
/// (or fails) for unknown formats / busted archives / pre-startup
/// crashes mid-extract, leaving the file on disk with no install
/// record. The button gives the user an explicit retry.
pub fn hasDownloadedButNotInstalled(frame: *Frame, thread_id: u64) bool {
    // If an extract worker is already running for this game, the
    // button shouldn't show — the install strip already covers it.
    if (isInstallingForGame(frame, thread_id)) return false;

    // Need at least one terminal-with-archive job whose version isn't
    // already covered by an existing install row.
    var buf: [16]DownloadedEntry = undefined;
    return listDownloadedNotInstalled(frame, thread_id, &buf).len > 0;
}

/// One row in the per-game "downloaded versions, ready to install"
/// list rendered as a dropdown next to the Install button.
pub const DownloadedEntry = struct {
    job_id: u64,
    /// `""` when the Job didn't capture a version (e.g. RPDL torrent
    /// title without a parseable version segment). The UI labels it
    /// "unknown version".
    version: []const u8,
    /// SHA-256 the post-install worker verifies before extract. Null
    /// when the source provider didn't ship one (most cases).
    expected_sha256: ?[32]u8,
};

/// Build the list of "downloaded but not yet installed" entries for
/// this thread, written into `buf`. Returns the populated prefix.
/// Filters out versions that already have an `installs` row so the
/// dropdown doesn't list redundant choices. `buf` cap silently caps
/// the result — 16 is plenty for the realistic case.
pub fn listDownloadedNotInstalled(
    frame: *Frame,
    thread_id: u64,
    buf: []DownloadedEntry,
) []DownloadedEntry {
    if (isInstallingForGame(frame, thread_id)) return buf[0..0];
    // Existing installs — used to suppress versions the user already
    // has, so the dropdown only offers new builds.
    const installs = frame.lib.listInstalls(thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));

    var n: usize = 0;
    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |entry| : ({}) {
        if (n >= buf.len) break;
        const j = entry.value_ptr.*;
        if (j.game_id != thread_id) continue;
        switch (j.status) {
            .done, .seeding => {},
            else => continue,
        }
        const ver_slice: []const u8 = if (j.version) |v| v else "";
        // Skip versions whose install row already exists. Versions
        // compared with `version_mod.equivalent` so "21.0" ≡ "21.0.0".
        var already_installed = false;
        for (installs) |inst| {
            if (ver_slice.len > 0 and version_mod.equivalent(inst.version, ver_slice)) {
                already_installed = true;
                break;
            }
        }
        if (already_installed) continue;
        buf[n] = .{
            .job_id = j.id,
            .version = ver_slice,
            .expected_sha256 = j.expected_sha256,
        };
        n += 1;
    }
    return buf[0..n];
}

/// Kick off the post-install worker for a specific downloaded job.
/// Companion to `startInstallFromDownload` for the multi-version
/// dropdown case. `expected_sha256` (if known) is forwarded so the
/// worker verifies the archive before extracting.
pub fn startInstallFromDownloadJob(
    frame: *Frame,
    thread_id: u64,
    job_id: u64,
    expected_sha256: ?[32]u8,
) void {
    const state = frame.state;
    if (isInstallingForGame(frame, thread_id)) {
        state.setDownloadMsg("install already running for this game");
        return;
    }
    if (state.post_installed) |opaque_ptr| {
        const set_ptr: *PostInstalledSet = @ptrCast(@alignCast(opaque_ptr));
        _ = set_ptr.remove(job_id);
    }
    startPostInstall(frame, job_id, thread_id, expected_sha256) catch |e| {
        var msg_buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&msg_buf, "install start failed: {s}", .{@errorName(e)}) catch "install start failed";
        state.setDownloadMsg(m);
        return;
    };
    state.setDownloadMsg("install started — extracting archive in background");
}

/// Kick off the post-install worker for the game's existing downloaded
/// archive. Picks the first .done/.seeding job tied to `thread_id`
/// and routes it through `startPostInstall`. Also clears the job from
/// the `post_installed` dedupe set so the worker actually fires —
/// `drainCompletedDownloads` would otherwise skip it as "already
/// processed". No-op when nothing matches or a worker is already in
/// flight for this game.
pub fn startInstallFromDownload(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (isInstallingForGame(frame, game.f95_thread_id)) {
        state.setDownloadMsg("install already running for this game");
        return;
    }

    var job_id_opt: ?u64 = null;
    var sha_opt: ?[32]u8 = null;
    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        const j = entry.value_ptr.*;
        if (j.game_id != game.f95_thread_id) continue;
        switch (j.status) {
            .done, .seeding => {
                job_id_opt = j.id;
                sha_opt = j.expected_sha256;
                break;
            },
            else => {},
        }
    }
    const job_id = job_id_opt orelse {
        state.setDownloadMsg("no downloaded archive on record for this game");
        return;
    };

    // Drop the dedupe entry so the worker spawn isn't gated by a
    // prior auto-attempt that bailed (e.g. unknown 7z without
    // p7zip on PATH).
    if (state.post_installed) |opaque_ptr| {
        const set_ptr: *PostInstalledSet = @ptrCast(@alignCast(opaque_ptr));
        _ = set_ptr.remove(job_id);
    }

    startPostInstall(frame, job_id, game.f95_thread_id, sha_opt) catch |e| {
        var msg_buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&msg_buf, "install start failed: {s}", .{@errorName(e)}) catch "install start failed";
        state.setDownloadMsg(m);
        return;
    };
    state.setDownloadMsg("install started — extracting archive in background");
}

/// True iff a post-install worker is currently extracting an archive
/// for this F95 thread id. Detail page uses this to render an
/// "Installing…" progress strip; the strip disappears as soon as
/// `drainPostInstall` clears the worker entry.
pub fn isInstallingForGame(frame: *Frame, thread_id: u64) bool {
    if (frame.state.post_install_jobs) |opaque_ptr| {
        const list: *const PostInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        for (list.items) |pij| {
            if (pij.game_id != thread_id) continue;
            const phase: PostInstallPhase = @enumFromInt(pij.phase.load(.acquire));
            if (phase == .pending) return true;
        }
    }
    if (frame.state.manual_install_jobs) |opaque_ptr| {
        const list: *const ManualInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        for (list.items) |job| {
            if (job.game_id != thread_id) continue;
            const phase: ManualInstallPhase = @enumFromInt(job.phase.load(.acquire));
            if (phase == .pending) return true;
        }
    }
    return false;
}

/// Current extract-progress estimate (0..100) for an in-flight
/// install of this thread, or null when no install is running. The
/// poller writes 0..99 while extracting; the worker stamps 100 right
/// before flipping the phase to `.done`, so the UI can briefly show
/// "100%" before `drainPostInstall` clears the row.
pub fn extractProgressForGame(frame: *Frame, thread_id: u64) ?u8 {
    if (frame.state.post_install_jobs) |opaque_ptr| {
        const list: *const PostInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        for (list.items) |pij| {
            if (pij.game_id != thread_id) continue;
            const phase: PostInstallPhase = @enumFromInt(pij.phase.load(.acquire));
            if (phase != .pending) continue;
            if (pij.archive_size == 0) return null;
            return pij.progress_pct.load(.acquire);
        }
    }
    if (frame.state.manual_install_jobs) |opaque_ptr| {
        const list: *const ManualInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        for (list.items) |job| {
            if (job.game_id != thread_id) continue;
            const phase: ManualInstallPhase = @enumFromInt(job.phase.load(.acquire));
            if (phase != .pending) continue;
            if (job.archive_size == 0) return null;
            return job.progress_pct.load(.acquire);
        }
    }
    return null;
}

/// Background thread that estimates extract progress while the
/// worker is blocked in `archive.extract`. Walks `dest_dir` every
/// ~250 ms summing file sizes; pct = bytes_on_disk / (archive_size *
/// 2). The ×2 fudge factor accounts for the typical ~50%
/// compression ratio of Ren'Py / RPGM archive payloads. Capped at 99
/// so the UI doesn't claim "done" before the worker actually returns.
fn extractProgressPoller(job: *PostInstallJob) void {
    // ×2 is a coarse fit for Ren'Py / RPGM zips. Smaller for raw
    // 7z (already-compressed assets) → progress moves slower but
    // never overshoots, which is the safer failure mode.
    const denom: u64 = @max(1, job.archive_size * 2);
    const tick = std.Io.Duration.fromMilliseconds(250);
    while (!job.progress_stop.load(.acquire)) {
        const bytes = dirSizeBytes(job.io, job.dest_dir);
        const pct_u64: u64 = @min(99, @divTrunc(bytes * 100, denom));
        job.progress_pct.store(@intCast(pct_u64), .release);
        // Nudge dvui so the bar repaints even when no input event
        // arrives — without this the UI sits idle and the % only
        // updates when the user moves the mouse.
        dvui.refresh(job.win, @src(), null);
        std.Io.sleep(job.io, tick, .awake) catch break;
    }
}

/// Recursive directory size — sum of regular file sizes under `path`.
/// Walks via `std.Io.Dir.walk`. Returns 0 on any error (best-effort
/// estimator; the UI handles "unknown" gracefully).
fn dirSizeBytes(io: std.Io, path: []const u8) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var w = dir.walk(std.heap.page_allocator) catch return 0;
    defer w.deinit();
    var total: u64 = 0;
    while (w.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var f = entry.dir.openFile(io, entry.basename, .{ .mode = .read_only }) catch continue;
        defer f.close(io);
        const st = f.stat(io) catch continue;
        total += st.size;
    }
    return total;
}

/// True iff any post-install worker is in flight. Cheap state-only
/// probe (no allocator touch) used by the main loop to decide
/// whether to keep re-rendering for the animated "Installing…"
/// strip on the detail page.
pub fn anyPostInstallActive(state: *const State) bool {
    const opaque_ptr = state.post_install_jobs orelse return false;
    const list_ptr: *const PostInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
    return list_ptr.items.len > 0;
}

/// Spawn the post-install worker for a completed game-job. Resolves
/// everything the worker needs (file path via aria2, recipe lookup,
/// destination dir) up front, then hands off. Failures here surface
/// to the caller; failures inside the worker land on the job's
/// `err_name` field for `drainPostInstall` to log.
fn startPostInstall(
    frame: *Frame,
    download_job_id: u64,
    game_id: u64,
    expected_sha256: ?[32]u8,
) !void {
    const alloc = frame.lib.alloc;

    const daemon = if (frame.dl_mgr.daemon) |*d| d else return error.NoDaemon;
    const gid = frame.dl_mgr.job_gids.get(download_job_id) orelse return error.NoGid;
    const file_path = try daemon.getFiles(gid);
    errdefer alloc.free(file_path);
    if (file_path.len == 0) {
        alloc.free(file_path);
        return error.NoFilePath;
    }

    // Resolve version + recipe_id. Priority order:
    //   1. The version captured on the Job at enqueue time (the
    //      RPDL-derived title version, or the F95 scrape for donor
    //      DDL) — that's "the build the user actually downloaded".
    //   2. The recipe's version (if a recipe exists for this thread).
    //   3. The fallback string "unversioned".
    // All owned slices so the worker has stable memory regardless of
    // frame turnover.
    var version_str: []u8 = try alloc.dupe(u8, "unversioned");
    errdefer alloc.free(version_str);
    var recipe_id: []u8 = try alloc.dupe(u8, "");
    errdefer alloc.free(recipe_id);
    var have_recipe = false;
    if (frame.recipe_repo.findGameByThread(game_id) catch null) |maybe| {
        var pp = maybe;
        defer pp.deinit();
        alloc.free(version_str);
        version_str = try alloc.dupe(u8, pp.recipe.version);
        alloc.free(recipe_id);
        recipe_id = try alloc.dupe(u8, pp.recipe.id);
        have_recipe = true;
    }
    // Override with the Job-captured version when present — that's
    // strictly more specific than the recipe's "what's current"
    // string, especially for RPDL where the title's version segment
    // pins us to a single torrent build. Skip junk values (bare "0",
    // whitespace) so we don't downgrade a good recipe.version with
    // garbage extracted from a title.
    if (frame.dl_mgr.jobs.get(download_job_id)) |j| {
        if (j.version) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "0")) {
                alloc.free(version_str);
                version_str = try alloc.dupe(u8, trimmed);
            }
        }
    }
    // Final fallback: when neither a recipe nor the Job captured a
    // version (e.g. an RPDL torrent whose title didn't expose one
    // despite the more permissive `looksLikeVersion` rules), pull
    // from the F95-scraped game record. RPDL torrents reliably
    // carry SOMETHING parseable in the title, so this branch is
    // mostly for donor DDL on a game we haven't fully synced —
    // still better than literal "unversioned".
    if (std.mem.eql(u8, version_str, "unversioned")) {
        for (frame.games) |*gg| {
            if (gg.f95_thread_id != game_id) continue;
            if (gg.latest_version) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "0")) {
                    alloc.free(version_str);
                    version_str = try alloc.dupe(u8, trimmed);
                }
            }
            break;
        }
    }
    log.info("post-install version resolution: tid={d} → '{s}'", .{ game_id, version_str });

    // Pick the install directory. With ANY known version (Job- or
    // recipe-derived) we land at `<lib>/<tid>/<version>/`; without
    // we fall back to `<lib>/<tid>/`.
    const versioned_dir = have_recipe or !std.mem.eql(u8, version_str, "unversioned");
    var dest_buf: [640]u8 = undefined;
    const dest_dir_local = if (versioned_dir)
        std.fmt.bufPrint(&dest_buf, "{s}/{d}/{s}", .{ frame.info.library_root, game_id, version_str }) catch return error.PathTooLong
    else
        std.fmt.bufPrint(&dest_buf, "{s}/{d}", .{ frame.info.library_root, game_id }) catch return error.PathTooLong;

    if (dirNonEmpty(frame.io, dest_dir_local)) {
        log.info("post-install game-job {d}: {s} already populated, skipping extract", .{ download_job_id, dest_dir_local });
        // Still record the install row — without it the detail
        // page's install dropdown stays empty and the user can't
        // pick or launch this version.
        // Match the provenance sniff used by the worker path below so
        // an early-exit RPDL install also records `.rpdl`.
        const early_source: library.InstallSource = blk: {
            if (frame.dl_mgr.jobs.get(download_job_id)) |j| {
                if (std.mem.startsWith(u8, j.source_url, "rpdl:")) break :blk .rpdl;
            }
            break :blk .recipe;
        };
        doInstallUpsert(frame, game_id, version_str, dest_dir_local, recipe_id, early_source);
        // Refresh the per-frame install-set so the InstallDot flips
        // green immediately — this path bypasses the worker (no
        // drainPostInstall pickup), so without this the UI keeps the
        // stale "not installed" snapshot until the next nav event.
        refreshInstalledSet(frame);
        alloc.free(file_path);
        alloc.free(version_str);
        alloc.free(recipe_id);
        return;
    }

    const dest_dir = try alloc.dupe(u8, dest_dir_local);
    errdefer alloc.free(dest_dir);

    // Stat the archive up-front for the extract-progress poller. Best
    // effort — 0 means "unknown" and the poller stays quiet.
    const archive_size: u64 = blk: {
        var f = std.Io.Dir.cwd().openFile(frame.io, file_path, .{ .mode = .read_only }) catch break :blk 0;
        defer f.close(frame.io);
        const st = f.stat(frame.io) catch break :blk 0;
        break :blk st.size;
    };

    // Provenance: sniff the Job's `source_url` (which is the label we
    // passed to `enqueueTorrent` / `enqueueUrl`). RPDL torrents are
    // labelled `rpdl:<id>`; everything else falls back to `.recipe`.
    const source_kind: library.InstallSource = blk: {
        if (frame.dl_mgr.jobs.get(download_job_id)) |j| {
            if (std.mem.startsWith(u8, j.source_url, "rpdl:")) break :blk .rpdl;
        }
        break :blk .recipe;
    };

    const pij = try alloc.create(PostInstallJob);
    pij.* = .{
        .phase = .init(@intFromEnum(PostInstallPhase.pending)),
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .download_job_id = download_job_id,
        .game_id = game_id,
        .file_path = file_path,
        .dest_dir = dest_dir,
        .version = version_str,
        .recipe_id = recipe_id,
        .have_recipe = have_recipe,
        .expected_sha256 = expected_sha256,
        .archive_size = archive_size,
        .source = source_kind,
    };

    const list = postInstallJobsList(frame);
    try list.append(alloc, pij);

    pij.thr = std.Thread.spawn(.{}, postInstallWorker, .{pij}) catch |e| {
        _ = list.pop();
        alloc.free(file_path);
        alloc.free(dest_dir);
        alloc.free(version_str);
        alloc.free(recipe_id);
        alloc.destroy(pij);
        return e;
    };
    pij.thr.detach();
    log.info("post-install game-job {d}: worker spawned, extracting in background", .{download_job_id});
}

fn postInstallWorker(job: *PostInstallJob) void {
    const fail = struct {
        fn run(j: *PostInstallJob, name: []const u8) void {
            j.err_name = name;
            j.phase.store(@intFromEnum(PostInstallPhase.failed), .release);
            dvui.refresh(j.win, @src(), null);
        }
    }.run;

    if (job.expected_sha256) |want| {
        downloads.verifyFile(job.io, job.file_path, want) catch {
            log.warn("post-install game-job {d}: SHA-256 mismatch for {s}", .{ job.download_job_id, job.file_path });
            fail(job, "HashMismatch");
            return;
        };
    }

    const fmt = downloads.detectFormat(job.file_path);
    if (fmt == .unknown) {
        log.warn("post-install game-job {d}: unknown archive format for {s}", .{ job.download_job_id, job.file_path });
        fail(job, "UnknownFormat");
        return;
    }

    log.info("post-install game-job {d}: extracting {s} → {s}", .{ job.download_job_id, job.file_path, job.dest_dir });

    // Fire up the size-polling thread so the UI's "Installing —
    // extracting" strip shows a moving %. Worker keeps blocking in
    // std.zip/std.tar.extract; the poller watches dest_dir size and
    // writes the estimate into job.progress_pct.
    var poller_thread: ?std.Thread = null;
    if (job.archive_size > 0) {
        poller_thread = std.Thread.spawn(.{}, extractProgressPoller, .{job}) catch null;
    }
    downloads.extract(job.alloc, job.io, job.file_path, job.dest_dir, .{ .strip = 0 }) catch {
        if (poller_thread) |t| {
            job.progress_stop.store(true, .release);
            t.join();
        }
        fail(job, "ExtractionFailed");
        return;
    };
    if (poller_thread) |t| {
        job.progress_stop.store(true, .release);
        t.join();
    }
    job.progress_pct.store(100, .release);
    log.info("post-install game-job {d}: extract finished", .{job.download_job_id});

    job.phase.store(@intFromEnum(PostInstallPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

/// Each guiFrame: scan the in-flight list, do the DB upsert for
/// freshly-finished extractions (must run on the UI thread because
/// SQLite isn't multi-thread-safe at the app layer), then free.
pub fn drainPostInstall(frame: *Frame) void {
    if (frame.state.post_install_jobs == null) return;
    const list = postInstallJobsList(frame);

    var i: usize = 0;
    while (i < list.items.len) {
        const pij = list.items[i];
        const phase: PostInstallPhase = @enumFromInt(pij.phase.load(.acquire));
        if (phase == .pending) {
            i += 1;
            continue;
        }
        if (phase == .done) {
            // Always write the install row — even raw-paste / no-
            // recipe extracts deserve an entry so they land in the
            // detail-page dropdown and the user can launch them.
            doInstallUpsert(frame, pij.game_id, pij.version, pij.dest_dir, pij.recipe_id, pij.source);
            // Refresh the per-frame install-set snapshot so the
            // InstallDot + detail page flip green immediately without
            // waiting for the next navigation event.
            refreshInstalledSet(frame);
            // Auto-convert hook. Only fires when the user opted in
            // AND we have a recipe for this game with a non-`none`
            // convert_linux block (the convert spec needs an engine
            // pin; without a recipe we have nothing to feed Convert).
            if (frame.state.auto_convert) {
                maybeAutoConvert(frame, pij.game_id, pij.dest_dir);
            }
        } else if (phase == .failed) {
            log.warn("post-install game-job {d}: worker failed ({s})", .{ pij.download_job_id, pij.err_name orelse "?" });
        }
        pij.alloc.free(pij.file_path);
        pij.alloc.free(pij.dest_dir);
        pij.alloc.free(pij.version);
        pij.alloc.free(pij.recipe_id);
        pij.alloc.destroy(pij);
        _ = list.swapRemove(i);
        // Don't bump i — swapRemove may have moved a fresh entry
        // into this slot that still needs checking.
    }
}

/// Called after a fresh post-install if `state.auto_convert` is on.
/// Looks up the recipe, builds a ConvertSpec, and runs Convert in
/// place. Surfaces failures via `state.setConvertMsg` — most
/// commonly "no recipe — Convert needs a recipe with convert_linux"
/// when the user has the toggle on but the game has no recipe.
fn maybeAutoConvert(frame: *Frame, game_id: u64, install_dir: []const u8) void {
    const state = frame.state;
    const conv_spec = resolveConvertSpec(frame, install_dir);
    if (conv_spec == .none) {
        state.setConvertMsg("Auto-convert skipped: engine not detected, or game is already Linux-native.");
        return;
    }
    log.info("auto-convert: tid={d} engine={s} → {s}", .{ game_id, @tagName(conv_spec), install_dir });
    frame.convert_svc.convert(install_dir, conv_spec, false) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Auto-convert failed: {s}", .{@errorName(e)}) catch "Auto-convert failed";
        state.setConvertMsg(msg);
        return;
    };
    state.setConvertMsg("Auto-convert: done.");
}

fn doInstallUpsert(
    frame: *Frame,
    game_id: u64,
    version_str: []const u8,
    dest_dir: []const u8,
    recipe_id: []const u8,
    source: library.InstallSource,
) void {
    var id_buf: [36]u8 = undefined;
    generateUuid(frame.io, &id_buf);
    const now = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
    frame.lib.upsertInstall(&.{
        .id = id_buf,
        .game_thread_id = game_id,
        .version = version_str,
        .install_path = dest_dir,
        .recipe_id = recipe_id,
        .installed_at = now_s,
        .source = source,
    }) catch |e| {
        log.warn("installs row for game {d} failed: {s}", .{ game_id, @errorName(e) });
    };
}

// ============================================================
//  manual install (user-supplied archive)
// ============================================================
//
// Mirror of the post-install pipeline but with two differences:
//   - SHA-256 is *computed* during extract, not verified — there's
//     no expected hash for a hand-picked archive.
//   - The Install row carries `source = .manual`, an optional user
//     `name`, and the computed `archive_sha256`. Lets the picker
//     show provenance and disambiguate two installs of the same
//     version.

const ManualInstallPhase = enum(u8) { pending, done, failed };

pub const ManualInstallJob = struct {
    phase: std.atomic.Value(u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    thr: std.Thread,
    game_id: u64,
    /// Source archive on the user's disk — owned. Never modified.
    file_path: []u8,
    /// Destination dir under `<library_root>/<tid>/`. Owned.
    dest_dir: []u8,
    /// Caller-typed version (e.g. "0.20.0"). Owned.
    version: []u8,
    /// Optional user label. Null when the user left the field blank.
    name: ?[]u8,
    /// Filled by the worker after the hash pass. Always populated
    /// once the worker reaches `.done` — let the drainer copy it
    /// into the Install row.
    archive_sha256_hex: [64]u8 = [_]u8{0} ** 64,
    archive_sha256_set: bool = false,
    err_name: ?[]const u8 = null,
    /// Extract-progress estimate (0..100). Same shape as PostInstallJob:
    /// the poller thread walks dest_dir size every ~250ms and writes
    /// the best guess here so the UI can render a moving bar.
    progress_pct: std.atomic.Value(u8) = .init(0),
    /// Poller's stop flag — worker flips this to true after extract
    /// returns so the poll loop exits and joins.
    progress_stop: std.atomic.Value(bool) = .init(false),
    /// Source archive size on disk, captured at startManualInstall
    /// time. 0 ⇒ stat failed; poller bails and the UI shows
    /// indeterminate animation.
    archive_size: u64 = 0,
};

pub const ManualInstallJobsList = std.ArrayList(*ManualInstallJob);

fn manualInstallJobsList(frame: *Frame) *ManualInstallJobsList {
    if (frame.state.manual_install_jobs) |opaque_ptr| {
        return @ptrCast(@alignCast(opaque_ptr));
    }
    const list_ptr = frame.lib.alloc.create(ManualInstallJobsList) catch unreachable;
    list_ptr.* = .empty;
    frame.state.manual_install_jobs = list_ptr;
    return list_ptr;
}

pub fn freeManualInstallJobs(state: *State, alloc: std.mem.Allocator) void {
    if (state.manual_install_jobs) |opaque_ptr| {
        const list_ptr: *ManualInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        list_ptr.deinit(alloc);
        alloc.destroy(list_ptr);
        state.manual_install_jobs = null;
    }
}

/// True iff at least one manual-install worker is still extracting.
/// `workersBusy` consults this so shutdown drains them before tearing
/// down `init.io`.
pub fn manualInstallsRunning(state: *const State) bool {
    if (state.manual_install_jobs) |opaque_ptr| {
        const list_ptr: *const ManualInstallJobsList = @ptrCast(@alignCast(opaque_ptr));
        return list_ptr.items.len > 0;
    }
    return false;
}

/// Validate inputs, choose a destination directory that doesn't
/// collide on disk, and spawn the worker thread. Writes a short
/// status line via `setDownloadMsg` either way — this slot already
/// houses the per-game "install in flight" channel.
pub fn startManualInstall(
    frame: *Frame,
    game_id: u64,
    file_path_in: []const u8,
    version_in: []const u8,
    name_in: []const u8,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // ---- input sanity ----
    const file_path_trim = std.mem.trim(u8, file_path_in, " \t\r\n");
    if (file_path_trim.len == 0) {
        state.setDownloadMsg("Pick an archive file first.");
        return;
    }
    const version_trim = std.mem.trim(u8, version_in, " \t\r\n");
    if (version_trim.len == 0) {
        state.setDownloadMsg("Version is required — type it in or accept the suggestion.");
        return;
    }
    const name_trim = std.mem.trim(u8, name_in, " \t\r\n");

    // Format must be one of the supported archive types. RAR + bz2/xz
    // aren't wired up yet; rejecting up-front beats a worker that
    // fails halfway through.
    const fmt = downloads.detectFormat(file_path_trim);
    if (fmt == .unknown) {
        state.setDownloadMsg("Archive type not recognised (expected .zip / .7z / .tar.gz / .rar).");
        return;
    }

    std.Io.Dir.cwd().access(frame.io, file_path_trim, .{}) catch {
        state.setDownloadMsg("That file doesn't exist or isn't readable.");
        return;
    };

    // ---- destination path ----
    // `<library_root>/<tid>/<version-slug>/`. When the slug collides
    // (a prior install of the same version) we suffix `-2`, `-3`, …
    // up to a small cap so the unique-path constraint never bites.
    var slug_buf: [128]u8 = undefined;
    const slug = slugify(&slug_buf, version_trim) orelse {
        state.setDownloadMsg("Version string normalised to empty — pick a different value.");
        return;
    };
    var dest_buf: [768]u8 = undefined;
    var attempt: u32 = 1;
    const dest_dir_local: []const u8 = while (attempt <= 20) : (attempt += 1) {
        const candidate = if (attempt == 1)
            std.fmt.bufPrint(&dest_buf, "{s}/{d}/{s}", .{ frame.info.library_root, game_id, slug }) catch {
                state.setDownloadMsg("Destination path too long.");
                return;
            }
        else
            std.fmt.bufPrint(&dest_buf, "{s}/{d}/{s}-{d}", .{ frame.info.library_root, game_id, slug, attempt }) catch {
                state.setDownloadMsg("Destination path too long.");
                return;
            };
        if (!dirNonEmpty(frame.io, candidate)) break candidate;
    } else {
        state.setDownloadMsg("Too many existing installs at this version — clean up before adding another.");
        return;
    };

    // ---- own every input string so the worker outlives this frame ----
    const file_path_owned = alloc.dupe(u8, file_path_trim) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    errdefer alloc.free(file_path_owned);
    const dest_dir_owned = alloc.dupe(u8, dest_dir_local) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    errdefer alloc.free(dest_dir_owned);
    const version_owned = alloc.dupe(u8, version_trim) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    errdefer alloc.free(version_owned);
    var name_owned: ?[]u8 = null;
    if (name_trim.len > 0) {
        name_owned = alloc.dupe(u8, name_trim) catch {
            state.setDownloadMsg("Out of memory.");
            return;
        };
    }
    errdefer if (name_owned) |s| alloc.free(s);

    // Stat the archive up-front for the extract-progress poller. 0
    // means "unknown" → poller bails and the UI shows indeterminate.
    const archive_size: u64 = blk: {
        var f = std.Io.Dir.cwd().openFile(frame.io, file_path_trim, .{ .mode = .read_only }) catch break :blk 0;
        defer f.close(frame.io);
        const st = f.stat(frame.io) catch break :blk 0;
        break :blk st.size;
    };

    const job = alloc.create(ManualInstallJob) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    job.* = .{
        .phase = .init(@intFromEnum(ManualInstallPhase.pending)),
        .alloc = alloc,
        .io = frame.io,
        .win = frame.win,
        .thr = undefined,
        .game_id = game_id,
        .file_path = file_path_owned,
        .dest_dir = dest_dir_owned,
        .version = version_owned,
        .name = name_owned,
        .archive_size = archive_size,
    };

    const list = manualInstallJobsList(frame);
    list.append(alloc, job) catch {
        alloc.destroy(job);
        alloc.free(file_path_owned);
        alloc.free(dest_dir_owned);
        alloc.free(version_owned);
        if (name_owned) |s| alloc.free(s);
        state.setDownloadMsg("Out of memory.");
        return;
    };

    job.thr = std.Thread.spawn(.{}, manualInstallWorker, .{job}) catch |e| {
        _ = list.pop();
        alloc.destroy(job);
        alloc.free(file_path_owned);
        alloc.free(dest_dir_owned);
        alloc.free(version_owned);
        if (name_owned) |s| alloc.free(s);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Spawn failed: {s}", .{@errorName(e)}) catch "Spawn failed";
        state.setDownloadMsg(msg);
        return;
    };
    job.thr.detach();
    state.setDownloadMsg("Manual install: hashing + extracting…");
    log.info("manual-install: tid={d} src='{s}' dest='{s}' v='{s}'", .{ game_id, file_path_owned, dest_dir_owned, version_owned });
}

fn manualInstallWorker(job: *ManualInstallJob) void {
    const fail = struct {
        fn run(j: *ManualInstallJob, name: []const u8) void {
            j.err_name = name;
            j.phase.store(@intFromEnum(ManualInstallPhase.failed), .release);
            dvui.refresh(j.win, @src(), null);
        }
    }.run;

    // ---- hash ----
    // Stream the archive through SHA-256 before extract. Cheap on top
    // of the disk read we'd do anyway, and the result lets the
    // diagnostics page identify the file later if the user re-picks
    // a renamed copy.
    var hasher = downloads.Hasher.init();
    {
        var f = std.Io.Dir.cwd().openFile(job.io, job.file_path, .{ .mode = .read_only }) catch {
            fail(job, "OpenFailed");
            return;
        };
        defer f.close(job.io);
        var rd_buf: [64 * 1024]u8 = undefined;
        var fr = f.reader(job.io, &rd_buf);
        while (true) {
            var chunk: [64 * 1024]u8 = undefined;
            const got = fr.interface.readSliceShort(&chunk) catch {
                fail(job, "ReadFailed");
                return;
            };
            if (got == 0) break;
            hasher.update(chunk[0..got]);
        }
    }
    const sha_bytes = hasher.finalize();
    const sha_hex = std.fmt.bytesToHex(sha_bytes, .lower);
    @memcpy(job.archive_sha256_hex[0..], &sha_hex);
    job.archive_sha256_set = true;

    // ---- extract ----
    // Spawn the size-polling thread so the UI's "Installing —
    // extracting" strip shows a moving %. Same trick as the
    // post-install worker.
    var poller_thread: ?std.Thread = null;
    if (job.archive_size > 0) {
        poller_thread = std.Thread.spawn(.{}, manualExtractProgressPoller, .{job}) catch null;
    }
    downloads.extract(job.alloc, job.io, job.file_path, job.dest_dir, .{ .strip = 0 }) catch {
        if (poller_thread) |t| {
            job.progress_stop.store(true, .release);
            t.join();
        }
        fail(job, "ExtractionFailed");
        return;
    };
    if (poller_thread) |t| {
        job.progress_stop.store(true, .release);
        t.join();
    }
    job.progress_pct.store(100, .release);

    job.phase.store(@intFromEnum(ManualInstallPhase.done), .release);
    dvui.refresh(job.win, @src(), null);
}

/// Mirror of `extractProgressPoller` for manual installs. Polls
/// `dest_dir` size against `archive_size * 2` (rough Ren'Py / RPGM
/// compression ratio) and updates `progress_pct` so the UI can
/// render a moving bar.
fn manualExtractProgressPoller(job: *ManualInstallJob) void {
    const denom: u64 = @max(1, job.archive_size * 2);
    const tick = std.Io.Duration.fromMilliseconds(250);
    while (!job.progress_stop.load(.acquire)) {
        const bytes = dirSizeBytes(job.io, job.dest_dir);
        const pct_u64: u64 = @min(99, @divTrunc(bytes * 100, denom));
        job.progress_pct.store(@intCast(pct_u64), .release);
        dvui.refresh(job.win, @src(), null);
        std.Io.sleep(job.io, tick, .awake) catch break;
    }
}

/// UI-thread drain — runs each frame from `ui.runMainLoop`. Picks up
/// terminal manual-install workers, writes the `installs` row, and
/// frees the job.
pub fn drainManualInstall(frame: *Frame) void {
    if (frame.state.manual_install_jobs == null) return;
    const list = manualInstallJobsList(frame);
    const state = frame.state;

    var i: usize = 0;
    while (i < list.items.len) {
        const job = list.items[i];
        const phase: ManualInstallPhase = @enumFromInt(job.phase.load(.acquire));
        if (phase == .pending) {
            i += 1;
            continue;
        }
        if (phase == .done) {
            var id_buf: [36]u8 = undefined;
            generateUuid(frame.io, &id_buf);
            const now = std.Io.Clock.Timestamp.now(frame.io, .real);
            const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
            const sha_opt: ?[64]u8 = if (job.archive_sha256_set) job.archive_sha256_hex else null;
            frame.lib.upsertInstall(&.{
                .id = id_buf,
                .game_thread_id = job.game_id,
                .version = job.version,
                .install_path = job.dest_dir,
                .recipe_id = "",
                .installed_at = now_s,
                .name = job.name,
                .source = .manual,
                .archive_sha256 = sha_opt,
            }) catch |e| {
                log.warn("manual-install: upsert failed: {s}", .{@errorName(e)});
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Manual install: DB upsert failed: {s}", .{@errorName(e)}) catch "Manual install: DB upsert failed";
                state.setDownloadMsg(msg);
            };
            refreshInstalledSet(frame);
            state.setDownloadMsg("Manual install: done.");
            log.info("manual-install: tid={d} v='{s}' installed at '{s}'", .{ job.game_id, job.version, job.dest_dir });
        } else if (phase == .failed) {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "Manual install failed: {s}",
                .{job.err_name orelse "?"},
            ) catch "Manual install failed";
            state.setDownloadMsg(msg);
            log.warn("manual-install: tid={d} failed ({s})", .{ job.game_id, job.err_name orelse "?" });
        }
        job.alloc.free(job.file_path);
        job.alloc.free(job.dest_dir);
        job.alloc.free(job.version);
        if (job.name) |s| job.alloc.free(s);
        job.alloc.destroy(job);
        _ = list.swapRemove(i);
    }
}

/// Replace runs of non-alnum chars with `-`, collapse repeats, drop
/// leading/trailing dashes. Returns null when the result is empty.
fn slugify(buf: []u8, src: []const u8) ?[]const u8 {
    var n: usize = 0;
    var last_was_dash = true;
    for (src) |c| {
        if (n >= buf.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '.') {
            buf[n] = std.ascii.toLower(c);
            n += 1;
            last_was_dash = false;
        } else if (!last_was_dash) {
            buf[n] = '-';
            n += 1;
            last_was_dash = true;
        }
    }
    // strip trailing dash
    while (n > 0 and buf[n - 1] == '-') : (n -= 1) {}
    if (n == 0) return null;
    return buf[0..n];
}

fn postInstallMod(frame: *Frame, job_id: u64, game_id: u64, mod_id_opt: ?u64) !void {
    const alloc = frame.lib.alloc;
    const mod_id = mod_id_opt orelse {
        log.warn("post-install mod-job {d}: no mod_id", .{job_id});
        return;
    };

    // Locate the downloaded archive file via aria2.
    const daemon = if (frame.dl_mgr.daemon) |*d| d else return;
    const gid = frame.dl_mgr.job_gids.get(job_id) orelse return;
    const file_path = try daemon.getFiles(gid);
    defer alloc.free(file_path);
    if (file_path.len == 0) {
        log.warn("post-install mod-job {d}: aria2 returned no file path", .{job_id});
        return;
    }

    // Latest install of the parent game is where we apply.
    const install_opt = frame.lib.latestInstallForGame(game_id) catch null;
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse {
        log.warn("post-install mod-job {d}: game {d} has no install row — apply skipped", .{ job_id, game_id });
        return;
    };

    var mod_id_buf: [32]u8 = undefined;
    const mod_id_str = std.fmt.bufPrint(&mod_id_buf, "{d}", .{mod_id}) catch return;

    // Tracker lives at <game_root>/.f69-mods.json — same place
    // `doInstallMod` writes — so the Mods page sees the post-install
    // result, not a tracker stranded at the wrapper-folder parent.
    const layout = modTrackerLayout(frame.io, alloc, install.install_path) catch |e| {
        log.warn("post-install mod-job {d}: tracker layout failed: {s}", .{ job_id, @errorName(e) });
        return;
    };
    defer freeModTrackerLayout(alloc, layout);

    var tracker = installer_mod.Tracker.init(alloc, frame.io, layout.tracker_path);
    defer tracker.deinit();

    // Re-load existing entries into the tracker so flush rewrites the
    // full file (line-delimited JSON, full overwrite).
    var existing = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer existing.deinit(alloc);
    for (existing.entries) |e| {
        tracker.record(e) catch {};
    }

    log.info("post-install mod-job {d}: applying {s} → {s}", .{ job_id, file_path, layout.game_root });
    installer_mod.applyModArchive(
        alloc,
        frame.io,
        mod_id_str,
        file_path,
        layout.game_root,
        &tracker,
        .{},
    ) catch |e| {
        log.warn("post-install mod-job {d}: apply failed: {s}", .{ job_id, @errorName(e) });
        return;
    };
}

/// On a .failed download for `game_id`, advance the per-game source
/// attempt index and enqueue the next mirror. When the recipe's
/// sources are exhausted, surface a status line and stop.
fn tryNextSource(frame: *Frame, game_id: u64) !void {
    const state = frame.state;
    const m = attemptsMap(frame);
    const next_idx: u32 = (m.get(game_id) orelse 0) + 1;
    m.put(game_id, next_idx) catch {};

    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return;
    var parsed = parsed_opt orelse return;
    defer parsed.deinit();

    const sources = parsed.recipe.sources;
    if (next_idx >= sources.len) {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "All {d} source(s) failed for game {d}", .{ sources.len, game_id }) catch "All sources failed";
        state.setDownloadMsg(msg);
        log.warn("{s}", .{msg});
        return;
    }

    log.info("game {d}: source {d} failed, trying source {d}/{d}", .{ game_id, next_idx - 1, next_idx + 1, sources.len });
    const new_job = try enqueueOneSource(frame, sources[next_idx], .game, game_id, null);
    var ok_buf: [192]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Source {d}/{d} failed; trying next (job {d})", .{ next_idx, sources.len, new_job }) catch "Trying next source";
    state.setDownloadMsg(ok_msg);
}

/// Fill `out` with a random RFC-4122 v4 UUID string. 36 chars
/// `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`.
fn generateUuid(io: std.Io, out: *[36]u8) void {
    var raw: [16]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    // Version 4, variant 1 (10xx) bits.
    raw[6] = (raw[6] & 0x0F) | 0x40;
    raw[8] = (raw[8] & 0x3F) | 0x80;
    _ = std.fmt.bufPrint(out, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],
        raw[6],  raw[7],
        raw[8],  raw[9],
        raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
    }) catch unreachable;
}

fn dirNonEmpty(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |_| return true;
    return false;
}

// ============================================================
//  per-game backup saves — sandbox HOME → dated XDG_DATA_HOME copy
// ============================================================

/// Recursively copy the per-game sandbox HOME to
/// `<XDG_DATA_HOME>/f69/save-backups/<thread_id>/<YYYY-MM-DD-HHMMSS>/`.
/// Defends against the Round-18 footgun where deleting an install dir
/// also wipes the co-located sandbox HOME (Phase 7 installer will
/// decouple these — until then, periodic backups are the mitigation).
pub fn doBackupSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setLaunchMsg("Saves path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().access(frame.io, sandbox_home, .{}) catch {
        state.setLaunchMsg("No sandbox HOME yet — launch the game once to create it.");
        return;
    };

    // Backups live under data_root so they travel with the portable
    // f69 folder. `<data_root>/save-backups/<thread_id>/<unix-seconds>/`.
    const ts = backupTimestamp(frame.io);
    var dest_buf: [768]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/save-backups/{d}/{s}", .{ frame.info.data_root, game.f95_thread_id, ts }) catch {
        state.setLaunchMsg("Backup path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().createDirPath(frame.io, dest) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Backup mkdir failed: {s}", .{@errorName(e)}) catch "Backup mkdir failed";
        state.setLaunchMsg(msg);
        return;
    };

    copyTreePlain(alloc, frame.io, sandbox_home, dest) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Backup copy failed: {s}", .{@errorName(e)}) catch "Backup copy failed";
        state.setLaunchMsg(msg);
        return;
    };

    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Saves backed up to {s}", .{dest}) catch "Saves backed up";
    state.setLaunchMsg(ok_msg);
}

/// Pure-ish: produce a stable "YYYYMMDD-HHMMSS"-shaped string. Uses
/// the host clock; falls back to "unknown" if the clock read fails.
fn backupTimestamp(io: std.Io) [24]u8 {
    var out: [24]u8 = [_]u8{0} ** 24;
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    const secs = @divTrunc(ts.raw.toNanoseconds(), 1_000_000_000);
    _ = std.fmt.bufPrint(&out, "{d}", .{secs}) catch return out;
    return out;
}

/// Simple recursive copy: directories + files, preserves modes, no
/// symlink magic. Backup destinations are user-owned save scratch
/// dirs — a symlink in there would be unusual and copying through is
/// closer to "snapshot what's there now".
fn copyTreePlain(alloc: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8) !void {
    var src_dir = try std.Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true });
    defer src_dir.close(io);
    try std.Io.Dir.cwd().createDirPath(io, dest);

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest, entry.path }) catch return error.PathTooLong;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.path }) catch return error.PathTooLong;

        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, dest_path),
            .file => try copyOneFile(io, src_path, dest_path),
            else => {},
        }
    }
}

fn copyOneFile(io: std.Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        // readSliceShort aliases its source if the destination is the
        // reader's own backing buffer — keep them distinct.
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
    }
    try out_writer.interface.flush();
    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}

// ============================================================
//  per-game open saves — recipe.saves.linux → xdg-open
// ============================================================

/// Resolve the recipe's `saves.linux` path (expanding `$HOME` →
/// per-game sandbox HOME and `$XDG_DATA_HOME` → `<sandbox>/.local/share`)
/// and ask `xdg-open` (or the user's configured browser path) to open
/// it in the system file manager. Falls back to opening the sandbox
/// HOME root when the recipe doesn't pin a saves path.
/// Open the game's install folder in the system file manager. Routes
/// through `xdg-open` like `doOpenSaves`. Latest install row from the
/// DB takes precedence; falls back to `<library_root>/<tid>/` (where
/// no-recipe installs land).
/// Write a new `name` to the install row (or clear it when the new
/// value is all-whitespace). Surfaces the result via
/// `setDownloadMsg` — the picker-label refresh happens for free on
/// the next frame's `listInstalls` call.
pub fn doRenameInstall(frame: *Frame, install_id: [36]u8, new_name: []const u8) void {
    const trimmed = std.mem.trim(u8, new_name, " \t\r\n");
    const name_opt: ?[]const u8 = if (trimmed.len == 0) null else trimmed;
    frame.lib.updateInstallName(install_id[0..], name_opt) catch |e| {
        log.warn("rename install: {s}", .{@errorName(e)});
        frame.state.setDownloadMsg("Rename failed (DB error).");
        return;
    };
    frame.state.setDownloadMsg(if (name_opt == null) "Name cleared." else "Renamed.");
}

/// Delete an install: wipe the on-disk install folder, then drop the
/// DB row. Order matters — if `deleteTree` fails (permissions, mounted
/// volume) we keep the DB row so the user can still see/retry rather
/// than ending up with files but no record.
pub fn doDeleteInstall(frame: *Frame, install_id: [36]u8, install_path: []const u8) void {
    const state = frame.state;

    if (install_path.len > 0) {
        // deleteTree's error set doesn't expose `FileNotFound` (it's
        // already considered success), so we don't special-case it
        // here. Treat NotDir as a "stale entry" caller bug — log and
        // continue to the DB drop.
        std.Io.Dir.cwd().deleteTree(frame.io, install_path) catch |e| {
            var buf: [240]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Delete failed (disk): {s}", .{@errorName(e)}) catch "Delete failed (disk)";
            log.warn("doDeleteInstall: deleteTree({s}) failed: {s}", .{ install_path, @errorName(e) });
            state.setDownloadMsg(msg);
            return;
        };
        log.info("doDeleteInstall: removed install dir {s}", .{install_path});
    }

    frame.lib.deleteInstall(install_id[0..]) catch |e| {
        log.warn("doDeleteInstall: DB row delete failed: {s}", .{@errorName(e)});
        state.setDownloadMsg("Disk gone, DB row delete failed (stale row).");
        return;
    };
    refreshInstalledSet(frame);
    state.setDownloadMsg("Install removed (disk + record).");
}

pub fn doOpenGameFolder(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Honour the detail-page install picker. If the user has picked a
    // specific install in the dropdown, open *that* install's dir
    // rather than always the latest — matches how Launch resolves.
    var fallback_buf: [640]u8 = undefined;
    const installs_owned: ?[]library.Install = frame.lib.listInstalls(game.f95_thread_id) catch null;
    defer if (installs_owned) |list| frame.lib.freeInstalls(list);
    const picked: ?*const library.Install = blk: {
        const list = installs_owned orelse break :blk null;
        if (list.len == 0) break :blk null;
        if (state.detail_picker_install_id) |sel| {
            for (list) |*inst| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
            }
        }
        break :blk &list[0];
    };
    const target: []const u8 = if (picked) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Open folder: path buffer overflow.");
            return;
        };

    std.Io.Dir.cwd().access(frame.io, target, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No install at {s}. Download the game first.", .{target}) catch "No install dir";
        state.setLaunchMsg(msg);
        return;
    };

    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open folder failed: {s}", .{@errorName(e)}) catch "Open folder failed";
        state.setLaunchMsg(msg);
        return;
    };
    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Opened {s}", .{target}) catch "Opened folder";
    state.setLaunchMsg(ok_msg);
}

pub fn doOpenSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var sandbox_home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&sandbox_home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setConvertMsg("Saves path buffer overflow.");
        return;
    };

    // Recipe-pinned save paths were retired — the `saves` block on
    // GameRecipe is gone. Engine-derived defaults (Ren'Py:
    // `$XDG_DATA_HOME/RenPy/...`; RPGM: `<install>/www/save/`) will
    // land later. For now we fall back to the sandbox HOME itself
    // so the user can navigate manually. `game` stays in scope for
    // the future engine-derive path.
    const target = sandbox_home;
    std.Io.Dir.cwd().createDirPath(frame.io, target) catch {}; // best-effort

    // Spawn xdg-open detached so the UI doesn't block on the file
    // manager startup.
    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open saves failed: {s}", .{@errorName(e)}) catch "Open saves failed";
        state.setConvertMsg(msg);
        return;
    };

    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Opened {s}", .{target}) catch "Opened saves";
    state.setConvertMsg(ok_msg);
}

/// Pure. Expand `$HOME` and `$XDG_DATA_HOME` in the recipe's saves
/// template against the per-game sandbox HOME. Allocator-owned result.
pub fn expandSavesPath(alloc: std.mem.Allocator, tmpl: []const u8, sandbox_home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < tmpl.len) {
        if (std.mem.startsWith(u8, tmpl[i..], "$XDG_DATA_HOME")) {
            try out.appendSlice(alloc, sandbox_home);
            try out.appendSlice(alloc, "/.local/share");
            i += "$XDG_DATA_HOME".len;
        } else if (std.mem.startsWith(u8, tmpl[i..], "$HOME")) {
            try out.appendSlice(alloc, sandbox_home);
            i += "$HOME".len;
        } else {
            try out.append(alloc, tmpl[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn spawnXdgOpen(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const path_owned = try alloc.dupe(u8, path);
    // The reaper thread takes ownership of `path_owned` + the child
    // handle; UI thread returns immediately without blocking on
    // xdg-open's exit. Without this the f69 main thread sat on
    // `child.wait` for the few ms xdg-open lives, and the launched
    // file manager / browser appeared as f69's child in `ps`.
    const ReaperArgs = struct { io: std.Io, alloc: std.mem.Allocator, path: []u8 };
    const args_ptr = alloc.create(ReaperArgs) catch {
        alloc.free(path_owned);
        return error.OutOfMemory;
    };
    args_ptr.* = .{ .io = io, .alloc = alloc, .path = path_owned };

    const ReaperFn = struct {
        fn run(a: *ReaperArgs) void {
            defer a.alloc.free(a.path);
            defer a.alloc.destroy(a);
            var child = std.process.spawn(a.io, .{
                .argv = &.{ "xdg-open", a.path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return;
            _ = child.wait(a.io) catch {};
        }
    };
    const thr = std.Thread.spawn(.{}, ReaperFn.run, .{args_ptr}) catch |e| {
        alloc.free(args_ptr.path);
        alloc.destroy(args_ptr);
        return e;
    };
    thr.detach();
}

const testing = std.testing;

test "expandSavesPath: $HOME substitution" {
    const got = try expandSavesPath(testing.allocator, "$HOME/.renpy/save", "/games/14014/.f69-home");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/games/14014/.f69-home/.renpy/save", got);
}

test "expandSavesPath: $XDG_DATA_HOME substitution" {
    const got = try expandSavesPath(testing.allocator, "$XDG_DATA_HOME/RenPy/SummertimeSaga-1454697768", "/games/14014/.f69-home");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/games/14014/.f69-home/.local/share/RenPy/SummertimeSaga-1454697768", got);
}

test "expandSavesPath: literal path passes through" {
    const got = try expandSavesPath(testing.allocator, "/abs/path", "/sandbox");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/abs/path", got);
}

test "expandSavesPath: $XDG_DATA_HOME takes precedence over $HOME prefix" {
    // Both markers start with `$`; the longer one must win at any
    // given position.
    const got = try expandSavesPath(testing.allocator, "$XDG_DATA_HOME/x", "/sb");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/sb/.local/share/x", got);
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
    if (state.post_installed) |opaque_ptr| {
        const set_ptr: *PostInstalledSet = @ptrCast(@alignCast(opaque_ptr));
        set_ptr.deinit();
        alloc.destroy(set_ptr);
        state.post_installed = null;
    }
    if (state.download_attempts) |opaque_ptr| {
        const map_ptr: *AttemptsMap = @ptrCast(@alignCast(opaque_ptr));
        map_ptr.deinit();
        alloc.destroy(map_ptr);
        state.download_attempts = null;
    }
    freeRunningGames(state, alloc);
}
