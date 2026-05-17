// Async mod install/uninstall queue.
//
// One global FIFO queue serviced by a single worker thread. UI rows
// enqueue an install or uninstall job; the worker runs them strictly
// in order so two installs can't fight over the same filesystem.
//
// Crash recovery: the queue serializes its job descriptions to
// `<data_root>/.f69-mod-queue.json` on every mutation. On startup
// `recover()` reads the file, treats any "in-flight" entry as
// interrupted, runs uninstallMod to roll back whatever the partial
// tracker shows on disk, then re-enqueues a fresh install. Backup
// restores work because the apply path periodically flushes the
// tracker (per `ApplyOpts.flush_every`) so the interrupted state
// is up-to-date enough to reverse.
//
// Concurrency invariants:
//   * `jobs` is mutex-protected; UI reads under `mutex.lock()`.
//   * Each job's atomics are independently readable without the
//     mutex (phase / progress / cancel).
//   * The worker only ever mutates `jobs[0]` (the head) between
//     `popHeadLocked` calls. Enqueuers append to the tail.

const std = @import("std");
const installer = @import("installer");
const library = @import("library");
const recipe = @import("recipe");
const dvui = @import("dvui");
const atomic_io = @import("util_atomic_io");

const log = std.log.scoped(.mod_job_queue);

pub const Kind = enum(u8) { install = 0, uninstall = 1 };

pub const Phase = enum(u8) {
    queued = 0,
    /// Preparing: tracker layout resolution, conflict scan.
    preparing = 1,
    /// Extracting to /tmp staging.
    staging = 2,
    /// Copying staged files into the install dir.
    applying = 3,
    /// Final tracker flush.
    flushing = 4,
    done = 5,
    err = 6,
    canceled = 7,
};

pub fn phaseLabel(p: Phase) []const u8 {
    return switch (p) {
        .queued => "Queued",
        .preparing => "Preparing",
        .staging => "Extracting",
        .applying => "Installing",
        .flushing => "Finalising",
        .done => "Done",
        .err => "Failed",
        .canceled => "Canceled",
    };
}

/// One queued install or uninstall.
pub const Job = struct {
    id: u64,
    kind: Kind,
    game_thread_id: u64,
    mod_thread_id: u64,
    /// Recipe id (alloc-owned). Used for tracker entry matching and
    /// for the banner label.
    mod_recipe_id: []u8,
    /// Pretty name for the banner (alloc-owned). "{name} v{version}".
    display: []u8,
    /// Mod-archive absolute path for installs (alloc-owned). Null for
    /// uninstall jobs.
    archive_path: ?[]u8,
    /// User pick at enqueue time. Persists across recovery so a retry
    /// runs the same way as the original.
    backup_mode: installer.BackupMode,
    /// Install id pinned at enqueue time so a later "v0.21 added"
    /// doesn't redirect this job's apply target mid-flight. Sized to
    /// match `library.Install.id` ([36]u8 — UUID hex with dashes); a
    /// smaller buffer silently truncates and breaks the equality test
    /// in `findInstallById`.
    install_id_buf: [36]u8,
    install_id_len: u8,

    // ---- atomic state (workers + UI both touch) ----
    phase: std.atomic.Value(u8),
    cancel_flag: std.atomic.Value(bool),
    progress_done: std.atomic.Value(u32),
    progress_total: std.atomic.Value(u32),

    // ---- worker-only fields (UI must not read while .phase < .done) ----
    err_buf: [192]u8,
    err_len: u16,

    pub fn installId(self: *const Job) []const u8 {
        return self.install_id_buf[0..self.install_id_len];
    }

    pub fn currentPhase(self: *const Job) Phase {
        return @enumFromInt(self.phase.load(.monotonic));
    }

    pub fn errMessage(self: *const Job) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn deinit(self: *Job, alloc: std.mem.Allocator) void {
        alloc.free(self.mod_recipe_id);
        alloc.free(self.display);
        if (self.archive_path) |p| alloc.free(p);
        self.* = undefined;
    }
};

