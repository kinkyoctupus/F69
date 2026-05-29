// Shared UI types + small utilities used by both `screens.zig` and
// the per-domain modules under `actions/`. Keeps the dependency graph
// one-way:
//
//     types.zig
//       │
//       ├── actions/*.zig (re-exported via actions.zig wall)
//       │     │
//       └─────┴── screens.zig
//                  │
//                  └── ui.zig (entry point + dispatcher)
//
// No file imports `ui.zig`, so there are no module cycles.

const std = @import("std");
const library = @import("library");
const f95 = @import("f95");
const f95_indexer = @import("f95_indexer");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox = @import("sandbox");
const convert = @import("convert");
const compat = @import("compat");
const dvui = @import("dvui");
const state_mod = @import("state.zig");
const mod_job_queue = @import("mod_job_queue.zig");

pub const State = state_mod.State;

const lat_log = std.log.scoped(.latency);

/// Threshold in milliseconds above which a timed section emits a log
/// line. 16ms ≈ one 60 Hz frame; 50ms is when users start to perceive
/// lag. Tune up if logs get too chatty during normal use.
pub const LATENCY_THRESHOLD_MS: u64 = 16;

/// Capture a timestamp for later `endLatency` measurement. No alloc,
/// no work beyond a clock read.
pub fn startLatency(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .real);
}

/// Compare against `start` and emit a log line if the elapsed time
/// exceeds `LATENCY_THRESHOLD_MS`. Cheap when fast (just a clock read
/// + subtract), only logs when slow.
pub fn endLatency(io: std.Io, start: std.Io.Clock.Timestamp, label: []const u8) void {
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const delta_ns: i128 = now.raw.toNanoseconds() - start.raw.toNanoseconds();
    if (delta_ns <= 0) return;
    const ms: u64 = @intCast(@divTrunc(delta_ns, 1_000_000));
    if (ms >= LATENCY_THRESHOLD_MS) {
        lat_log.info("{s}: {d} ms", .{ label, ms });
    }
}

/// Per-frame context. `runMainLoop` builds one each iteration and hands
/// it to screen + action functions. Pointers borrow runMainLoop's locals;
/// no heap involved.
pub const Frame = struct {
    state: *State,
    games: []library.Game,
    lib: *library.Library,
    f95_svc: *f95.Service,
    /// F95Indexer cache API client. Used by the refresh worker when
    /// `state.refresh_backend == .indexer` (the default). Auth-free;
    /// independent of `f95_svc.client.cookie`. Always non-null — the
    /// scraper backend just doesn't touch it.
    f95_indexer_client: *f95_indexer.Client,
    dl_mgr: *downloads.Manager,
    /// Local recipes repo — used by the per-game Download button to
    /// resolve a game's recipe + sources at click time.
    recipe_repo: *recipe.Repo,
    /// Sandbox backend (bwrap / sandboxie / none). The Launch button
    /// hands a `SandboxConfig` built from the recipe to this.
    sandbox: *sandbox.Sandbox,
    /// Always-`NoSandbox` instance used when the user has opted out
    /// of sandboxing for this launch (per-game `.never` override, or
    /// `.use_default` with the global toggle off). Routed-through with
    /// an empty `sandbox_home` so the game sees the host `$HOME`.
    host_launcher: *sandbox.NoSandbox,
    /// Convert service. The Convert button hands `(install_dir, spec)`
    /// to this to run Ren'Py / RPGM Win→Linux conversion.
    convert_svc: *convert.Service,
    /// Compat service. Detects host-compat issues against an install
    /// (e.g. NixOS bundled-SDL2 X11/Wayland dlopen failure) and
    /// applies env-injection / file-patching fixes. The Launch flow
    /// composes its env_extra from the install's applied fixes.
    compat_svc: *compat.Service,
    /// Pointer to the dvui Window — needed so worker threads can call
    /// `dvui.refresh(win, …)` and wake the UI loop out of its event
    /// wait. The UI thread itself doesn't dereference it.
    win: *dvui.Window,
    /// Process Io vtable — reused for file reads on the UI thread and
    /// for worker-thread HTTP fetches (`f95.Client` already owns its
    /// own reference; this is just a shortcut for one-shot ops).
    io: std.Io,
    /// Long-lived FIFO queue + worker thread for mod install/uninstall.
    /// All `actions.doInstallMod` / `doUninstallMod` calls enqueue here
    /// instead of running synchronously, so 15GB mods don't lock the UI.
    mod_jobs: *mod_job_queue.Queue,
    info: RuntimeInfo,
    /// Per-frame snapshot of `(game_thread_id → latest install version
    /// string)`. Built once by `guiFrame` from a single SELECT over
    /// the `installs` table (see `Library.latestInstallVersionMap`);
    /// readers do an O(1) lookup instead of a fresh SQL prepare+step
    /// per card. The backing storage lives in dvui's per-frame arena,
    /// so the pointer is **only valid during the current frame** —
    /// don't stash on `State` or on a job payload.
    install_versions: ?*const std.AutoHashMap(u64, []const u8) = null,
    /// Per-frame snapshot of `(thread_id → *Game)` into `games`.
    /// `gameByThreadId` reads from this; built once by `guiFrame`
    /// from dvui's per-frame arena. Same lifetime rules as
    /// `install_versions` — valid only for the current frame.
    /// The value type is `*library.Game` (mutable) to match the
    /// linear-scan call sites; readers that want `const` can
    /// re-cast at the use site.
    games_by_thread: ?*const std.AutoHashMap(u64, *library.Game) = null,
};

