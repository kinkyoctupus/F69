// Sync engine + image pipeline.
//
//   - sync-recap stack (end-of-batch "what changed" popup)
//   - per-game `syncGame` + `syncWorker` worker-thread offload
//   - on-disk image transcoding (cover + screenshots + thumbs)
//   - slide / thumb / cover read-through caches
//   - sync-all queue + `advanceSyncQueue` chaining
//   - cancelSync / cancelImageQueue
//   - phase-2 background screenshot worker (image queue)
//   - cover-cache disk LRU + cover pre-warmer
//
// External callers see this through the actions.zig re-export wall.

const std = @import("std");
const atomic_io = @import("util_atomic_io");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const f95 = @import("f95");
const dvui = @import("dvui");
const image = @import("image");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const common = @import("common.zig");
const downloads_mod = @import("downloads.zig");
const installer_mod = @import("installer.zig");
const launch_mod = @import("launch.zig");
const mods_act = @import("mods.zig");

const Frame = types.Frame;
const State = types.State;

const SyncRecapList = owned_types.SyncRecapList;
const ImageJobPhase = owned_types.ImageJobPhase;

pub const SyncRecapEntry = owned_types.SyncRecapEntry;
pub const SyncPayload = owned_types.SyncPayload;
pub const SyncJob = owned_types.SyncJob;
pub const ImageJob = owned_types.ImageJob;

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

fn syncRecapList(frame: *Frame) ?*SyncRecapList {
    if (frame.state.sync_recap) |list_ptr| return list_ptr;
    const list_ptr = frame.lib.alloc.create(SyncRecapList) catch return null;
    list_ptr.* = .empty;
    frame.state.sync_recap = list_ptr;
    return list_ptr;
}

/// Read-only accessor for the UI — returns `&.{}` when the recap
/// hasn't been touched yet.
pub fn syncRecapEntries(state: *const State) []const SyncRecapEntry {
    const list_ptr = state.sync_recap orelse return &.{};
    return list_ptr.items;
}