/// Runner callback the queue invokes from the worker thread to do the
/// actual filesystem work. Lives in the UI layer because it needs to
/// resolve the install path (Library lookup) and the recipe (Repo
/// lookup). Returns void; mutates the job's atomics + err fields.
pub const Runner = *const fn (ctx: ?*anyopaque, job: *Job) void;

pub const Queue = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    win: ?*dvui.Window,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    jobs: std.ArrayList(*Job) = .empty,
    next_id: u64 = 1,

    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = .init(false),

    runner: Runner,
    runner_ctx: ?*anyopaque,

    /// Persist path: `<data_root>/.f69-mod-queue.json`. Empty when no
    /// queue file should be written (tests).
    persist_path: ?[]u8 = null,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        win: ?*dvui.Window,
        runner: Runner,
        runner_ctx: ?*anyopaque,
    ) Queue {
        return .{
            .alloc = alloc,
            .io = io,
            .win = win,
            .runner = runner,
            .runner_ctx = runner_ctx,
        };
    }

    /// Tell the queue where to persist its job descriptions. Borrowed
    /// path — caller keeps the string alive for the queue's lifetime.
    pub fn setPersistPath(self: *Queue, path: []const u8) !void {
        if (self.persist_path) |p| self.alloc.free(p);
        self.persist_path = try self.alloc.dupe(u8, path);
    }

    pub fn deinit(self: *Queue) void {
        // Signal the worker, wake it, join.
        self.shutdown.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.worker) |t| t.join();
        self.worker = null;

        self.mutex.lockUncancelable(self.io);
        for (self.jobs.items) |j| {
            j.deinit(self.alloc);
            self.alloc.destroy(j);
        }
        self.jobs.deinit(self.alloc);
        self.mutex.unlock(self.io);

        if (self.persist_path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    /// Spawn the worker thread. Safe to call once. No-op on second call.
    pub fn start(self: *Queue) !void {
        if (self.worker != null) return;
        self.worker = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    /// Enqueue a new job. Returns its assigned id. Wakes the worker.
    /// Job takes ownership of `mod_recipe_id`, `display`, `archive_path`
    /// — callers should `dupe` before passing.
    pub fn enqueue(
        self: *Queue,
        kind: Kind,
        game_thread_id: u64,
        mod_thread_id: u64,
        mod_recipe_id: []u8,
        display: []u8,
        archive_path: ?[]u8,
        backup_mode: installer.BackupMode,
        install_id: []const u8,
    ) !u64 {
        const job = try self.alloc.create(Job);
        errdefer self.alloc.destroy(job);

        var inst_buf: [36]u8 = undefined;
        const inst_n = @min(install_id.len, inst_buf.len);
        @memcpy(inst_buf[0..inst_n], install_id[0..inst_n]);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        job.* = .{
            .id = id,
            .kind = kind,
            .game_thread_id = game_thread_id,
            .mod_thread_id = mod_thread_id,
            .mod_recipe_id = mod_recipe_id,
            .display = display,
            .archive_path = archive_path,
            .backup_mode = backup_mode,
            .install_id_buf = inst_buf,
            .install_id_len = @intCast(inst_n),
            .phase = .init(@intFromEnum(Phase.queued)),
            .cancel_flag = .init(false),
            .progress_done = .init(0),
            .progress_total = .init(0),
            .err_buf = undefined,
            .err_len = 0,
        };
        try self.jobs.append(self.alloc, job);
        self.cond.signal(self.io);

        self.persistLocked() catch |e| log.warn("persist after enqueue failed: {s}", .{@errorName(e)});

        if (self.win) |w| dvui.refresh(w, @src(), null);
        return id;
    }

    /// True if the given mod has a queued or in-flight job. UI uses
    /// this to disable Install/Uninstall buttons.
    pub fn isModBusy(self: *Queue, game_thread_id: u64, mod_thread_id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |j| {
            if (j.game_thread_id != game_thread_id) continue;
            if (j.mod_thread_id != mod_thread_id) continue;
            const p = j.currentPhase();
            if (p == .done or p == .err or p == .canceled) continue;
            return true;
        }
        return false;
    }

    /// Request cooperative cancel for the given job id. The worker
    /// observes the flag between files and unwinds.
    pub fn cancel(self: *Queue, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |j| {
            if (j.id == id) {
                j.cancel_flag.store(true, .release);
                return;
            }
        }
    }

    /// Pop any finished jobs at the head (done / err / canceled) and
    /// destroy them. Called per UI frame so banner state matches reality.
    pub fn drainFinished(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var changed = false;
        while (self.jobs.items.len > 0) {
            const head = self.jobs.items[0];
            const p = head.currentPhase();
            if (p != .done and p != .err and p != .canceled) break;
            _ = self.jobs.orderedRemove(0);
            head.deinit(self.alloc);
            self.alloc.destroy(head);
            changed = true;
        }
        if (changed) self.persistLocked() catch {};
    }

    /// Read-only view of the queue for UI rendering. Caller MUST hold
    /// `mutex` for the duration. Returned slice is invalidated on the
    /// next enqueue/pop.
    pub fn jobsLocked(self: *Queue) []const *Job {
        return self.jobs.items;
    }

    pub fn lock(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Queue) void {
        self.mutex.unlock(self.io);
    }

    fn workerLoop(self: *Queue) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.jobs.items.len == 0 and !self.shutdown.load(.acquire)) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.shutdown.load(.acquire)) {
                self.mutex.unlock(self.io);
                return;
            }
            // Find the first not-yet-finished job (UI may not have
            // drained yet; we still want to advance).
            var pick: ?*Job = null;
            for (self.jobs.items) |j| {
                const p = j.currentPhase();
                if (p == .done or p == .err or p == .canceled) continue;
                pick = j;
                break;
            }
            self.mutex.unlock(self.io);

            if (pick) |job| {
                self.runner(self.runner_ctx, job);
                // Persist final state so a crash right after completion
                // doesn't make a recovery think this job is still
                // running.
                self.mutex.lockUncancelable(self.io);
                self.persistLocked() catch {};
                self.mutex.unlock(self.io);
                if (self.win) |w| dvui.refresh(w, @src(), null);
            } else {
                // All jobs are finished — wait for either a new
                // enqueue or shutdown.
                self.io.sleep(std.Io.Duration.fromMilliseconds(10), .real) catch {};
            }
        }
    }

    // ============================================================
    //  Persistence — JSON snapshot of pending jobs.
    // ============================================================

    const Persisted = struct {
        version: u32 = 1,
        next_id: u64,
        jobs: []const PersistedJob,
    };

    const PersistedJob = struct {
        id: u64,
        kind: []const u8,
        game_thread_id: u64,
        mod_thread_id: u64,
        mod_recipe_id: []const u8,
        display: []const u8,
        archive_path: ?[]const u8,
        backup_mode: []const u8,
        install_id: []const u8,
        /// Last observed phase. Anything but `.queued` at recovery time
        /// means the run was interrupted and the load path should roll
        /// it back before re-enqueueing.
        phase: []const u8,
    };

    fn persistLocked(self: *Queue) !void {
        const path = self.persist_path orelse return;

        // Build a slice of PersistedJob views into the live jobs. No
        // copies of any strings — JSON serialiser only borrows.
        var view: std.ArrayList(PersistedJob) = .empty;
        defer view.deinit(self.alloc);
        for (self.jobs.items) |j| {
            const p = j.currentPhase();
            // Skip jobs the UI has already finished; they're about to
            // be popped by drainFinished and shouldn't be re-played.
            if (p == .done or p == .canceled) continue;
            view.append(self.alloc, .{
                .id = j.id,
                .kind = @tagName(j.kind),
                .game_thread_id = j.game_thread_id,
                .mod_thread_id = j.mod_thread_id,
                .mod_recipe_id = j.mod_recipe_id,
                .display = j.display,
                .archive_path = j.archive_path,
                .backup_mode = @tagName(j.backup_mode),
                .install_id = j.installId(),
                .phase = @tagName(p),
            }) catch return error.OutOfMemory;
        }

        const payload = Persisted{
            .next_id = self.next_id,
            .jobs = view.items,
        };

        var aw = std.Io.Writer.Allocating.initCapacity(self.alloc, 4096) catch return error.OutOfMemory;
        defer aw.deinit();
        std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.WriteFailed;

        atomic_io.writeFileAtomic(self.io, path, aw.writer.buffered()) catch return error.WriteFailed;
    }

    /// Returns the parsed persisted state. Caller must `deinitRecovered`
    /// to free strings. Recovery flow is two-phase: the queue layer
    /// reads + frees the file, then the UI layer runs rollbacks and
    /// re-enqueues fresh jobs.
    pub fn loadPersisted(self: *Queue) !?RecoveredState {
        const path = self.persist_path orelse return null;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(1 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        defer self.alloc.free(bytes);

        var parsed = std.json.parseFromSlice(Persisted, self.alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.ParseFailed;
        defer parsed.deinit();

        const p = parsed.value;
        var recovered: std.ArrayList(RecoveredJob) = .empty;
        errdefer {
            for (recovered.items) |*r| r.deinit(self.alloc);
            recovered.deinit(self.alloc);
        }

        for (p.jobs) |j| {
            const kind: Kind = if (std.mem.eql(u8, j.kind, "install")) .install else .uninstall;
            const bm: installer.BackupMode = if (std.mem.eql(u8, j.backup_mode, "copy")) .copy else .none;
            const ap_owned: ?[]u8 = if (j.archive_path) |a|
                self.alloc.dupe(u8, a) catch return error.OutOfMemory
            else
                null;
            const rec = RecoveredJob{
                .kind = kind,
                .game_thread_id = j.game_thread_id,
                .mod_thread_id = j.mod_thread_id,
                .mod_recipe_id = self.alloc.dupe(u8, j.mod_recipe_id) catch return error.OutOfMemory,
                .display = self.alloc.dupe(u8, j.display) catch return error.OutOfMemory,
                .archive_path = ap_owned,
                .backup_mode = bm,
                .install_id = self.alloc.dupe(u8, j.install_id) catch return error.OutOfMemory,
                .was_running = !std.mem.eql(u8, j.phase, "queued"),
            };
            recovered.append(self.alloc, rec) catch return error.OutOfMemory;
        }

        // Wipe the persist file so a second crash before re-persistence
        // doesn't double-replay.
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};

        return .{
            .jobs = recovered.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
            .next_id = p.next_id,
        };
    }
};