/// One detected browser. `path` is the absolute exe path; `display`
/// is a human-friendly name for the dropdown.
pub const Browser = struct {
    display: []const u8,
    path: []const u8,
};

pub const RuntimeInfo = struct {
    /// Directory holding the f69 executable (or `$F69_EXE_DIR` when
    /// set by `run.sh`). Used to discover sibling files: the bundled
    /// `aria2c`, user-dropped fonts under `<exe_dir>/fonts/`, etc.
    exe_dir: []const u8,
    /// `<exe_dir>/data/` (or `$F69_DATA_DIR`). Single root for every
    /// path below — DB, covers, library, recipes, caches, cookies,
    /// tokens, save backups. Portable: drop the f69 folder anywhere
    /// and it travels with its data.
    data_root: []const u8,
    db_path: []const u8,
    covers_dir: []const u8,
    library_root: []const u8,
    /// `<config>/f69/f95_cookie` — login state lives here so it
    /// survives across restarts.
    cookie_path: []const u8,
    /// `<config>/f69/recipes` — directory holding `<id>.game.zon` /
    /// `<id>.mod.zon` files. Phase 2 wiring.
    recipes_dir: []const u8,
    /// `<data_root>/mod-archives` — user-supplied mod archives, one
    /// per mod thread id. Owned by f69 once moved here; never
    /// auto-deleted.
    mod_archives_dir: []const u8,
    /// `<data_root>/mod-presets` — user-authored install presets that
    /// extend / override the bundled built-ins. Discovered by
    /// `recipe.loadUserPresets`.
    mod_presets_dir: []const u8,
    /// `<data_root>/convert-presets` — user-authored Win→Linux
    /// convert strategies. Bundled defaults cover the common cases;
    /// users can add `*.preset.zon` files here to extend.
    convert_presets_dir: []const u8,
    /// `<config>/f69/browser` — single-line file holding the user's
    /// chosen browser executable path.
    browser_path_file: []const u8,
    /// Detected browsers (xdg-open + system browsers in PATH).
    browsers: []const Browser,
    /// The browser path as loaded from disk at startup; State copies
    /// this into a mutable buffer for the settings UI to edit.
    initial_browser_path: []const u8,
    rate_limit_ms: u64,
    /// `<config>/f69/rpdl_token` — plain-text file the RPDL Settings
    /// section persists the bearer token to. Path; the actual token
    /// lives in `state.rpdl_token` and is heap-owned by State.
    rpdl_token_path: []const u8,
    /// `<data_root>/ui_scale` — single-line file with the user's
    /// preferred dvui content_scale (e.g. "1.25"). Settings exposes
    /// a slider that writes here and bumps `state.ui_scale` so the
    /// new scale takes effect from the next frame.
    ui_scale_path: []const u8,
    /// UI scale loaded from disk at startup. State copies this into
    /// `state.ui_scale`; the main loop pushes the current value into
    /// `Window.content_scale` every frame.
    initial_ui_scale: f32,
    /// `<data_root>/last_update_check` — single-line file storing the
    /// unix-seconds timestamp of the most recent successful
    /// "check updates" walk. The walker uses this as its
    /// stop-condition; entries older than this on the F95 latest
    /// page mean we've already seen them.
    last_update_check_path: []const u8,
    /// Bootstrap value for `state.last_update_check_ts`. 0 = never
    /// checked; the worker will default to "now - 14 days" so the
    /// first run doesn't blast pages all the way back to year 0.
    initial_last_update_check_ts: i64,
    /// `<data_root>/auto_check` — key=value file with the
    /// auto-update-check preferences. See `loadAutoCheck` in main.zig
    /// for the format.
    auto_check_path: []const u8,
    initial_auto_check: state_mod.AutoCheckSettings,
    /// `<data_root>/auto_convert` — single-line `true` / `false`.
    /// When true, post-install fires Convert as soon as the extract
    /// worker reports done. Default false.
    auto_convert_path: []const u8,
    initial_auto_convert: bool,
    /// `<data_root>/auto_apply_compat` — single-line `true`/`false`.
    /// When true, every successful Convert (manual or auto) is
    /// followed by a compat scan + apply of every unfixed issue,
    /// and re-apply of any fixed issue whose recipe sha changed
    /// since the apply. Default true.
    auto_apply_compat_path: []const u8,
    initial_auto_apply_compat: bool,
    /// `<data_root>/sandbox_default` — single-line `true` / `false`.
    /// Global "sandbox on launch" preference. Per-game
    /// `SandboxOverride` (always / never / use_default) wins;
    /// only `.use_default` consults this. Default true.
    sandbox_default_path: []const u8,
    initial_sandbox_default: bool,
    /// `<data_root>/auto_update_default` — single-line `true`/`false`.
    /// Global "auto-download updates on sync" preference. Per-game
    /// `AutoUpdateOverride` wins; only `.use_default` consults this.
    /// Default false.
    auto_update_default_path: []const u8,
    initial_auto_update_default: bool,
    /// `<data_root>/refresh_backend` — single-line `indexer` / `scraper`.
    /// Picks which backend the refresh worker uses. Default `.indexer`
    /// (F95Indexer cache at `api.f95checker.dev`). Settings → Sync row
    /// writes here.
    refresh_backend_path: []const u8,
    initial_refresh_backend: state_mod.RefreshBackend,
    /// `<data_root>/max_parallel_sync` — single-line integer (1..16).
    /// Effective concurrency of the `/full` + scrape worker pool.
    /// Default 4. Settings → Sync row writes here.
    max_parallel_sync_path: []const u8,
    initial_max_parallel_sync: u32,
    /// `<data_root>/max_parallel_image` — single-line integer (1..16).
    /// Effective concurrency of the screenshot ImageJob pool.
    /// Default 4. Settings → Sync row writes here.
    max_parallel_image_path: []const u8,
    initial_max_parallel_image: u32,
    /// `<data_root>/min_session_seconds` — single-line integer (0..1800).
    /// Sessions shorter than this do not count as "played". Default 60.
    /// Evaluated at session close; past counts_as_played values are not
    /// retroactively updated when this setting changes.
    min_session_seconds_path: []const u8,
    initial_min_session_seconds: u32,
    /// `<data_root>/tags.txt` — cache of F95's master tag list.
    /// Newline-separated, first line `# fetched: <unix-secs>`.
    tags_master_path: []const u8,
    /// `<data_root>/aria2_port` — single-line file with the user's
    /// preferred aria2 RPC port. Empty/0 = random ephemeral port.
    /// Settings → Downloads exposes a textEntry that rewrites this;
    /// changes take effect on the next launch.
    aria2_port_path: []const u8,
    /// Aria2 RPC port loaded from disk at startup. 0 ⇒ random.
    initial_aria2_port: u16,
    /// `<data_root>/aria2_seed_ratio` — single-line file with the
    /// user's preferred BT seed-ratio target (default 5.0, floor
    /// 2.0). Changes take effect on the next launch (daemon-wide
    /// --seed-ratio flag is set at spawn).
    aria2_seed_ratio_path: []const u8,
    /// Aria2 seed-ratio target loaded from disk at startup.
    initial_aria2_seed_ratio: f32,
    /// Snapshot of host env at process start — XDG_RUNTIME_DIR /
    /// WAYLAND_DISPLAY / DISPLAY / HOME. The sandbox backend uses
    /// these to wire display + audio + fontconfig binds.
    host: sandbox.HostInfo = .{},
};

