//! Generic worker-job primitive.
//!
//! Every UI feature that offloads work to a detached thread followed
//! the same shape:
//!   1. heap-alloc a struct with `phase: atomic.Value(u8)`, `thr`,
//!      `alloc`, `win`, plus payload-specific fields;
//!   2. spawn a worker thread that flips `phase` on terminal state +
//!      calls `dvui.refresh(win, …)` to wake the UI;
//!   3. each frame, drain the slot: if `phase == .pending` return;
//!      otherwise branch on `.done` / `.failed`, run a cleanup, free.
//!
//! Twelve+ jobs hand-rolled that scaffolding. `Job(Payload)` captures
//! the common shape; `spawnJob` factors the alloc + spawn + detach +
//! slot-set chain; `drainBackgroundJob` factors the per-frame reap.
//! New workers reduce to: define a `Payload` struct, write
//! `myWorker(job: *Job(Payload)) void`, call `spawnJob`, and
//! `drainBackgroundJob(...onDone, ...onFailed)` once per frame.
//!
//! Per-job phase enums (`SyncJobPhase`, `RefreshTagsPhase`, …) all
//! used the canonical pending/done/failed shape so this primitive
//! standardises on `Job.Phase`.

const std = @import("std");
const dvui = @import("dvui");

/// Canonical job phase. Worker flips from `.pending` to either
/// `.done` or `.failed` exactly once; UI thread only ever observes
/// the terminal transition through the atomic.
pub const Phase = enum(u8) { pending, done, failed };

/// Heap-allocated job carrier. Behavior is in `actions/*.zig`
/// workers; this struct is pure data plus the atomic phase + cancel
/// flag the UI/worker contract relies on.
///
/// Lifetime: `spawnJob` allocates + spawns + detaches; the worker
/// runs to terminal phase; the next `drainBackgroundJob` reap on
/// the UI thread destroys the job. The `thr` handle is never
/// joined — detached threads are reaped by the OS, and the atomic
/// phase already gives the UI a safe happens-before for reading
/// any worker-written payload field.
pub fn Job(comptime Payload: type) type {
    return struct {
        const Self = @This();
        pub const PayloadT = Payload;

        phase: std.atomic.Value(u8),
        cancel: std.atomic.Value(bool) = .init(false),
        thr: std.Thread,
        alloc: std.mem.Allocator,
        win: *dvui.Window,
        payload: Payload,

        /// Worker → UI: flip to `.done`, refresh.
        pub fn markDone(self: *Self) void {
            self.phase.store(@intFromEnum(Phase.done), .release);
            dvui.refresh(self.win, @src(), null);
        }

        /// Worker → UI: flip to `.failed`, refresh. The payload's
        /// `err_name` (or equivalent) carries the diagnostic;
        /// `markFailed` itself is allocator-free so it works from
        /// any worker control path.
        pub fn markFailed(self: *Self) void {
            self.phase.store(@intFromEnum(Phase.failed), .release);
            dvui.refresh(self.win, @src(), null);
        }

        /// UI thread snapshot of the current phase.
        pub fn phaseGet(self: *const Self) Phase {
            return @enumFromInt(self.phase.load(.acquire));
        }

        /// UI thread asks the worker to bail out at its next phase
        /// boundary. Workers must poll `cancelRequested` between
        /// long operations; the contract is *cooperative* — there's
        /// no kill primitive here.
        pub fn requestCancel(self: *Self) void {
            self.cancel.store(true, .release);
        }

        /// Worker thread polls between long operations.
        pub fn cancelRequested(self: *const Self) bool {
            return self.cancel.load(.acquire);
        }
    };
}

/// Spawn a detached worker thread that runs `workerFn(job)`. The
/// caller's `slot` (a `*?*Job(Payload)` typed pointer on `State`)
/// is updated to point at the new job on success. Returns the job
/// pointer too so the caller can record additional bookkeeping
/// (e.g. seeding a thread-id into a sibling map).
///
/// On failure (alloc or spawn) the slot is left unchanged and the
/// job is reclaimed; caller decides whether to surface a toast.
pub fn spawnJob(
    comptime Payload: type,
    comptime workerFn: fn (*Job(Payload)) void,
    alloc: std.mem.Allocator,
    win: *dvui.Window,
    payload: Payload,
    slot: *?*Job(Payload),
) !*Job(Payload) {
    const job = try alloc.create(Job(Payload));
    errdefer alloc.destroy(job);
    job.* = .{
        .phase = .init(@intFromEnum(Phase.pending)),
        .thr = undefined,
        .alloc = alloc,
        .win = win,
        .payload = payload,
    };
    job.thr = try std.Thread.spawn(.{}, workerFn, .{job});
    job.thr.detach();
    slot.* = job;
    return job;
}

/// UI-thread reaper. Reads `slot.*`, returns if no job or still
/// pending; otherwise calls the appropriate handler, nulls the
/// slot, and destroys the heap allocation. The handlers are
/// responsible for any payload-owned cleanup (freeing strings,
/// transferring ownership into Library, etc.) BEFORE this helper
/// destroys the carrier.
///
/// The handler signature is `fn (*Ctx, *Job(Payload)) void`. `Ctx`
/// is `anytype` so callers can pass `*Frame`, `*State`, or
/// whatever. Both handlers must take the same `Ctx` type.
pub fn drainBackgroundJob(
    comptime Payload: type,
    comptime onDone: anytype,
    comptime onFailed: anytype,
    ctx: anytype,
    slot: *?*Job(Payload),
) void {
    const job = slot.* orelse return;
    switch (job.phaseGet()) {
        .pending => return,
        .done => onDone(ctx, job),
        .failed => onFailed(ctx, job),
    }
    slot.* = null;
    job.alloc.destroy(job);
}
