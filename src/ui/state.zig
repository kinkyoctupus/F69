// UI state. Single struct lives in main; UI mutates it in event
// handlers; render reads it each frame.

const std = @import("std");
const library = @import("library");
const dvui = @import("dvui");
const buf_mod = @import("buf.zig");
const owned = @import("owned.zig");
const import_job_mod = @import("import_job.zig");
pub const MessageBuf = buf_mod.MessageBuf;

pub const Screen = enum { library, detail, settings, import, downloads, diagnostics, recipe_editor, mods_for_game };
/// Sort options. `weighted` uses Game.weightedRating against the
/// library's mean rating + a fixed prior weight, so games with few
/// votes don't unfairly dominate over well-rated games. `sync_state`
/// promotes already-synced rows above placeholder "(unsynced)" ones —
/// previously this was implicit, now it's an explicit pick.
pub const SortColumn = enum { name, rating, weighted, votes, last_updated, sync_state };
pub const SortDir = enum { asc, desc };
pub const LoginStatus = enum { unknown, logged_out, logged_in, logging_in, err };
pub const View = enum { grid, list };
pub const Tab = enum { overview, changelog, downloads, notes };

/// Filter tabs for the Mods page. Each filters the master list of
/// (archive, recipe) pairs by state:
///   installed     — applied to the selected install
///   ready         — has archive + recipe but not installed
///   needs_archive — recipe exists, no archive yet (imported)
///   needs_recipe  — archive exists, no recipe yet (orphan)
pub const ModsTab = enum { installed, ready, needs_archive, needs_recipe };
pub const SettingsTab = enum { general, sync, accounts, library, downloads, mod_presets, convert_presets, about };

/// Recipe-wizard modal phases. The wizard renders one page per step,
/// with Back/Next driving the transition. `review` is terminal — save
/// from there closes the modal.
pub const WizardStep = enum {
    meta, // mod name, version, F95 post URL, target game version
    install, // pick install blocks (extract / extract_inner / copy / move / delete / chmod_x)
    relations, // requires / conflicts / load_after pickers
    review, // show generated ZON; save / cancel
};

/// One install-step block being built up by the wizard. The wizard's
/// "Add block" buttons append one of these; finalize converts them
/// into a `[]recipe.InstallStep` written into the saved recipe.
pub const WizardBlockKind = enum {
    extract,
    extract_inner,
    copy,
    move,
    delete,
    chmod_x,
};

/// Fixed-size scratch for a single wizard block. The wizard owns up
/// to `WIZARD_MAX_BLOCKS` of these. Strings are inline buffers so the
/// allocator stays out of the wizard's hot path.
pub const WizardBlock = struct {
    kind: WizardBlockKind,
    /// extract.to / extract_inner.to / chmod_x first path / copy.src /
    /// move.src / delete.path — the "first" path field of the block.
    a_buf: [256]u8 = [_]u8{0} ** 256,
    /// extract_inner.archive (the inner archive within main staging) /
    /// copy.dest / move.dest — the "second" path field, unused for
    /// `extract`/`delete`/`chmod_x`.
    b_buf: [256]u8 = [_]u8{0} ** 256,
    /// strip count for `extract` / `extract_inner`.
    strip: u8 = 0,
};

pub const WIZARD_MAX_BLOCKS: usize = 32;
pub const WIZARD_MAX_RELATIONS: usize = 16;
pub const WIZARD_MAX_INSTALL_VERSIONS: usize = 16;

