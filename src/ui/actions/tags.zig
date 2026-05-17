// Master tag-list refresh — one-shot worker that re-fetches F95's
// `/tags/` index, sorts + dedupes, swaps `state.tags_master`, and
// persists to `<data_root>/tags.txt`. Tags change rarely so the user
// clicks "Refresh" in Settings → Library every now and then.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const dvui = @import("dvui");
const f95 = @import("f95");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const common = @import("common.zig");

const Frame = types.Frame;
const State = types.State;

pub const RefreshTagsJob = owned_types.RefreshTagsJob;

// ============================================================
//  Master tag list refresh
// ============================================================
//
// One-shot worker that re-fetches F95's `/tags/` index, sorts +
// dedupes, swaps `state.tags_master`, and persists to
// `<data_root>/tags.txt`. Tags change rarely so the user clicks
// "Refresh" in Settings → Library every now and then.

const RefreshTagsPhase = enum(u8) { pending, done, failed };


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
    const job = state.pending_tags_refresh orelse return;
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
        const m = std.fmt.bufPrint(&emsg, "tag refresh failed: {s}", .{common.friendlyError(job.err_name orelse "?")}) catch "tag refresh failed";
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