/// Free every entry's owned strings + the list itself. Idempotent.
pub fn freeSyncRecap(state: *State, alloc: std.mem.Allocator) void {
    if (state.sync_recap) |list_ptr| {
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
    if (frame.state.sync_recap) |list_ptr| {
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
    const list = syncRecapList(frame) orelse {
        alloc.free(name_dup);
        alloc.free(old_dup);
        alloc.free(new_dup);
        return;
    };
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
    const list_ptr = state.sync_recap orelse return;
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
    const url_owned = alloc.dupe(u8, url_slice) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: url dup");
        return;
    };
    const covers_owned = alloc.dupe(u8, frame.info.covers_dir) catch {
        alloc.free(url_owned);
        state.sync_status = .err;
        state.setSyncMsg("internal error: covers_dir dup");
        return;
    };

    _ = job_mod.spawnJob(
        SyncPayload,
        syncWorker,
        alloc,
        frame.win,
        .{
            .thread_id = game.f95_thread_id,
            .url = url_owned,
            .f95_svc = frame.f95_svc,
            .covers_dir = covers_owned,
            .io = frame.io,
            .progress_done = .init(0),
            .progress_total = .init(1),
        },
        &state.pending_sync,
    ) catch {
        alloc.free(covers_owned);
        alloc.free(url_owned);
        state.sync_status = .err;
        state.setSyncMsg("internal error: job alloc/spawn");
        return;
    };

    state.sync_status = .running;
    // Banner shows the active game's name + queue progress. If the
    // user adds another game while this one's running, the queue
    // The banner reads `state.currentSyncName()` and the queue
    // counters directly — no need to bake them into `sync_msg`. Clear
    // any lingering completion message so a stale "sync-all complete"
    // doesn't sit on top of the in-progress banner.
    state.setCurrentSyncName(game.name);
    state.sync_msg.clear();
    state.sync_status = .running;
}

/// Wall-clock milliseconds via the Zig 0.16 `std.Io.Clock` API.
/// Hides the verbose call site so the timing log macros stay tidy.
fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

fn syncWorker(job: *SyncJob) void {
    const p = &job.payload;
    // Coarse wall-clock timing so the log shows where the seconds go.
    // Phase boundaries: HTML fetch+parse → cover fetch → screenshots.
    // The image phases dominate when a thread has many screenshots
    // because each GET is rate-limited at the F95 client level.
    const t_start = nowMs(p.io);
    const scraped = p.f95_svc.scrapeThread(p.url) catch |e| {
        // HTTP 404 from F95 means the thread is gone — dev took it
        // down, mod nuked it, whatever. We don't want to error out
        // (the user would have to dismiss a banner per orphaned
        // game during a sync-all). Instead flag the job and let
        // drainSync flip the row's dev_status to .orphaned.
        if (e == f95.errors.Error.NotFound) {
            log.info("sync tid={d} ORPHANED (F95 returned 404) elapsed_ms={d}", .{ p.thread_id, nowMs(p.io) - t_start });
            p.orphaned = true;
            job.markDone();
            return;
        }
        log.info("sync tid={d} FAIL scrape elapsed_ms={d} err={s}", .{ p.thread_id, nowMs(p.io) - t_start, @errorName(e) });
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    const t_after_scrape = nowMs(p.io);
    log.info(
        "sync tid={d} scrape_ms={d} name={?s} engine_str={?s} version={?s} developer={?s}",
        .{ p.thread_id, t_after_scrape - t_start, scraped.name, scraped.engine_str, scraped.version, scraped.developer },
    );

    // ScrapedThread strings are job.alloc-owned; we transfer ownership
    // onto the SyncJob fields, drainSync copies into Library.
    p.name = if (scraped.name) |n| @constCast(n) else null;
    p.version = if (scraped.version) |v| @constCast(v) else null;
    p.developer = if (scraped.developer) |d| @constCast(d) else null;
    p.rating = scraped.rating;
    p.vote_count = scraped.vote_count;
    if (scraped.engine_str) |e| {
        p.engine = library.Engine.fromBracket(e);
        job.alloc.free(e);
    }
    if (scraped.dev_status_str) |s| {
        p.dev_status = library.DevStatus.fromBracket(s);
        job.alloc.free(s);
    }
    if (scraped.last_updated_at) |ts| p.last_updated_at = ts;
    if (scraped.thread_info_md) |t| p.thread_info_md = @constCast(t);
    if (scraped.censored_str) |c| {
        p.censored = library.CensoredState.fromText(c);
        job.alloc.free(c);
    }
    if (scraped.tags.len > 0) p.tags = scraped.tags;
    if (scraped.screenshots.len > 0) p.screenshots = scraped.screenshots;
    if (scraped.description_md) |d| p.description_md = @constCast(d);
    if (scraped.changelog_md) |c| p.changelog_md = @constCast(c);
    if (scraped.reviews_md) |r| p.reviews_md = @constCast(r);
    if (scraped.downloads_md) |d| p.downloads_md = @constCast(d);
    if (scraped.download_links.len > 0) {
        p.download_links = encodeDownloadLinks(job.alloc, scraped.download_links) catch null;
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
        const cp = std.fmt.bufPrint(&cover_path_buf, "{s}/{d}", .{ p.covers_dir, p.thread_id }) catch break :blk false;
        break :blk fileExists(p.io, cp);
    } else true;

    const t_before_images = nowMs(p.io);
    if (!want_cover or cover_present) {
        // Nothing to fetch in this worker. Leave `progress_total` at
        // its initial 1 so the banner's sub-progress doesn't flicker.
        if (scraped.cover_url) |cu| job.alloc.free(cu);
        log.info(
            "sync tid={d} cover_cached={any} shots_deferred={d}",
            .{ p.thread_id, want_cover and cover_present, scraped.screenshots.len },
        );
    } else {
        // Cover work coming up — publish the planned step count.
        p.progress_total.store(2, .release);
        p.progress_done.store(1, .release);
        dvui.refresh(job.win, @src(), null);
        if (scraped.cover_url) |cu| {
            defer job.alloc.free(cu);
            if (job.cancelRequested()) {
                log.info("sync tid={d} cancelled before cover fetch", .{p.thread_id});
            } else {
                const t_c0 = nowMs(p.io);
                if (fetchAndWriteCover(job, cu)) {
                    p.cover_updated = true;
                    log.info("sync tid={d} cover_ms={d}", .{ p.thread_id, nowMs(p.io) - t_c0 });
                } else |_| {
                    log.info("sync tid={d} cover FAIL elapsed_ms={d}", .{ p.thread_id, nowMs(p.io) - t_c0 });
                }
                _ = p.progress_done.fetchAdd(1, .release);
                dvui.refresh(job.win, @src(), null);
            }
        }
    }

    // If the user clicked Cancel, mark the job failed so drainSync
    // skips the applyScrape write — the scraped data is still owned
    // by job and will be freed via cleanup(). This keeps cancellation
    // observable to the UI without partial-row commits.
    if (job.cancelRequested()) {
        log.info("sync tid={d} TOTAL_ms={d} CANCELLED", .{ p.thread_id, nowMs(p.io) - t_start });
        p.err_name = "Cancelled";
        job.markFailed();
        return;
    }

    log.info(
        "sync tid={d} TOTAL_ms={d} scrape_ms={d} images_ms={d}",
        .{ p.thread_id, nowMs(p.io) - t_start, t_after_scrape - t_start, nowMs(p.io) - t_before_images },
    );
    job.markDone();
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
    const p = &job.payload;
    const raw = try p.f95_svc.client.getImage(cover_url);
    defer job.alloc.free(raw);
    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("cover transcode failed ({s}): {s}", .{ @errorName(e), cover_url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try coverPath(&path_buf, p.covers_dir, p.thread_id);
    try writeAtomic(p.io, path, ready);

    // Also write the thumbnail. Failure here is non-fatal — the lazy
    // path in `thumbBytes` will regenerate from the full-size file.
    writeThumbBeside(job.alloc, p.io, path, ready) catch |e| {
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
    const p = &job.payload;
    const raw = try p.f95_svc.client.getImage(url);
    defer job.alloc.free(raw);
    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("screenshot {d} transcode failed ({s}): {s}", .{ idx, @errorName(e), url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ p.covers_dir, p.thread_id, idx });
    try writeAtomic(p.io, path, ready);

    writeThumbBeside(job.alloc, p.io, path, ready) catch |e| {
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
    // Snapshot the slot before draining so we can do the post-drain
    // cache invalidation + queue advance independent of the carrier
    // (drainBackgroundJob destroys it via the .done/.failed handler).
    const slot_was_set = state.pending_sync != null;
    job_mod.drainBackgroundJob(
        SyncPayload,
        onSyncDone,
        onSyncFailed,
        frame,
        &state.pending_sync,
    );
    if (!slot_was_set) return;
    if (state.pending_sync != null) return; // worker still pending — no-op
    // Worker reached terminal phase and the carrier is freed. Clear
    // the active-sync banner and advance the queue if a batch is in
    // flight. (cancelSync nulls sync_queue, so a cancelled run won't
    // advance — matches the previous behaviour.)
    state.active_sync_name.clear();
    if (state.sync_queue != null) advanceSyncQueue(frame);
}

/// Drop any cover/slide/thumb caches keyed on this job's thread id
/// before transferring ownership back to the UI thread. Runs from
/// both onSyncDone and onSyncFailed so cancelled / failed jobs that
/// still wrote a fresh cover (cover_updated) don't leave stale bytes
/// in the cache.
fn invalidateCachesForJob(frame: *Frame, job: *SyncJob) void {
    const state = frame.state;
    const p = &job.payload;
    if (p.cover_updated) {
        invalidateCover(state, frame.lib.alloc, p.thread_id);
    }
    if (state.slide_cache_thread == p.thread_id) {
        freeSlideCache(state, frame.lib.alloc);
    }
    if (state.thumb_cache_thread == p.thread_id) {
        freeThumbCache(state, frame.lib.alloc);
    }
}

/// Free every payload-owned heap allocation. Called from both
/// handlers right before drainBackgroundJob destroys the carrier.
/// Idempotent — every field is null-checked.
fn freeSyncPayload(job: *SyncJob) void {
    const p = &job.payload;
    job.alloc.free(p.url);
    job.alloc.free(p.covers_dir);
    if (p.name) |n| job.alloc.free(n);
    if (p.version) |v| job.alloc.free(v);
    if (p.developer) |d| job.alloc.free(d);
    if (p.tags) |ts| {
        for (ts) |t| job.alloc.free(t);
        job.alloc.free(ts);
    }
    if (p.screenshots) |ss| {
        for (ss) |x| job.alloc.free(x);
        job.alloc.free(ss);
    }
    if (p.description_md) |d| job.alloc.free(d);
    if (p.changelog_md) |c| job.alloc.free(c);
    if (p.reviews_md) |r| job.alloc.free(r);
    if (p.downloads_md) |d| job.alloc.free(d);
    if (p.thread_info_md) |t| job.alloc.free(t);
    if (p.download_links) |dl| {
        for (dl) |d| job.alloc.free(d);
        job.alloc.free(dl);
    }
}

fn onSyncFailed(frame: *Frame, job: *SyncJob) void {
    const state = frame.state;
    const p = &job.payload;
    invalidateCachesForJob(frame, job);
    // User cancellation is not an error path — silently clean up
    // and DO NOT chain into the rest of the queue (cancelSync
    // already freed it). Real failures still surface a banner.
    const was_cancelled = p.err_name != null and std.mem.eql(u8, p.err_name.?, "Cancelled");
    if (was_cancelled) {
        state.sync_status = .idle;
        state.sync_msg.clear();
        freeSyncPayload(job);
        return;
    }
    state.sync_status = .err;
    const friendly = common.friendlyError(p.err_name orelse "?");
    var emsg: [128]u8 = undefined;
    const m = if (state.sync_queue) |_|
        std.fmt.bufPrint(&emsg, "sync-all: {d}/{d} — failed: {s}", .{ state.sync_queue_started, state.sync_queue_total, friendly }) catch "sync-all error"
    else
        std.fmt.bufPrint(&emsg, "scrape failed: {s}", .{friendly}) catch "scrape failed";
    state.setSyncMsg(m);
    freeSyncPayload(job);
}

fn onSyncDone(frame: *Frame, job: *SyncJob) void {
    const state = frame.state;
    const p = &job.payload;
    invalidateCachesForJob(frame, job);

    // .done — find the row by thread_id and apply numeric fields.
    var target: ?*library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == p.thread_id) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        state.sync_status = .err;
        state.setSyncMsg("synced game no longer in list");
        freeSyncPayload(job);
        return;
    };

    const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();

    // Orphaned outcome: F95 returned 404 for this thread. Don't
    // clobber the row's good data with the empty scrape — only flip
    // dev_status + bump last_scraped_at so the badge updates and the
    // user can see the row was checked.
    if (p.orphaned) {
        frame.lib.applyScrape(game, .{
            .dev_status = .orphaned,
            .last_scraped_at = now_s,
        }) catch |e| {
            state.sync_status = .err;
            var emsg: [80]u8 = undefined;
            const m = std.fmt.bufPrint(&emsg, "DB write failed: {s}", .{@errorName(e)}) catch "DB write failed";
            state.setSyncMsg(m);
            freeSyncPayload(job);
            return;
        };
        state.sync_status = .ok;
        state.sort_applied_column = null;
        state.sort_applied_dir = null;
        var orph_buf: [128]u8 = undefined;
        const m = if (state.sync_queue) |_|
            std.fmt.bufPrint(&orph_buf, "sync-all: {d}/{d} — orphaned (thread gone from F95)", .{ state.sync_queue_started, state.sync_queue_total }) catch "orphaned"
        else
            std.fmt.bufPrint(&orph_buf, "orphaned — F95 returned 404 for thread {d}", .{p.thread_id}) catch "orphaned";
        state.setSyncMsg(m);
        freeSyncPayload(job);
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
        .name = p.name,
        .version = p.version,
        .developer = p.developer,
        .rating = p.rating,
        .vote_count = p.vote_count,
        .engine = p.engine,
        .dev_status = p.dev_status,
        .last_updated_at = p.last_updated_at,
        .thread_info_md = p.thread_info_md,
        .censored = p.censored,
        .tags = p.tags,
        .screenshots = p.screenshots,
        .description_md = p.description_md,
        .changelog_md = p.changelog_md,
        .reviews_md = p.reviews_md,
        .download_links = p.download_links,
        .downloads_md = p.downloads_md,
        .last_scraped_at = now_s,
    }) catch |e| {
        state.sync_status = .err;
        var emsg: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "DB write failed: {s}", .{@errorName(e)}) catch "DB write failed";
        state.setSyncMsg(m);
        freeSyncPayload(job);
        return;
    };

    // After a successful scrape we have everything needed to author
    // the canonical game recipe (name + version + engine + thread).
    // Auto-save it idempotently so the Recipe tab — which we're
    // about to retire — never becomes a precondition for anything
    // else (mods, downloads, sharing).
    mods_act.ensureGameRecipeOnDisk(frame, game) catch |e| {
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
                    if (launch_mod.shouldAutoUpdate(state, game) and
                        !downloads_mod.hasActiveDownloadForGame(frame, game.f95_thread_id) and
                        !installer_mod.isInstallingForGame(frame, game.f95_thread_id) and
                        launch_mod.recipeReadyForAutoUpdate(frame, game.f95_thread_id, new_v))
                    {
                        log.info("auto-update: tid={d} '{s}' {s} -> {s}", .{ game.f95_thread_id, game.name, old_v, new_v });
                        downloads_mod.doDownloadGame(frame, game);
                        markRecapAutoDownloaded(state, game.f95_thread_id);
                    } else if (launch_mod.shouldAutoUpdate(state, game) and
                        !launch_mod.hasAutoFetchableSource(frame, game.f95_thread_id))
                    {
                        log.info("auto-update: tid={d} skipped — no auto-fetchable recipe source", .{game.f95_thread_id});
                    } else if (launch_mod.shouldAutoUpdate(state, game) and
                        launch_mod.hasAutoFetchableSource(frame, game.f95_thread_id))
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

    freeSyncPayload(job);
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


/// Cancel the running sync (if any) and drop the rest of the batch
/// queue. Worker observes `job.cancel` between phases and exits as
/// `Cancelled`. UI thread frees the queue immediately; drainSync's
/// cleanup will run when the worker reports back.
pub fn cancelSync(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_sync) |j| {
        j.cancel.store(true, .release);
        log.info("cancelSync: flag set on tid={d}", .{j.payload.thread_id});
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
    if (state.image_active) |job| {
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
            state.image_active_name.clear();
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
        state.image_active_name.clear();
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

