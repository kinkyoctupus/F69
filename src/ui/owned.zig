//! Heap-allocated state types shared between `state.zig` and
//! `actions.zig`.
//!
//! Background: most of the UI's long-lived state — caches, in-flight
//! jobs, running-game tables — is heap-allocated by `actions.zig` and
//! parked through a slot on `state.State` until the next frame drains
//! it. The "right" home for those types is `actions.zig` (next to
//! their lifecycle), but `state.zig` is imported by `actions.zig` so
//! having `state.zig` import the concrete types back would close a
//! cycle. The previous workaround was to declare every slot as
//! `?*anyopaque` and pay one `@ptrCast(@alignCast)` per read.
//!
//! `owned.zig` breaks the cycle: it owns the *data* shape of each
//! type, imports only modules that don't pull `state`/`actions`, and
//! is consumed by both. Behavior (workers, drain helpers, lifecycle)
//! stays in `actions.zig`, operating on `*owned.SyncJob` etc.
//!
//! R4 lands these incrementally. Each phase keeps the build + tests
//! green:
//!   R4a — primitive-valued maps/sets (this file's first cut)
//!   R4b — caches (ModfileCache, ModsPageCache, …)
//!   R4c — jobs (SyncJob, UpdateCheckJob, …)
//!   R4d — modal/transient (ClashModalState, …)

const std = @import("std");
const installer_mod = @import("installer");
const recipe = @import("recipe");
const library = @import("library");
const f95 = @import("f95");
const dvui = @import("dvui");
const job_mod = @import("job.zig");

/// Re-export so `state.zig` + `actions/*.zig` see one common
/// `owned.Job`. Generic worker-job primitive; see `src/ui/job.zig`
/// for the lifecycle contract.
pub const Job = job_mod.Job;

// ---- R4a: simple containers ------------------------------------

/// Set of f95_thread_id → unit. Tracks games currently installed on
/// disk per `library.db`. Lazy-populated by `refreshInstalledSet`;
/// consulted by `isInstalled` to colour rows.
pub const InstalledSet = std.AutoHashMap(u64, void);

/// Set of f95_thread_id → unit. Tracks games that have *finished*
/// their auto-extract step in this process. The on-disk presence is
/// the source of truth; this set just avoids re-running extract on
/// every frame while the file system catches up.
pub const PostInstalledSet = std.AutoHashMap(u64, void);

/// Map of f95_thread_id → attempt count. Records how many automatic
/// post-download install attempts have been kicked off per game so a
/// repeatedly-failing extract doesn't loop forever.
pub const AttemptsMap = std.AutoHashMap(u64, u32);

/// Map of f95_thread_id → child PID. Populated when "Run" launches
/// a game and consulted to grey-out the row and offer "Stop".
pub const RunningGamesMap = std.AutoHashMap(u64, i32);

/// Map of donor download_job_id → f95_thread_id. Used to correlate
/// `downloads.Manager` events back to the game whose donor flow
/// kicked them off.
pub const DonorJobsMap = std.AutoHashMap(u64, u64);

/// Map of f95_thread_id → retry counter. Caps how many times a
/// donor-DDL attempt is retried before the user has to re-trigger.
pub const DonorRetriesMap = std.AutoHashMap(u64, u8);

// ---- R4b: caches ----------------------------------------------

/// Loaded modfile list for the currently-open game's Modfiles tab.
/// Refilled on tab open + after Add / Scan / Delete actions. Owned
/// by `lib.alloc`; `actions.freeModfileCacheState` calls
/// `installer.mod_archives.freeModfileList` on `mods`.
pub const ModfileCache = struct {
    mods: []installer_mod.mod_archives.Modfile,
};

/// Tab-bar counters precomputed alongside `ModsPageCache` so the
/// header row doesn't re-scan the mods list on every paint.
pub const ModsTabCounts = struct {
    installed: usize = 0,
    ready: usize = 0,
    needs_archive: usize = 0,
    needs_recipe: usize = 0,
};