pub const RecoveredJob = struct {
    kind: Kind,
    game_thread_id: u64,
    mod_thread_id: u64,
    mod_recipe_id: []u8,
    display: []u8,
    archive_path: ?[]u8,
    backup_mode: installer.BackupMode,
    install_id: []u8,
    /// True if the job was past `.queued` when the app died — caller
    /// must roll back any partial on-disk state before re-enqueueing.
    was_running: bool,

    pub fn deinit(self: *RecoveredJob, alloc: std.mem.Allocator) void {
        alloc.free(self.mod_recipe_id);
        alloc.free(self.display);
        if (self.archive_path) |p| alloc.free(p);
        alloc.free(self.install_id);
        self.* = undefined;
    }
};

pub const RecoveredState = struct {
    jobs: []RecoveredJob,
    next_id: u64,

    pub fn deinit(self: *RecoveredState, alloc: std.mem.Allocator) void {
        for (self.jobs) |*j| j.deinit(alloc);
        if (self.jobs.len > 0) alloc.free(self.jobs);
        self.* = undefined;
    }
};

/// Adopt a recovered next_id so newly enqueued jobs don't collide with
/// stale persisted ids in any logs the user may have.
pub fn adoptRecoveredNextId(q: *Queue, next_id: u64) void {
    q.mutex.lockUncancelable(q.io);
    defer q.mutex.unlock(q.io);
    if (next_id > q.next_id) q.next_id = next_id;
}
