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