// ============================================================
//  theme — sensual pink accents over Adwaita base
// ============================================================

/// Pink palette. Hot rose for focus/highlight, deep wine for text-select,
/// muted plum borders. Tuned to look at home on Adwaita Dark; Light mode
/// gets a slightly toned-down version for legibility on white.
pub fn pinkTheme(scheme: anytype) dvui.Theme {
    _ = scheme; // dvui.Theme has no built-in light variant of our pink
    // yet — keep dark base. Phase 1.5: per-scheme palette.
    var t = dvui.Theme.builtin.adwaita_dark;

    const accent: dvui.Color = .{ .r = 0xE9, .g = 0x4B, .b = 0x7A }; // rose
    const accent_hover: dvui.Color = .{ .r = 0xFF, .g = 0x6F, .b = 0x91 };
    const accent_press: dvui.Color = .{ .r = 0xC1, .g = 0x38, .b = 0x69 };
    const accent_border: dvui.Color = .{ .r = 0xFF, .g = 0x8F, .b = 0xAC };
    const wine: dvui.Color = .{ .r = 0x5C, .g = 0x2A, .b = 0x3D };

    t.focus = accent;
    t.text_select = wine;
    t.highlight = .{
        .fill = accent,
        .fill_hover = accent_hover,
        .fill_press = accent_press,
        .text = dvui.Color.white,
        .border = accent_border,
    };
    return t;
}

// ============================================================
//  string + time helpers
// ============================================================

pub fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

pub fn humanRelative(buf: []u8, delta_s: i64) ![]const u8 {
    if (delta_s < 0) return std.fmt.bufPrint(buf, "in {d}s", .{-delta_s});
    if (delta_s < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{delta_s});
    if (delta_s < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(delta_s, 60)});
    if (delta_s < 86400) return std.fmt.bufPrint(buf, "{d} h ago", .{@divTrunc(delta_s, 3600)});
    if (delta_s < 86400 * 30) return std.fmt.bufPrint(buf, "{d} d ago", .{@divTrunc(delta_s, 86400)});
    if (delta_s < 86400 * 365) return std.fmt.bufPrint(buf, "{d} mo ago", .{@divTrunc(delta_s, 86400 * 30)});
    return std.fmt.bufPrint(buf, "{d} y ago", .{@divTrunc(delta_s, 86400 * 365)});
}