/// Per-wizard state. Allocated/freed by `actions.zig` when the user
/// clicks "Create recipe" / cancels / saves.
pub const WizardState = struct {
    step: WizardStep = .meta,
    /// Modfile this wizard is authoring a recipe for. SHA-256 hex.
    modfile_id_buf: [64]u8 = [_]u8{0} ** 64,
    modfile_id_len: usize = 0,
    /// Which game the modfile belongs to (used for recipe.for_game
    /// and to look up the modfile back at finalize time).
    game_thread_id: u64 = 0,
    /// Cached game recipe id for the current game — set when the
    /// wizard opens. Drives the `for_game` field of the output.
    for_game_buf: [128]u8 = [_]u8{0} ** 128,
    for_game_len: usize = 0,

    name_buf: [160]u8 = [_]u8{0} ** 160,
    version_buf: [32]u8 = [_]u8{0} ** 32,
    post_url_buf: [512]u8 = [_]u8{0} ** 512,
    for_game_version_buf: [64]u8 = [_]u8{0} ** 64,

    /// Versions of installed builds for this game, captured when the
    /// wizard opens. Rendered as a dropdown on the meta page so the
    /// user picks the existing install instead of typing a version
    /// by hand (and getting it subtly wrong).
    install_versions_buf: [WIZARD_MAX_INSTALL_VERSIONS][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** WIZARD_MAX_INSTALL_VERSIONS,
    install_versions_count: usize = 0,
    install_versions_pick: usize = 0,

    blocks: [WIZARD_MAX_BLOCKS]WizardBlock = [_]WizardBlock{.{ .kind = .extract }} ** WIZARD_MAX_BLOCKS,
    block_count: usize = 0,

    /// Selected requires / conflicts / load_after — each entry is a
    /// recipe id picked from the existing mod recipes for this game.
    requires_buf: [WIZARD_MAX_RELATIONS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** WIZARD_MAX_RELATIONS,
    requires_len: usize = 0,
    conflicts_buf: [WIZARD_MAX_RELATIONS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** WIZARD_MAX_RELATIONS,
    conflicts_len: usize = 0,
    load_after_buf: [WIZARD_MAX_RELATIONS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** WIZARD_MAX_RELATIONS,
    load_after_len: usize = 0,

    /// Last error message (validator failure, file write failure…)
    /// shown on the review page.
    err_msg_buf: [240]u8 = [_]u8{0} ** 240,
    err_msg_len: usize = 0,

    /// True when the simulation detail-list (per-file rows) is
    /// expanded. UI button toggles. Persists across paints inside
    /// the wizard's lifetime; resets to false when wizard closes.
    sim_details_expanded: bool = false,

    /// When set, the simulation panel highlights writes produced by
    /// this step index. Set by clicking a block's title row; cleared
    /// by clicking the same block again or by re-opening the wizard.
    sim_highlight_step: ?usize = null,

    /// Screen the user was on when this wizard was opened. closeWizard
    /// pops back to it. Required field — every caller must specify
    /// where to return so the navigation can't silently drop the user
    /// in the wrong place.
    return_screen: Screen,
};

/// Lifecycle of a single Sync click. Driven by the UI thread off
/// observations of the worker thread's atomic flag.
pub const SyncStatus = enum { idle, running, ok, err };

/// Severity of a toast notification. Drives the leading glyph + how
/// long the toast hangs around before auto-dismissing.
///   info    — plain "here's what happened" (no glyph). 3 s.
///   success — confirmation of a user-initiated action ("Renamed."). 3 s.
///   warn    — non-fatal hint ("Auto-update skipped: recipe lags"). 6 s.
///   err     — failure path ("Spawn failed: …"). Stays until clicked.
pub const ToastKind = enum { info, success, warn, err };

/// One toast record. Buffer is inline (no allocator) so any code
/// path can push without needing `lib.alloc` plumbing. Message
/// truncated at `MAX_TOAST_MSG`.
///
/// TTL is in *frames* (not wall-clock) to avoid threading `std.Io`
/// through every state setter. Drain decrements once per frame; at
/// ~60 fps the 180-frame default ≈ 3 seconds. Vsync-dependent so
/// 144 Hz monitors fade twice as fast — fine for transient UI.
pub const MAX_TOAST_MSG: usize = 240;
pub const Toast = struct {
    buf: [MAX_TOAST_MSG]u8 = [_]u8{0} ** MAX_TOAST_MSG,
    len: usize = 0,
    kind: ToastKind = .info,
    /// Frames remaining before this toast disappears. `maxInt(u32)`
    /// = persistent (used by `.err` so failures don't slip past).
    ttl_frames: u32 = 0,

    pub fn msg(self: *const Toast) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Per-kind default TTL in frames at 60 fps (vsync-dependent — 144 Hz
/// monitors fade roughly proportionally faster, which is fine for
/// Toast lifetimes in frames (~60 Hz target). Two buckets:
///   info / success → 3 s (transient acks, "queued X", "renamed")
///   warn / err     → 5 s (something the user might want to read /
///                    screenshot before it goes away)
/// All four are click-to-dismiss so the user can clear them
/// immediately without waiting for the timer.
const TOAST_TTL_INFO: u32 = 300;
const TOAST_TTL_SUCCESS: u32 = 300;
const TOAST_TTL_WARN: u32 = 300;
const TOAST_TTL_ERR: u32 = 300;

/// Cap on active toasts. Pushing a sixth evicts the oldest non-error.
pub const MAX_TOASTS: usize = 5;

/// Per-install management action launched from the install picker's
/// ⋯ menu. Held in `State.manage_action`; the next-frame UI renders
/// a matching modal (rename text entry, delete confirm) and clears
/// the action when the user closes it.
pub const ManageAction = enum { none, rename, delete };

/// Capacity of the cover-bytes round-robin cache. ~64 covers × ~300 KB
/// avg = ~20 MB peak. Eviction is FIFO via `cover_cache_next`.
pub const COVER_CACHE_CAP: usize = 64;
/// Capacity of the per-game thumbnail-strip cache. Cover (idx 0) +
/// up to MAX_SCREENSHOTS (20) = 21 slots. One game's-worth.
pub const THUMB_CACHE_CAP: usize = 21;

pub const CoverCacheEntry = struct {
    thread_id: u64,
    bytes: []u8,
};

pub const SyncStateFilter = enum { all, synced, unsynced };

/// Filter the library by whether the game has at least one `installs`
/// row. `unknown` is the explicit "no install on record" state — we
/// already auto-write a row in `drainPostInstall` so anything missing
/// is genuinely uninstalled.
pub const InstalledFilter = enum { all, installed, not_installed };

/// Unit for the "check for updates every X" recurring auto-check.
/// Drives the multiplier between the user's integer count and the
/// elapsed-seconds comparison the main loop runs.
pub const AutoCheckUnit = enum {
    minutes,
    hours,
    days,

    pub fn seconds(self: AutoCheckUnit) i64 {
        return switch (self) {
            .minutes => 60,
            .hours => 60 * 60,
            .days => 24 * 60 * 60,
        };
    }
};

/// Persisted preferences for the auto-update-check workflow.
pub const AutoCheckSettings = struct {
    /// True → trigger one update-check once at app start (after the
    /// library has loaded and any in-flight bookmark import wraps).
    on_startup: bool = false,
    /// True → trigger an update-check whenever
    /// `(now - last_update_check_ts) >= interval_count * unit`.
    interval_enabled: bool = false,
    /// Clamped to 1..999 on load so a bad file can't render the
    /// interval pathologically tight or unreachable.
    interval_count: u32 = 6,
    interval_unit: AutoCheckUnit = .hours,
};

pub const Filters = struct {
    engine: EngineMask = .{},
    status: StatusMask = .{},
    /// Inclusive lower bound on rating; null = no filter.
    min_rating: ?f32 = null,
    /// Tri-state filter on whether a row has ever been synced. Default
    /// `.all` shows everything; `.synced` shows only rows where
    /// `last_scraped_at != null`, `.unsynced` shows only the placeholder
    /// "(unsynced)" rows.
    sync_state: SyncStateFilter = .all,
    /// "Installed / Not installed / All" filter. Independent of
    /// sync state — a synced row may or may not have an install.
    installed: InstalledFilter = .all,
    /// Substring match against `Game.developer`, case-insensitive.
    /// Empty buffer = no filter. ASCII-only contains check.
    developer_buf: [64]u8 = [_]u8{0} ** 64,
    /// Comma-separated tag list — game must have EVERY listed tag
    /// (case-insensitive substring of any of `Game.tags`).
    tag_include_buf: [256]u8 = [_]u8{0} ** 256,
    /// Comma-separated tag list — game must have NONE of these tags.
    tag_exclude_buf: [256]u8 = [_]u8{0} ** 256,
    /// Dev-status mask: scraped from F95 (completed / abandoned /
    /// on hold / in progress / unknown). Any-bit-set ⇒ filter active.
    dev_status: DevStatusMask = .{},
    /// Censored mask: scraped from the OP's "Censored:" line.
    censored: CensoredMask = .{},

    pub const EngineMask = struct {
        renpy: bool = false,
        rpgm_mv: bool = false,
        rpgm_mz: bool = false,
        rpgm_vx: bool = false,
        unity: bool = false,
        unreal: bool = false,
        html: bool = false,
        flash: bool = false,
        java: bool = false,
        wolf_rpg: bool = false,
        qsp: bool = false,
        tyranobuilder: bool = false,
        twine: bool = false,
        other: bool = false,
        unknown: bool = false,
    };

    pub const StatusMask = struct {
        not_started: bool = false,
        in_queue: bool = false,
        in_progress: bool = false,
        completed: bool = false,
        replaying: bool = false,
        abandoned: bool = false,
        waiting_for_update: bool = false,
    };

    pub const DevStatusMask = struct {
        unknown: bool = false,
        in_progress: bool = false,
        on_hold: bool = false,
        completed: bool = false,
        abandoned: bool = false,
        orphaned: bool = false,
    };

    pub const CensoredMask = struct {
        unknown: bool = false,
        no: bool = false,
        yes: bool = false,
        partial: bool = false,
    };

    pub fn empty(self: Filters) bool {
        return self.min_rating == null and self.sync_state == .all and
            !engineMaskAny(self.engine) and
            !statusMaskAny(self.status) and
            !devStatusMaskAny(self.dev_status) and
            !censoredMaskAny(self.censored) and
            developerSliceLen(&self.developer_buf) == 0 and
            tagSliceLen(&self.tag_include_buf) == 0 and
            tagSliceLen(&self.tag_exclude_buf) == 0;
    }

    /// View the live (sentinel-trimmed) slice of a fixed-size text-input
    /// buffer. dvui's textEntry leaves the unused tail zeroed.
    pub fn developerSlice(self: *const Filters) []const u8 {
        return sliceFromBuf(u8, &self.developer_buf);
    }
    pub fn tagIncludeSlice(self: *const Filters) []const u8 {
        return sliceFromBuf(u8, &self.tag_include_buf);
    }
    pub fn tagExcludeSlice(self: *const Filters) []const u8 {
        return sliceFromBuf(u8, &self.tag_exclude_buf);
    }
    fn sliceFromBuf(comptime T: type, buf: []const T) []const T {
        var n: usize = 0;
        while (n < buf.len and buf[n] != 0) : (n += 1) {}
        return buf[0..n];
    }
    fn developerSliceLen(buf: *const [64]u8) usize {
        return sliceFromBuf(u8, buf).len;
    }
    fn tagSliceLen(buf: *const [256]u8) usize {
        return sliceFromBuf(u8, buf).len;
    }

    fn engineMaskAny(m: EngineMask) bool {
        return m.renpy or m.rpgm_mv or m.rpgm_mz or m.rpgm_vx or m.unity or m.unreal or
            m.html or m.flash or m.java or m.wolf_rpg or m.qsp or m.tyranobuilder or
            m.twine or m.other or m.unknown;
    }

    fn statusMaskAny(m: StatusMask) bool {
        return m.not_started or m.in_queue or m.in_progress or m.completed or
            m.replaying or m.abandoned or m.waiting_for_update;
    }

    fn devStatusMaskAny(m: DevStatusMask) bool {
        return m.unknown or m.in_progress or m.on_hold or m.completed or m.abandoned or m.orphaned;
    }

    fn censoredMaskAny(m: CensoredMask) bool {
        return m.unknown or m.no or m.yes or m.partial;
    }

    pub fn match(self: Filters, g: *const library.Game) bool {
        const is_unsynced = std.mem.eql(u8, g.name, "(unsynced)");
        switch (self.sync_state) {
            .all => {},
            .synced => if (is_unsynced) return false,
            .unsynced => if (!is_unsynced) return false,
        }
        if (self.min_rating) |min| {
            const r = g.rating orelse 0;
            if (r < min) return false;
        }

        // Engine mask: if any engine bit is set, the game's engine must
        // match one. If none are set, no engine filter.
        if (engineMaskAny(self.engine)) {
            const ok = switch (g.engine) {
                .renpy => self.engine.renpy,
                .rpgm_mv => self.engine.rpgm_mv,
                .rpgm_mz => self.engine.rpgm_mz,
                .rpgm_vx => self.engine.rpgm_vx,
                .unity => self.engine.unity,
                .unreal => self.engine.unreal,
                .html => self.engine.html,
                .flash => self.engine.flash,
                .java => self.engine.java,
                .wolf_rpg => self.engine.wolf_rpg,
                .qsp => self.engine.qsp,
                .tyranobuilder => self.engine.tyranobuilder,
                .twine => self.engine.twine,
                .other => self.engine.other,
                .unknown => self.engine.unknown,
            };
            if (!ok) return false;
        }

        // Status mask: same rule.
        if (statusMaskAny(self.status)) {
            const ok = switch (g.completion_status) {
                .not_started => self.status.not_started,
                .in_queue => self.status.in_queue,
                .in_progress => self.status.in_progress,
                .completed => self.status.completed,
                .replaying => self.status.replaying,
                .abandoned => self.status.abandoned,
                .waiting_for_update => self.status.waiting_for_update,
            };
            if (!ok) return false;
        }

        // Dev-status (developer's release state) mask.
        if (devStatusMaskAny(self.dev_status)) {
            const ok = switch (g.dev_status) {
                .unknown => self.dev_status.unknown,
                .in_progress => self.dev_status.in_progress,
                .on_hold => self.dev_status.on_hold,
                .completed => self.dev_status.completed,
                .abandoned => self.dev_status.abandoned,
                .orphaned => self.dev_status.orphaned,
            };
            if (!ok) return false;
        }

        // Censored mask.
        if (censoredMaskAny(self.censored)) {
            const ok = switch (g.censored) {
                .unknown => self.censored.unknown,
                .no => self.censored.no,
                .yes => self.censored.yes,
                .partial => self.censored.partial,
            };
            if (!ok) return false;
        }

        // Developer text filter — case-insensitive substring.
        const dev_q = sliceFromBuf(u8, &self.developer_buf);
        if (dev_q.len > 0) {
            const dev = g.developer orelse return false;
            if (!asciiContainsIgnoreCase(dev, dev_q)) return false;
        }

        // Tag include — game must match EVERY listed tag (comma-
        // separated, case-insensitive substring of any of `g.tags`).
        const inc_raw = sliceFromBuf(u8, &self.tag_include_buf);
        if (inc_raw.len > 0) {
            var it = std.mem.splitScalar(u8, inc_raw, ',');
            while (it.next()) |raw| {
                const want = std.mem.trim(u8, raw, " \t");
                if (want.len == 0) continue;
                var hit = false;
                for (g.tags) |t| {
                    if (asciiContainsIgnoreCase(t, want)) {
                        hit = true;
                        break;
                    }
                }
                if (!hit) return false;
            }
        }

        // Tag exclude — game must match NONE of the listed tags.
        const exc_raw = sliceFromBuf(u8, &self.tag_exclude_buf);
        if (exc_raw.len > 0) {
            var it = std.mem.splitScalar(u8, exc_raw, ',');
            while (it.next()) |raw| {
                const banned = std.mem.trim(u8, raw, " \t");
                if (banned.len == 0) continue;
                for (g.tags) |t| {
                    if (asciiContainsIgnoreCase(t, banned)) return false;
                }
            }
        }

        return true;
    }

    fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |nc, k| {
                if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(nc)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
};

pub const State = struct {
    screen: Screen = .library,
    view: View = .grid,
    sort_column: SortColumn = .name,
    sort_dir: SortDir = .asc,
    /// Last sort actually applied to the games slice; null forces a
    /// re-sort (used after `reload_requested`).
    sort_applied_column: ?SortColumn = null,
    sort_applied_dir: ?SortDir = null,
    filters: Filters = .{},
    search_buf: [64]u8 = [_]u8{0} ** 64,
    /// f95_thread_id of the game currently displayed in detail screen.
    selected_thread: ?u64 = null,
    /// Currently shown slide in the detail-screen carousel. Slide 0
    /// is the cover; 1..N are screenshots. Reset when the user
    /// navigates to a different game.
    carousel_index: usize = 0,
    /// `selected_thread` value the carousel index is currently for.
    /// Detail screen detects mismatch + resets `carousel_index = 0`.
    carousel_for_thread: ?u64 = null,
    /// True while the click-to-enlarge image popup is showing the
    /// current carousel slide at native size in a modal floating
    /// window. dvui's `windowHeader` X-button writes false here when
    /// the user closes it.
    image_popup_open: bool = false,
    /// Single-slot cache for the current carousel slide's on-disk
    /// bytes (screenshots only — slide 0 reuses `cover_cache`). Without
    /// this we'd realloc + re-read + bust dvui's texture cache every
    /// frame, causing visible scroll/render lag. Stable while the slide
    /// stays on the same (thread, idx); freed and refreshed on change.
    slide_cache_thread: ?u64 = null,
    slide_cache_idx: usize = 0,
    slide_cache_bytes: ?[]u8 = null,
    /// Thumb-strip cache. Holds bytes for every slide of the active
    /// game so the ribbon under the carousel doesn't re-read 21 files
    /// per frame. Fixed-size array keyed by slide idx (0 = cover,
    /// 1..N = screenshots). Filled lazily on first paint, freed on
    /// thread change / detail-page exit.
    thumb_cache_thread: ?u64 = null,
    thumb_cache_bytes: [THUMB_CACHE_CAP]?[]u8 = [_]?[]u8{null} ** THUMB_CACHE_CAP,
    /// Active tab inside the detail screen.
    detail_tab: Tab = .overview,
    /// Active tab inside the Mods page. Filters which lists render
    /// below the page header. Reset to `.installed` on game-change so
    /// new game opens to the "what's currently running" view.
    mods_tab: ModsTab = .installed,
    /// Active tab on the Settings screen.
    settings_tab: SettingsTab = .general,
    /// dvui ScrollInfo backing the detail-screen outer scrollArea.
    /// State-owned so we preserve the user's scroll position across
    /// tab switches (the body has a 500px min-height floor so a tab
    /// switch can't strand the scroll position past the page's end).
    detail_scroll: dvui.ScrollInfo = .{},
    /// Install id the Mods page is currently operating against.
    /// Lets the user mod a non-latest version explicitly (e.g. apply
    /// a fix to v0.20 while v0.21 is also installed). Null = use the
    /// newest install. Reset when navigating between games.
    mods_page_install_id: ?[36]u8 = null,

    /// Install id the install-picker dropdown currently displays.
    /// Persisted across frames so dropdown selections stick AND so
    /// the ⋯ menu has a stable target. Null means "use the latest
    /// install" (default behaviour, matches pre-multi-install code).
    detail_picker_install_id: ?[36]u8 = null,
    /// Active install-management action (rename / delete) launched
    /// from the picker's ⋯ menu. `.none` = no modal in flight.
    manage_action: ManageAction = .none,
    /// Install id the active management action targets.
    manage_install_id: ?[36]u8 = null,
    /// Text-entry buffer for the rename modal. NUL-terminated;
    /// `manualInstallNameSlice`-style trimmed reads.
    manage_rename_buf: [64]u8 = [_]u8{0} ** 64,
    /// Thread-id the per-detail-page state is currently scoped to.
    /// `detailScreen` compares this against `selected_thread` each
    /// frame and, on mismatch, resets per-page UI state via
    /// `resetDetailViewState`. Without this the active tab + scroll +
    /// popups carry over when the user navigates from one game's
    /// detail page to another's, which surprised the user.
    detail_state_for_thread: ?u64 = null,
    /// True when the user clicked Delete and we're showing the confirm
    /// banner. Cleared on Cancel or after the row + cover are gone.
    confirm_delete: bool = false,
    /// True when the user clicked the `?` next to Convert; expands an
    /// inline help block under the action row.
    convert_help_open: bool = false,
    /// User-configurable dvui content_scale. Mirrored into
    /// `Window.content_scale` every frame so adjusting the Settings
    /// slider takes effect immediately. Persisted to
    /// Rebuilt once per library-screen render: every f95_thread_id
    /// that has at least one install row. Used by the grid/list-view
    /// installed indicator and the `installed` filter. Reset each
    /// frame the library screen rebuilds it; never referenced off
    /// the library-screen render path.
    installed_set: ?*owned.InstalledSet = null,
    /// `<data_root>/ui_scale`.
    ui_scale: f32 = 1.25,
    /// Tracks the last persisted value so we don't rewrite the file
    /// on every slider tick.
    ui_scale_persisted: f32 = 1.25,
    /// Unix-seconds timestamp of the last successful "check updates"
    /// walk. Used as the stop-condition when scanning F95's
    /// latest-updates pages. Persisted to disk on each successful
    /// scan; 0 means "never checked".
    last_update_check_ts: i64 = 0,
    /// User preferences for automatically running the update-check
    /// walker. Source-of-truth lives here; mirrored to disk via
    /// `persistAutoCheckIfDirty`.
    auto_check: AutoCheckSettings = .{},
    /// Snapshot of the last value we wrote to disk — used to debounce
    /// the persist call when nothing actually changed.
    auto_check_persisted: AutoCheckSettings = .{},
    /// One-shot flag — flips to true after the on-startup auto check
    /// has fired (or been skipped because workers were busy). Stays
    /// true for the rest of the run so we don't repeatedly trigger
    /// it after bookmarks finish importing.
    auto_check_did_startup: bool = false,
    /// Saved on library→detail transition, restored on Back.
    library_scroll: f32 = 0,
    /// Persistent scroll state for the library screen — `virtual_size`
    /// drives the scrollbar and `viewport.y/h` is read each frame to
    /// decide which row range to actually render. Lives across frames
    /// so the scroll position survives toggles.
    lib_scroll_info: dvui.ScrollInfo = .{},
    /// Last Sync action's status. Reset to `.idle` when entering detail.
    sync_status: SyncStatus = .idle,
    /// Short message describing the last sync (success or error).
    sync_msg: buf_mod.MessageBuf(128) = .{},
    /// Heap-allocated SyncJob (defined in `ui.zig`); held as anyopaque
    /// so `state.zig` doesn't pull in f95/library/std.Thread.
    pending_sync: ?*owned.SyncJob = null,
    /// Sync-all queue: thread_ids waiting to be synced. drainSync pops
    /// the head and spawns the next job once the current one finishes.
    /// Heap-alloc'd via `lib.alloc`; null when no batch is in flight.
    /// Heap-allocated UpdateCheckJob (defined in `actions.zig`), held
    /// as anyopaque to avoid the cyclic import. `drainUpdateCheck`
    /// reads phase via atomics and frees here on completion.
    pending_update_check: ?*owned.UpdateCheckJob = null,
    /// Heap-allocated RpdlDownloadJob (defined in `actions.zig`).
    /// Tracks the search → fetch-torrent → enqueue handoff for the
    /// per-game Tier-2 auto-download.
    pending_rpdl_download: ?*owned.RpdlDownloadJob = null,
    /// Heap-allocated DonorDownloadJob (defined in `actions.zig`).
    /// Mirrors `pending_rpdl_download` for the Tier-1 donor-DDL flow:
    /// POST `/sam/dddl.php` → grab signed URL → enqueue via aria2.
    pending_donor_download: ?*owned.DonorDownloadJob = null,
    /// Tracks which in-flight aria2 jobs originated from a donor-DDL
    /// signed URL so the failure handler knows it can POST for a fresh
    /// URL and re-enqueue (handles signed-URL TTL expiry).
    donor_jobs: ?*owned.DonorJobsMap = null,
    /// Bounds the auto-retry loop on signed-URL expiry — without it a
    /// permanently dead URL would just spin forever.
    donor_retries: ?*owned.DonorRetriesMap = null,
    /// `HashMap(u64 job_id → DonorTickState)` — per-job rolling
    /// telemetry for donor downloads (last log timestamp, last
    /// observed byte count, stall-since timestamp, last seen aria2
    /// errorMessage). Drives the verbose "how is this download
    /// behaving" logging that `drainDonorTelemetry` emits.
    donor_tick_log: ?*owned.DonorTickLog = null,
    /// Heap-allocated RefreshTagsJob (defined in `actions.zig`).
    /// Set while a master-tag-list refresh is in flight.
    pending_tags_refresh: ?*owned.RefreshTagsJob = null,
    /// Active post-install workers — one entry per terminal download
    /// whose archive is currently being SHA-verified + extracted on a
    /// detached thread. Held as anyopaque so `state.zig` doesn't pull
    /// in downloads / installer modules; `actions.postInstallJobsList`
    /// does the lazy ArrayList(*PostInstallJob) init. Drained every
    /// frame by `drainPostInstall`.
    post_install_jobs: ?*owned.PostInstallJobsList = null,
    /// In-flight F95Checker / xLibrary import worker. Held as
    /// anyopaque so state.zig doesn't pull in the import_job module.
    /// One at a time; `actions.startImport*` rejects a second click.
    import_job: ?*import_job_mod.Job = null,
    /// In-flight manual-install workers (user picked an archive off
    /// disk; we hash + extract + write an `installs` row). Same
    /// lifecycle as `post_install_jobs`; held as anyopaque so this
    /// file doesn't pull in actions.zig's `ManualInstallJob`.
    manual_install_jobs: ?*owned.ManualInstallJobsList = null,
    /// Detail-page "Install from file…" expander state: when true,
    /// renderActionRow drops an inline panel under itself with
    /// path / version / name fields. Independent of an in-flight
    /// worker so the panel can stay open while the worker runs.
    manual_install_open: bool = false,
    /// Editable text fields for the manual-install panel. Loaded
    /// from / written back to disk on enqueue.
    manual_install_path_buf: [1024]u8 = [_]u8{0} ** 1024,
    manual_install_version_buf: [64]u8 = [_]u8{0} ** 64,
    manual_install_name_buf: [64]u8 = [_]u8{0} ** 64,
    /// Accumulated "version changed" entries collected during a
    /// sync-all / updates-check batch. Lazy-init ArrayList of
    /// `SyncRecapEntry` (defined in actions.zig). When the batch
    /// finishes with `sync_recap_show = true`, the main loop renders
    /// the popup over the current screen.
    sync_recap: ?*owned.SyncRecapList = null,
    /// True while the end-of-batch recap popup should be visible.
    /// Cleared by the user (close button) or by starting a new batch.
    sync_recap_show: bool = false,
    /// Master tag list loaded from `<data_root>/tags.txt`. Owned by
    /// `lib.alloc`. Empty until either disk-load or the first
    /// refresh succeeds. Re-allocated wholesale on refresh.
    tags_master: []const []const u8 = &.{},
    /// Unix seconds when the master list was last fetched. 0 = never.
    tags_master_fetched_at: i64 = 0,
    /// Quick-filter text for the sidebar tag checkbox lists.
    tags_filter_buf: [64]u8 = [_]u8{0} ** 64,
    sync_queue: ?[]u64 = null,
    /// 0-based pop offset into `sync_queue` — the next item to spawn
    /// once the current sync completes. Strictly an array index;
    /// progress display uses `sync_queue_started` instead.
    sync_queue_idx: usize = 0,
    /// 1-based index of the currently-running sync within the batch
    /// (1 = first item of a batch). 0 means no batch is active.
    /// Decoupled from `sync_queue_idx` so the ad-hoc "append while
    /// solo sync runs" case can count the running sync as item 1
    /// without needing it in the pending queue array.
    sync_queue_started: u32 = 0,
    sync_queue_total: u32 = 0,
    /// Name of the game whose SyncJob is currently in flight. Set by
    /// `syncGame` when it spawns the worker and cleared by the
    /// drainSync cleanup helper. Reads as a sentinel-trimmed slice via
    /// `currentSyncName()`.
    active_sync_name: buf_mod.MessageBuf(160) = .{},

    // ----- phase-2 image fetch (screenshots) -----
    /// FIFO of thread_ids whose phase-1 (text+cover) scrape just
    /// committed; a background worker will fetch their screenshots so
    /// the library stays usable while images trickle in. Owned by
    /// `lib.alloc`. Indices `image_queue_head..image_queue_len` are
    /// pending; everything before head has been spawned. When head ==
    /// len the queue is drained and (after `image_active` clears) the
    /// counters reset.
    image_queue: ?[]u64 = null,
    image_queue_head: usize = 0,
    image_queue_len: usize = 0,
    image_queue_cap: usize = 0,
    /// Currently-running ImageJob; opaque so `actions.zig` owns the
    /// definition. Null when idle between jobs.
    image_active: ?*owned.ImageJob = null,
    /// Name of the game whose ImageJob is in flight (for the second
    /// banner row). Sentinel-trimmed.
    image_active_name: buf_mod.MessageBuf(160) = .{},
    /// Cumulative images fetched / planned across the current phase-2
    /// "batch". Resets to 0 when the queue empties AND `image_active`
    /// is null, so the banner row disappears between bursts. `done`
    /// is atomic so the worker thread can bump after each fetch.
    image_done: std.atomic.Value(u32) = .init(0),
    image_total: u32 = 0,
    /// Set by `cancelSync` (or a dedicated cancel button on the banner)
    /// to bail every in-flight + queued image fetch. Worker checks
    /// between each image; drain clears the queue + resets to false
    /// once the active job exits.
    image_cancel: std.atomic.Value(bool) = .init(false),
    /// Round-robin cache of cover bytes, shared by detail screen and
    /// grid thumbs. Owned by `lib.alloc`; freed on quit and on entry
    /// eviction. Sync invalidates the entry for the synced thread.
    cover_cache: [COVER_CACHE_CAP]?CoverCacheEntry = [_]?CoverCacheEntry{null} ** COVER_CACHE_CAP,
    cover_cache_next: usize = 0,
    /// Edit buffer for the Notes tab — re-loaded from the DB whenever
    /// `notes_for_thread` changes. UI flushes back to DB on Save click.
    notes_buf: [4096]u8 = [_]u8{0} ** 4096,
    notes_for_thread: ?u64 = null,
    /// Paste-area for the bookmark/thread-list importer (8 KiB cap).
    import_buf: [8192]u8 = [_]u8{0} ** 8192,
    /// Imported / skipped counts shown to the user post-import.
    import_msg: buf_mod.MessageBuf(128) = .{},
    /// Set by the importer; runMainLoop checks each iteration and
    /// re-runs `lib.listGames` when true.
    reload_requested: bool = false,
    /// Editable buffer for the Downloads screen's URL paste field.
    dl_url_buf: [512]u8 = [_]u8{0} ** 512,
    /// Editable buffer for the Settings → Downloads aria2-port field.
    /// "0" or empty means "random ephemeral port". Persisted to
    /// `<data_root>/aria2_port`; effective on next launch.
    aria2_port_buf: [8]u8 = [_]u8{0} ** 8,
    /// Last-persisted port (mirrored from disk via RuntimeInfo). Used
    /// to render the "(restart required)" hint when the buffer differs.
    aria2_port_persisted: u16 = 0,
    /// Short message after Save click in the Downloads settings tab.
    aria2_port_msg_buf: [80]u8 = [_]u8{0} ** 80,
    aria2_port_msg_len: usize = 0,
    /// Editable buffer for the Settings → Downloads seed-ratio field.
    /// Float like "5.0". Floor 2.0 enforced on Save.
    aria2_seed_ratio_buf: [16]u8 = [_]u8{0} ** 16,
    aria2_seed_ratio_persisted: f32 = 5.0,
    aria2_seed_ratio_msg_buf: [80]u8 = [_]u8{0} ** 80,
    aria2_seed_ratio_msg_len: usize = 0,
    /// Browser path buffer (settings → "Browser"). Filled at startup
    /// from `RuntimeInfo.initial_browser_path`; the dropdown copies
    /// detected paths into it. `actions.openInBrowser` reads from here.
    browser_path_buf: [512]u8 = [_]u8{0} ** 512,
    /// "OK" / error message after a browser save click.
    browser_msg: buf_mod.MessageBuf(80) = .{},
    /// F95 login form state.
    f95_user_buf: [128]u8 = [_]u8{0} ** 128,
    f95_pass_buf: [128]u8 = [_]u8{0} ** 128,
    login_status: LoginStatus = .unknown,
    login_msg: buf_mod.MessageBuf(128) = .{},
    /// In-flight bookmarks pull (worker thread). `actions.zig` defines
    /// the actual job struct.
    pending_bookmarks: ?*owned.BookmarksJob = null,
    /// RPDL credentials + status, mirroring the F95 section above.
    /// `rpdl_token` is heap-owned (`lib.alloc`), populated on Login or
    /// from `<config>/f69/rpdl_token` at startup; freed on quit. The
    /// per-game Download action reads this when an `.rpdl` source is
    /// dispatched.
    rpdl_user_buf: [128]u8 = [_]u8{0} ** 128,
    rpdl_pass_buf: [128]u8 = [_]u8{0} ** 128,
    rpdl_status: LoginStatus = .unknown,
    rpdl_msg: buf_mod.MessageBuf(128) = .{},
    rpdl_token: ?[]u8 = null,
    bookmarks_msg: buf_mod.MessageBuf(160) = .{},
    /// Mirrored from the worker's atomic fields each frame so the
    /// progress widget can read plain `u32`s.
    bookmarks_progress_current: u32 = 0,
    bookmarks_progress_total: u32 = 0,
    /// Job ids whose terminal status (.done OR .failed) has been
    /// processed by the post-install / fallback drainer. Lazy-init
    /// on first use.
    post_installed: ?*owned.PostInstalledSet = null,
    /// Per-game F95-thread-id → index into `recipe.sources[]` we're
    /// currently downloading. Bumped on each `.failed` to point at the
    /// next mirror. Lazy-init like `post_installed`.
    download_attempts: ?*owned.AttemptsMap = null,
    /// "Auto-convert new installs" toggle. When true, the post-
    /// install pipeline runs Convert immediately after an extract
    /// finishes (for games that have a recipe with `convert_linux`).
    /// Default off — Convert pulls SDKs and can be slow, so let
    /// the user opt in. Persisted under `<data_root>/auto_convert`.
    auto_convert: bool = false,
    auto_convert_persisted: bool = false,
    /// Global default for "sandbox on launch". Each game's per-game
    /// `SandboxOverride` (always / never / use_default) wins over this;
    /// only `use_default` consults the value here. Default on — the
    /// safer choice for unknown payloads. Persisted under
    /// `<data_root>/sandbox_default`.
    sandbox_default: bool = true,
    sandbox_default_persisted: bool = true,
    /// Global default for "auto-download updates on sync". Each game's
    /// `AutoUpdateOverride` wins; only `.use_default` consults this.
    /// Default off — auto-downloading in the background = bandwidth +
    /// disk surprises. User opts in via Settings → General. Persisted
    /// under `<data_root>/auto_update_default`.
    auto_update_default: bool = false,
    auto_update_default_persisted: bool = false,
    /// Per-game F95-thread-id → host PID of the currently-launched
    /// game. Populated by `doLaunchGame`, consumed by `doStopGame` +
    /// the detail screen (Launch ↔ Stop button swap). Pruned each
    /// frame by `drainRunningGames` via `kill(pid, 0)` probe. Lazy-
    /// init.
    running_games: ?*owned.RunningGamesMap = null,
    /// Active toast notifications, newest at index 0. Three separate
    /// `launch_msg` / `convert_msg` / `download_msg` buffers used to
    /// fight for a single status-line slot — now they all push to
    /// this stack and the global `renderToasts` overlay displays them
    /// kind-appropriately. Drains via `actions.drainExpiredToasts`
    /// each frame.
    toasts: [MAX_TOASTS]Toast = [_]Toast{.{}} ** MAX_TOASTS,
    toast_count: usize = 0,
    /// Persistent rect for the toast `floatingWindow`. We overwrite
    /// it every frame to keep the strip anchored at the bottom of the
    /// dvui window — without this, `floatingWindow` would auto-center
    /// on first frame and the toasts would land in the middle of the
    /// detail page (the original complaint).
    toast_rect: dvui.Rect = .{},

    // ============================================================
    //  Modfiles tab + recipe wizard
    // ============================================================

    /// Per-game modfile list cache. Owned by `lib.alloc`. Refilled on
    /// tab open + after Add / Scan / Delete actions. Null when not
    /// loaded; empty slice means "loaded, no entries yet."
    modfile_cache_thread: ?u64 = null,
    /// Heap-allocated list of Modfile records. Lazy-init.
    modfile_cache: ?*owned.ModfileCache = null,

    /// Per-game cache of the parsed game.zon + parsed mod.zon list +
    /// per-mod install/archive flags + computed tab counts shown on
    /// the Mods page. Without this, every render frame (including
    /// mouse-move) re-iterates the recipes dir, re-parses every ZON
    /// file, AND reloads the install tracker per mod — a noticeable
    /// stutter even with a few dozen mods. Invalidated whenever the
    /// modfile cache is dropped (covers every mutating action) plus
    /// on thread/install-selection switch (handled in modsScreen).
    /// Owned by `lib.alloc`; cast in actions.zig.
    mods_page_cache_thread: ?u64 = null,
    /// Buffer holding the install-id this cache was built against.
    /// Stored as a fixed buffer so we can compare without allocating.
    /// Length 0 = "no install selected" (cache built without an
    /// install context — happens when no installs exist for the game).
    mods_page_cache_install_id_buf: [64]u8 = [_]u8{0} ** 64,
    mods_page_cache_install_id_len: usize = 0,
    mods_page_cache: ?*owned.ModsPageCache = null,
    /// Scan in flight — UI greys the Scan button + shows a status row.
    modfile_scan_busy: bool = false,
    /// Last scan summary message ("Added N, skipped M, …") shown after
    /// a Scan run completes.
    modfile_scan_msg: buf_mod.MessageBuf(256) = .{},
    /// Modfile id currently waiting for a confirm-delete press. UI
    /// flips the row's button to "Confirm delete" when set; any other
    /// click clears it. `null` = idle.
    modfile_pending_delete_id_buf: [64]u8 = [_]u8{0} ** 64,
    modfile_pending_delete_id_len: usize = 0,

    /// User-preset id currently armed for delete. Separate from the
    /// modfile buffer so a preset id can't accidentally collide with
    /// a modfile id (different name spaces, but both go through the
    /// same two-click pattern).
    preset_pending_delete_id_buf: [128]u8 = [_]u8{0} ** 128,
    preset_pending_delete_id_len: usize = 0,

    /// Cached `recipe.MergedPresetSet`. Filled lazily on first access
    /// via `getMergedPresets`; invalidated by `invalidatePresetCache`
    /// after any write to `<data_root>/mod-presets/`. `null` = unloaded.
    preset_cache: ?*owned.MergedPresetSet = null,

    /// In-flight `TestInstallJob` for the wizard's Review-step "Test
    /// install (real)" button. `*anyopaque` for the same reason as
    /// `preset_cache` — keeps installer / recipe types out of state.zig.
    /// Drained per frame from `guiFrame`; null when idle.
    test_install_job: ?*owned.TestInstallJob = null,

    /// Recipe wizard — drives the multi-step modal that turns a
    /// modfile into a `.mod.zon`. Null = wizard closed.
    wizard: ?WizardState = null,

    /// File-clash modal state. Set by `doInstallMod` when the
    /// declared-files conflict scan finds collisions; cleared by the
    /// modal on cancel / accept. `*anyopaque` for the same reason as
    /// `modfile_cache` — keeps installer types out of state.zig.
    clash_modal: ?*owned.ClashModalState = null,

    pub fn importMsg(self: *const State) []const u8 {
        return self.import_msg.read();
    }
    pub fn setImportMsg(self: *State, msg: []const u8) void {
        self.import_msg.write(msg);
    }

    pub fn importBufSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.import_buf, 0) orelse self.import_buf.len;
        return self.import_buf[0..end];
    }

    pub fn syncMsg(self: *const State) []const u8 {
        return self.sync_msg.read();
    }
    pub fn setSyncMsg(self: *State, msg: []const u8) void {
        self.sync_msg.write(msg);
    }

    pub fn currentSyncName(self: *const State) []const u8 {
        return self.active_sync_name.read();
    }
    pub fn setCurrentSyncName(self: *State, name: []const u8) void {
        self.active_sync_name.write(name);
    }

    pub fn currentImageName(self: *const State) []const u8 {
        return self.image_active_name.read();
    }
    pub fn setCurrentImageName(self: *State, name: []const u8) void {
        self.image_active_name.write(name);
    }

    pub fn searchSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.search_buf, 0) orelse self.search_buf.len;
        return std.mem.trim(u8, self.search_buf[0..end], " \t");
    }

    pub fn dlUrlSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.dl_url_buf, 0) orelse self.dl_url_buf.len;
        return self.dl_url_buf[0..end];
    }

    pub fn loginMsg(self: *const State) []const u8 {
        return self.login_msg.read();
    }
    pub fn setLoginMsg(self: *State, msg: []const u8) void {
        self.login_msg.write(msg);
    }

    pub fn f95UserSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.f95_user_buf, 0) orelse self.f95_user_buf.len;
        return self.f95_user_buf[0..end];
    }
    pub fn f95PassSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.f95_pass_buf, 0) orelse self.f95_pass_buf.len;
        return self.f95_pass_buf[0..end];
    }

    pub fn rpdlUserSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.rpdl_user_buf, 0) orelse self.rpdl_user_buf.len;
        return self.rpdl_user_buf[0..end];
    }
    pub fn rpdlPassSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.rpdl_pass_buf, 0) orelse self.rpdl_pass_buf.len;
        return self.rpdl_pass_buf[0..end];
    }
    pub fn rpdlMsg(self: *const State) []const u8 {
        return self.rpdl_msg.read();
    }
    pub fn setRpdlMsg(self: *State, msg: []const u8) void {
        self.rpdl_msg.write(msg);
    }

    pub fn bookmarksMsg(self: *const State) []const u8 {
        return self.bookmarks_msg.read();
    }
    pub fn setBookmarksMsg(self: *State, msg: []const u8) void {
        self.bookmarks_msg.write(msg);
    }

    /// Push a toast onto the stack. Newest at index 0. When already
    /// at `MAX_TOASTS`, drops the oldest NON-ERR toast (errors stick
    /// until clicked); if every slot is an error, replaces the
    /// oldest error so we never lose newer error signal.
    pub fn pushToast(self: *State, kind: ToastKind, message: []const u8) void {
        var evict: usize = self.toast_count;
        if (evict >= MAX_TOASTS) {
            evict = MAX_TOASTS - 1;
            // Walk from oldest (tail) toward newest, find a non-err
            // we can stomp. Skip-err keeps user-facing errors visible.
            var i: usize = MAX_TOASTS;
            while (i > 0) : (i -= 1) {
                const idx = i - 1;
                if (self.toasts[idx].kind != .err) {
                    evict = idx;
                    break;
                }
            }
        }
        // Shift everything from 0..evict one slot down so the new
        // entry can land at index 0.
        var j: usize = evict;
        while (j > 0) : (j -= 1) {
            self.toasts[j] = self.toasts[j - 1];
        }
        var t: Toast = .{ .kind = kind };
        const n = @min(message.len, t.buf.len);
        @memcpy(t.buf[0..n], message[0..n]);
        t.len = n;
        t.ttl_frames = switch (kind) {
            .info => TOAST_TTL_INFO,
            .success => TOAST_TTL_SUCCESS,
            .warn => TOAST_TTL_WARN,
            .err => TOAST_TTL_ERR,
        };
        self.toasts[0] = t;
        if (self.toast_count < MAX_TOASTS) self.toast_count += 1;
    }

    /// Decrement every active toast's TTL by one. Removes any that
    /// hit zero. Persistent (err) toasts skipped. Called from the
    /// main loop each frame.
    pub fn ageToasts(self: *State) void {
        var i: usize = 0;
        while (i < self.toast_count) {
            const t = &self.toasts[i];
            if (t.ttl_frames == std.math.maxInt(u32)) {
                i += 1;
                continue;
            }
            if (t.ttl_frames > 1) {
                t.ttl_frames -= 1;
                i += 1;
                continue;
            }
            // Expired — drop in place.
            self.dismissToast(i);
            // Don't bump i; dismiss shifted everything up by one.
        }
    }

    // ============================================================
    //  Canonical notification service. New code should use these
    //  four entry points; everything else (pushToast, the
    //  setLaunchMsg/setDownloadMsg/setConvertMsg shims below) is
    //  kept working for legacy callers but routes through here.
    //
    //  All four are tied to the toast renderer at the bottom of the
    //  app window — auto-expire after a kind-specific TTL, click to
    //  dismiss early. Same lifecycle for every screen.
    // ============================================================

    /// Bookkeeping nudge ("Queued sync for 14014"). Shortest TTL.
    pub fn notifyInfo(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.info, message);
    }
    /// Confirms a user-initiated action that succeeded ("Renamed.").
    pub fn notifyOk(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.success, message);
    }
    /// Non-fatal hint the user might want to act on. Mid-length TTL.
    pub fn notifyWarn(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.warn, message);
    }
    /// A failure the user needs to see. Long TTL, auto-clears.
    pub fn notifyErr(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.err, message);
    }

    // ----- compatibility shims -----
    // The old launch_msg / download_msg / convert_msg pattern lived
    // for ~50 callers. Rather than churn every one we route them
    // through the new toast pipeline. Kind picked by a small sniff
    // ("failed" / "error" → err, otherwise info). Callers can opt
    // into more precise kinds by calling `notifyOk` / `notifyErr` /
    // `notifyWarn` / `notifyInfo` directly.
    pub fn setLaunchMsg(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(sniffKind(message), message);
    }
    pub fn setDownloadMsg(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(sniffKind(message), message);
    }
    pub fn setConvertMsg(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(sniffKind(message), message);
    }

    /// Remove the toast at `index`, shifting the rest up. UI calls
    /// this when the user clicks the ✕ on an error toast.
    pub fn dismissToast(self: *State, index: usize) void {
        if (index >= self.toast_count) return;
        var i: usize = index;
        while (i + 1 < self.toast_count) : (i += 1) {
            self.toasts[i] = self.toasts[i + 1];
        }
        self.toasts[self.toast_count - 1] = .{};
        self.toast_count -= 1;
    }

    /// Drop every active toast. Used on hard resets (app shutdown).
    /// Use `clearTransientToasts` for normal navigation — that keeps
    /// `.err` so the user doesn't lose a failure they haven't seen.
    pub fn clearToasts(self: *State) void {
        var i: usize = 0;
        while (i < MAX_TOASTS) : (i += 1) self.toasts[i] = .{};
        self.toast_count = 0;
    }

    /// Drop info / success / warn toasts; keep errors. Called on
    /// per-game navigation so transient confirmations don't bleed
    /// between games but real failures stick around until the user
    /// acknowledges them.
    pub fn clearTransientToasts(self: *State) void {
        var write: usize = 0;
        for (self.toasts[0..self.toast_count]) |t| {
            if (t.kind == .err) {
                self.toasts[write] = t;
                write += 1;
            }
        }
        var i: usize = write;
        while (i < MAX_TOASTS) : (i += 1) self.toasts[i] = .{};
        self.toast_count = write;
    }

    pub fn toastSlice(self: *const State) []const Toast {
        return self.toasts[0..self.toast_count];
    }

    pub fn browserPathSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.browser_path_buf, 0) orelse self.browser_path_buf.len;
        return self.browser_path_buf[0..end];
    }
    pub fn setBrowserPath(self: *State, p: []const u8) void {
        // `p` may alias `browser_path_buf` — `saveBrowserPath` calls
        // this with the trimmed slice from the same buffer. `memcpy`
        // forbids overlap; `copyForwards` is the documented escape
        // hatch when dst.ptr <= src.ptr (which is always our case
        // here since the dest is the buffer's head).
        const n = @min(p.len, self.browser_path_buf.len - 1);
        if (n > 0) std.mem.copyForwards(u8, self.browser_path_buf[0..n], p[0..n]);
        // Zero out everything past the new content so `browserPathSlice`
        // returns the right length on next read.
        @memset(self.browser_path_buf[n..], 0);
    }

    /// Trimmed slice of the manual-install path buffer up to the
    /// first NUL or end-of-buffer. Buffer holds a NUL-terminated
    /// string that the textEntry widget edits in place.
    pub fn manualInstallPathSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manual_install_path_buf, 0) orelse self.manual_install_path_buf.len;
        return self.manual_install_path_buf[0..end];
    }

    pub fn manualInstallVersionSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manual_install_version_buf, 0) orelse self.manual_install_version_buf.len;
        return self.manual_install_version_buf[0..end];
    }

    pub fn manualInstallNameSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manual_install_name_buf, 0) orelse self.manual_install_name_buf.len;
        return self.manual_install_name_buf[0..end];
    }

    /// Reset the manual-install panel's text fields (path / version /
    /// name) back to empty. Called after a successful enqueue so the
    /// user can immediately install a second archive without having
    /// to clear three fields by hand.
    pub fn resetManualInstallFields(self: *State) void {
        @memset(&self.manual_install_path_buf, 0);
        @memset(&self.manual_install_version_buf, 0);
        @memset(&self.manual_install_name_buf, 0);
    }

    pub fn browserMsg(self: *const State) []const u8 {
        return self.browser_msg.read();
    }
    pub fn setBrowserMsg(self: *State, msg: []const u8) void {
        self.browser_msg.write(msg);
    }

    /// Reset every UI field scoped to a single detail page. Called
    /// when the user navigates from one game's detail to another's so
    /// the new page opens with the default tab, default scroll, no
    /// stale popups, and no leftover status lines from the previous
    /// game. `carousel_*` and `notes_*` have their own per-thread
    /// guards and reset themselves; everything else lives here.
    pub fn resetDetailViewState(self: *State) void {
        self.detail_tab = .overview;
        self.detail_scroll = .{};
        self.confirm_delete = false;
        self.convert_help_open = false;
        self.image_popup_open = false;
        // Drop info / success / warn toasts so stale per-game
        // confirmations don't bleed across navigation. Errors stick
        // — the user hasn't acknowledged them yet, and silently
        // dropping them would mask real failures.
        self.clearTransientToasts();
        self.detail_picker_install_id = null;
        self.mods_page_install_id = null;
        self.mods_tab = .installed;
        self.manage_action = .none;
        self.manage_install_id = null;
        @memset(&self.manage_rename_buf, 0);
    }

    pub fn manageRenameSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manage_rename_buf, 0) orelse self.manage_rename_buf.len;
        return self.manage_rename_buf[0..end];
    }

    /// Active arming target for the preset-delete two-click. Empty
    /// slice = nothing armed.
    pub fn presetPendingDeleteSlice(self: *const State) []const u8 {
        return self.preset_pending_delete_id_buf[0..self.preset_pending_delete_id_len];
    }

    pub fn armPresetDelete(self: *State, preset_id: []const u8) void {
        @memset(&self.preset_pending_delete_id_buf, 0);
        const n = @min(preset_id.len, self.preset_pending_delete_id_buf.len);
        @memcpy(self.preset_pending_delete_id_buf[0..n], preset_id[0..n]);
        self.preset_pending_delete_id_len = n;
    }

    pub fn clearPresetDeleteArm(self: *State) void {
        @memset(&self.preset_pending_delete_id_buf, 0);
        self.preset_pending_delete_id_len = 0;
    }
};

