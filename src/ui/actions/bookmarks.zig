// Bookmarks pull (worker thread + drain).
//
// Walks `/watched/threads` paginated under the user's session cookie,
// extracts every thread id, then bulk-inserts via
// `Library.insertIfMissing`. New rows show up as `(unsynced)`; the
// existing post-import auto-sync then scrapes each one.
//
// Network walk runs on a worker so the UI keeps drawing during the
// (rate-limited) pagination — 100 bookmarks across 5 pages = ~7.5s.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const dvui = @import("dvui");
const library = @import("library");
const f95 = @import("f95");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const common = @import("common.zig");

const Frame = types.Frame;
const State = types.State;

pub const BookmarksPayload = owned_types.BookmarksPayload;
pub const BookmarksJob = owned_types.BookmarksJob;

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

/// `on_page` callback — runs on the worker. Wakes the dvui loop AND
/// dupes this page's entries onto the job's staging buffer so the UI
/// thread can insert them mid-pull.
fn bookmarksOnPage(ctx: ?*anyopaque, page_entries: []const f95.BookmarkEntry) void {
    const win_or_job = ctx orelse return;
    const job: *BookmarksJob = @ptrCast(@alignCast(win_or_job));
    const p = &job.payload;

    if (page_entries.len > 0) {
        const io = p.f95_svc.client.io;
        p.staged_mu.lockUncancelable(io);
        defer p.staged_mu.unlock(io);
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
            p.staged.append(job.alloc, .{
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
    const job = frame.state.pending_bookmarks orelse return;
    job.cancel.store(true, .release);
    log.info("cancelBookmarks: cancel flag set", .{});
}

pub fn startPullBookmarks(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_bookmarks != null) return;
    if (!frame.f95_svc.client.hasCookie()) {
        state.setBookmarksMsg("not logged in — log in first");
        return;
    }
    log.info("startPullBookmarks: walking watched threads", .{});

    _ = job_mod.spawnJob(
        BookmarksPayload,
        bookmarksWorker,
        frame.lib.alloc,
        frame.win,
        .{ .f95_svc = frame.f95_svc },
        &state.pending_bookmarks,
    ) catch {
        state.setBookmarksMsg("internal error: job alloc/spawn");
        return;
    };

    state.setBookmarksMsg("fetching watched threads…");
}

fn bookmarksWorker(job: *BookmarksJob) void {
    const p = &job.payload;
    const entries = p.f95_svc.fetchBookmarks(.{
        .current = &p.progress_current,
        .total = &p.progress_total,
        .on_page = bookmarksOnPage,
        // ctx is the job itself now — bookmarksOnPage needs access to
        // the staging buffer + window, both on `job`.
        .ctx = job,
        .cancel = &job.cancel,
    }) catch |e| {
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    // Transfer ownership of the entries slice (and its inner strings)
    // onto the job. drainBookmarks frees via `f95.bookmarks.freeAll`
    // after the bulk insert.
    p.entries = entries;
    job.markDone();
}

/// Per-frame drain. On done: walk the ids and `insertIfMissing` each;
/// trigger a reload + auto-sync-all so the new rows populate without
/// another click. While pending, mirror the worker's progress atomics
/// into `State` so the progress bar widget can read plain ints.
pub fn drainBookmarks(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_bookmarks) |job| {
        // Always mirror progress so the widget sees fresh numbers without
        // having to know about the BookmarksPayload layout.
        state.bookmarks_progress_current = job.payload.progress_current.load(.acquire);
        state.bookmarks_progress_total = job.payload.progress_total.load(.acquire);

        // **Live drain**: the worker's `bookmarksOnPage` callback has been
        // staging this pull's entries since page 1. Insert any newly-
        // staged rows into the library every frame — the user sees the
        // grid populate as pages come in, not all at once on .done.
        drainStagedBookmarks(frame, job);
    }

    job_mod.drainBackgroundJob(
        BookmarksPayload,
        onBookmarksDone,
        onBookmarksFailed,
        frame,
        &state.pending_bookmarks,
    );
}

fn freeBookmarksPayload(job: *BookmarksJob) void {
    const p = &job.payload;
    if (p.entries) |entries| f95.bookmarks.freeAll(job.alloc, entries);
    // Free anything still in the staged buffer (already-inserted
    // copies — we duped on stage; the worker's `entries` slice is
    // independent and gets freed via freeAll above).
    for (p.staged.items) |e| {
        job.alloc.free(e.thread_id);
        job.alloc.free(e.title);
        job.alloc.free(e.url);
    }
    p.staged.deinit(job.alloc);
}

fn onBookmarksFailed(frame: *Frame, job: *BookmarksJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer {
        freeBookmarksPayload(job);
        state.bookmarks_progress_current = 0;
        state.bookmarks_progress_total = 0;
    }
    // User-initiated cancel is not an error — just silence the
    // banner. The cancel flag is set by `cancelBookmarks`; the
    // worker propagates it as a `Cancelled` error. Either signal
    // counts as "intended stop".
    const user_cancelled = job.cancel.load(.acquire) or
        (p.err_name != null and std.mem.eql(u8, p.err_name.?, "Cancelled"));
    if (user_cancelled) {
        state.bookmarks_msg.clear();
        return;
    }
    const friendly = common.friendlyError(p.err_name orelse "?");
    var emsg: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "pull failed: {s}", .{friendly}) catch "pull failed";
    state.setBookmarksMsg(m);
}

fn onBookmarksDone(frame: *Frame, job: *BookmarksJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer {
        freeBookmarksPayload(job);
        state.bookmarks_progress_current = 0;
        state.bookmarks_progress_total = 0;
    }

    // Final summary: counters were maintained during live drain.
    const imported = p.live_inserted.load(.acquire);
    const skipped = p.live_skipped.load(.acquire);
    const dropped_nongame = p.live_dropped.load(.acquire);
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
    const p = &job.payload;

    // Hold staged_mu across the entire insert loop. Earlier shape
    // grabbed a slice header under the lock and iterated outside —
    // but the slice points into `p.staged.items`'s backing buffer,
    // and a worker append between unlock and the for-loop could
    // realloc + invalidate it. Worker appends ~50 entries per page
    // and blocks at most one drain (< 1 ms); holding the lock is
    // cheaper than copying entries by value.
    p.staged_mu.lockUncancelable(frame.io);
    defer p.staged_mu.unlock(frame.io);
    const new_count = p.staged.items.len - p.staged_drained;
    if (new_count == 0) return;
    const new_slice = p.staged.items[p.staged_drained .. p.staged_drained + new_count];
    p.staged_drained += new_count;

    var any_inserted = false;
    for (new_slice) |e| {
        const tid = std.fmt.parseInt(u64, e.thread_id, 10) catch {
            _ = p.live_skipped.fetchAdd(1, .release);
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
            _ = p.live_dropped.fetchAdd(1, .release);
            continue;
        }

        const g = library.Game{
            .f95_thread_id = tid,
            .name = name,
            .developer = parts.developer,
            .latest_version = parts.version,
        };
        const inserted = frame.lib.insertIfMissing(&g) catch {
            _ = p.live_skipped.fetchAdd(1, .release);
            continue;
        };
        if (inserted) {
            _ = p.live_inserted.fetchAdd(1, .release);
            any_inserted = true;
        } else {
            _ = p.live_skipped.fetchAdd(1, .release);
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