/// Per-game render-data cache for the Mods page. Built once per
/// (thread_id, install_id) and reused across frames until a
/// mutating action drops it. Without this, every frame
/// (including mouse-move-driven repaints) re-iterates the recipes
/// dir, re-parses every ZON, and reloads each mod's install
/// tracker — a noticeable stutter even with a few dozen mods.
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

/// Re-export of `recipe.MergedPresetSet` so `state.preset_cache`
/// can be typed without `state.zig` taking a direct `recipe`
/// import (and so the field type lives in the same module as the
/// other heap-state slots).
pub const MergedPresetSet = recipe.MergedPresetSet;

// ---- R4c: job structs ------------------------------------------

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

pub const SyncRecapList = std.ArrayList(SyncRecapEntry);

/// Payload for the per-game sync worker (scrape OP + cover +
/// screenshots). Generic carrier (phase, cancel, thread, allocator,
/// dvui window) is provided by `Job(...)`; this struct holds the
/// per-task inputs + worker output.
pub const SyncPayload = struct {
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
    url: []u8,
    f95_svc: *f95.Service,
    /// Owned copy of the covers cache dir; used by the worker to write
    /// the fetched cover bytes. Owned-and-freed alongside the Job.
    covers_dir: []u8,
    /// Set to `true` by the worker after it writes a fresh cover file
    /// so `drainSync` can invalidate the in-memory cache entry.
    cover_updated: bool = false,
    /// Io vtable — worker uses it for the cover-file write.
    io: std.Io,
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
pub const SyncJob = Job(SyncPayload);

/// Payload for the periodic latest-updates walker. Generic carrier
/// (phase, cancel, thread, allocator, dvui window) provided by
/// `Job(...)`; this struct holds the per-task inputs + worker output.
pub const UpdateCheckPayload = struct {
    f95_svc: *f95.Service,
    io: std.Io,
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
};
pub const UpdateCheckJob = Job(UpdateCheckPayload);

/// Payload for the RPDL torrent search → fetch worker. Generic
/// carrier (phase, cancel, thread, allocator, dvui window) provided
/// by `Job(...)`; this struct holds the per-task inputs + worker
/// output.
pub const RpdlDownloadPayload = struct {
    io: std.Io,
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
pub const RpdlDownloadJob = Job(RpdlDownloadPayload);

/// Payload for the F95 donor DDL flow worker (POST /sam/dddl.php
/// for a signed URL + cookie). Generic carrier (phase, cancel,
/// thread, allocator, dvui window) provided by `Job(...)`; this
/// struct holds the per-task inputs + worker output.
pub const DonorDownloadPayload = struct {
    io: std.Io,
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
pub const DonorDownloadJob = Job(DonorDownloadPayload);

pub const DonorTickState = struct {
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

pub const DonorTickLog = std.AutoHashMap(u64, DonorTickState);

/// Payload for the master-tag-list refresh worker. Generic carrier
/// (atomic phase, cancel flag, thread, allocator, dvui window) is
/// provided by `Job(...)`; this struct holds the per-task inputs +
/// worker output.
pub const RefreshTagsPayload = struct {
    io: std.Io,
    f95_svc: *f95.Service,
    /// Worker output. Owns the slice + inner strings on success;
    /// drain transfers ownership into `state.tags_master`.
    tags_out: []const []const u8 = &.{},
    fetched_at: i64 = 0,
    err_name: ?[]const u8 = null,
};
pub const RefreshTagsJob = Job(RefreshTagsPayload);

pub const ImageJobPhase = enum(u8) { pending, done };

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

pub const PostInstallJobsList = std.ArrayList(*PostInstallJob);

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

// ---- R4d: modal state ------------------------------------------

/// One declared-files conflict observed while installing a mod —
/// returned as a slice rather than the first hit only.
pub const ModFileConflictAll = struct {
    /// Path that collides (relative to install root).
    path: []u8,
    /// Mod id (numeric F95 thread, as string) currently owning the path.
    with_mod_id: []u8,
};

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