/// Best-effort kind detection for the compat-shim setters. Looks for
/// "fail" / "error" / "denied" / "not found" / "missing" / "no recipe"
/// — sticks the toast in the persistent `err` bucket so the user
/// can't miss the failure. Anything else → `info`. Callers that know
/// better should call `pushToast(.warn|.success, ...)` directly.
fn sniffKind(message: []const u8) ToastKind {
    var lower_buf: [128]u8 = undefined;
    const n = @min(message.len, lower_buf.len);
    for (message[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];
    const err_markers = [_][]const u8{ "fail", "error", "couldn't", "denied", "not found", "missing", "no recipe", "no install" };
    for (err_markers) |m| {
        if (std.mem.indexOf(u8, lower, m) != null) return .err;
    }
    return .info;
}

test "Filters.empty" {
    const f1 = Filters{};
    try std.testing.expect(f1.empty());
    const f2 = Filters{ .min_rating = 4.0 };
    try std.testing.expect(!f2.empty());
}

test "Filters.match rating gate" {
    const g = library.Game{ .f95_thread_id = 1, .name = "x", .rating = 3.0 };
    try std.testing.expect((Filters{}).match(&g));
    try std.testing.expect(!(Filters{ .min_rating = 4.0 }).match(&g));
    try std.testing.expect((Filters{ .min_rating = 2.0 }).match(&g));
}
