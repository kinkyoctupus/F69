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
const common = @import("common.zig");

const Frame = types.Frame;
const State = types.State;

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

pub const BookmarksJobPhase = enum(u8) { pending, done, failed };

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
    const job = frame.state.pending_bookmarks orelse return;
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
    const job = state.pending_bookmarks orelse return;

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
            state.bookmarks_msg.clear();
            return;
        }
        const friendly = common.friendlyError(job.err_name orelse "?");
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
