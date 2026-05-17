# f69 — Master Plan

This is the single source of truth for the project's design decisions and
phasing. Update it as decisions change.

## What this is

A native rewrite of XLibrary, scoped down to F95Zone-only with first-class
support for downloads, multi-version installs, mods (with dependency /
conflict resolution), Windows→Linux conversion, and sandboxed launch.

XLibrary is the reference for "what the app should look and feel like" but
not the reference for behavior — XLibrary is download/launch-naïve. We are
building a small declarative package manager on top of F95Zone.

## Hard constraints

- **Language:** Zig 0.16.0 (latest stable).
- **GUI:** dvui (SDL3 backend), pulled from main. No tagged release pinning.
- **DB:** zqlite (karlseguin) — actively maintained, transactions + blob
  handling + connection pool. Reject `vrischmann/zig-sqlite` despite
  comptime queries; maintainer is on hiatus.
- **Platforms:** Linux primary (Arch, Debian, Fedora, NixOS); Windows secondary.
- **No telemetry.** No phone-home. No auto-updater (we own the binary).

## Decisions confirmed

| Topic | Decision |
|---|---|
| F95Zone integration | Yes (only provider) |
| Steam / itch / GOG / DLsite | **Out** |
| Google Drive sync | **Out** |
| Bookmark import | Direct HTTP from app, libsecret-stored login cookie. **No extension dependency for v1.** |
| Browser extension | **Build our own** in phase 6+ as a sibling repo (`xlibrary-zig-extension`). MV3, F95-only scope. Pure polish — adds "Add to library" / "Sync this" buttons on F95 pages. App is fully functional without it. Reject reusing XLibrary's bundled `.xpi` (closed-source, lock-in to their RPC names). |
| Mass scrape with rate limit | Yes — single client chokepoint enforces 1500ms between f95zone.to requests |
| Game downloads | RPDL primary (torrents via aria2c subprocess), DDL fallback, public mirrors as link-list |
| Plain HTTP fallback | Yes — `handlers/http.zig` next to `handlers/aria2.zig`; user-toggleable per-source |
| Game updates | Install new version into separate dir, keep old, user re-picks mods |
| Mods | Yes, recipe-driven, with deps / conflicts / load-order |
| Recipe format | **ZON** (Zig Object Notation) — parsed via `std.zon.parse`. No custom lexer/parser/AST. Anti-RCE is enforced as a *schema* check in the validator regardless of format. |
| Recipe sources | Local files + auto-derived from F95 thread; **community repo deferred** |
| Conflict resolution | Backtracking-with-learning (Cargo-style), not SAT |
| Overlay strategy | **Flat-copy first** (works everywhere, build first). OverlayFS as later optimization — Debian/Ubuntu sysctl + AppArmor commonly block unprivileged userns mounts so flat-copy is the realistic common case. |
| Multi-version installs | Yes — each version is its own `Install` row + dir |
| Sandbox scope | **Per-game**, not per-install. Saves carry across versions. |
| Sandbox impl (Linux) | bubblewrap (`bwrap`) |
| Sandbox impl (Windows) | Sandboxie (sandboxie-plus) — user installs separately, we shell out to `Start.exe /box:<box> ...` |
| Sandbox default | Toggleable global setting + per-game override (always / never / use_default) |
| Win-only games on Linux | Recipe declares `convert linux { ... }` block; runtime downloads matching SDK/nwjs and bundles syslibs |
| Win→Linux SDK reference | Logic ported from user's `fix-linux-games.sh` and `nixos-libs.sh` |
| Auto-prune old installs | Default: never; opt-in `prune_old_after: 30d` |
| Token storage | libsecret / Secret Service (no plaintext default). XLibrary's plaintext model is the wrong default. |
| Save data location | Recipe carries an optional `.saves = .{ .linux = ..., .windows = ... }` block. UI exposes an "Open saves folder" button that resolves the path (under the sandbox HOME if sandboxed) and shells out to `xdg-open` / Explorer / `open`. Defaults are auto-derived per engine when omitted. |
| WS server bind | 127.0.0.1 only. XLibrary's 0.0.0.0 bind was a security finding from prior audit. |
| Concurrency | Single dedicated worker thread + per-job SPSC progress ring. UI thread reads via atomic snapshot pattern (one frame stale at most). No general thread pool yet. |
| Aria2 | RPC mode from day one (`--enable-rpc --rpc-listen-port=<random>` + JSON-RPC over HTTP). Stdout-parsing is brittle and version-coupled — skip it. |
| Schema migrations | Explicit `_schema_version` table + ordered up-migrations. Down-migrations only when destructive change is unavoidable. Migration failures fail-loud, not partial-state. |
| Settings versioning | `config.toml` carries a `version` field. Loader rejects newer versions, auto-migrates older ones. |
| Crash diagnostics | Custom `panic` handler writes `~/.cache/f69/crashes/<ts>.log` with stack + Zig version + git rev. No phone-home. |
| Natural keys | F95 thread id (integer) is the primary key for `games` and `mods` — both are 1:1 with an F95 thread. Synthetic UUIDs only for `installs` (composite of game + version is awkward as a foreign key). |

## Architecture

### Bounded contexts

Each context follows the same layout:

```
<context>/
  <context>.zig         ← public face: top-level type(s) + key call sites
  domain.zig            ← entity types (pure data, no IO)
  errors.zig            ← module-specific error set
  <internal>.zig        ← implementation files imported only within the context
```

**No Service-over-Repo passthroughs.** When a context's "service" would
just forward calls to the repo, collapse them into one type. We add a
distinct `Service` only when there's real cross-repo orchestration — for
now that's just `installer/installer.zig` (which coordinates downloads
+ verify + apply + tracker + library updates).

**No public re-export walls.** `<context>.zig` exposes the top-level
struct(s) and the few helpers callers need; everything else stays
internal. Callers reach into `domain.zig` for pure types; the build
graph (`build.zig`) enforces module boundaries, not duplicated `pub`s.

The contexts:

| Context | Purpose |
|---|---|
| `library` | Game / Install / Mod entities + zqlite-backed `Library` (formerly Repo). The "core" domain. |
| `recipe` | ZON loader + validator + derive-from-scrape + local FS storage |
| `resolver` | Dependency / conflict resolution + topo sort. Pure logic, no IO. |
| `f95` | F95Zone HTTP client + scrapers (thread, bookmarks, latest_alpha API) |
| `downloads` | Job queue + handler vtable + per-host implementations |
| `installer` | Apply install plans, overlay layering, file tracker, uninstall |
| `convert` | Windows→Linux conversion (Ren'Py, RPGM MV/MZ) |
| `sandbox` | bwrap (Linux) / Sandboxie (Windows) launch wrappers |
| `server` | WebSocket + JSON-RPC server. Used by *our own* extension once we ship one (phase 6+). Out for v1 — defer the WS server until the extension exists. |
| `ui` | dvui screens (presentation only — never imports repository.zig). See "UI structure" below for layout. |

Plus root-level files:

| File | Purpose |
|---|---|
| `main.zig` | Entry point. Installs panic handler, parses args, loads config, builds `App`, runs UI. |
| `app.zig` | `App` struct — owns config + library + worker thread + per-job state snapshots. |
| `config.zig` | `AppConfig` struct + versioned load/save (TOML). |

### Polymorphism — vtable vs tagged union

Zig has no traits/interfaces. Two patterns; pick by **expected impl count**:

**Tagged union — closed sets (≤ a few impls), all known at compile time:**

```zig
pub const OverlayBackend = union(enum) {
    overlayfs: OverlayFs,
    flat: FlatCopy,

    pub fn layer(self: *OverlayBackend, base: []const u8, mods: []const []const u8, merged: []const u8) !void {
        return switch (self.*) {
            inline else => |*x| x.layer(base, mods, merged),
        };
    }
};
```

Used for:
- `installer/overlay.zig` — overlayfs vs flat-copy (only ever 2)
- `sandbox/sandbox.zig` — bwrap vs sandboxie (per-platform; only one ever
  active)

Compiler can devirtualize switch arms; exhaustive checking; no
`*anyopaque` dance.

**Vtable — open sets (n>2, plug-in shaped):**

```zig
pub const Handler = struct {
    ptr: *anyopaque,
    priority: u8,                       // lower runs first
    vtable: *const VTable,

    pub const VTable = struct {
        canHandle: *const fn (ptr: *anyopaque, url: []const u8) bool,
        download:  *const fn (ptr: *anyopaque, job: *Job) anyerror!void,
        deinit:    *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };
};
```

Used for:
- `downloads/handlers/*` — http, aria2, rpdl, mega, mediafire, gofile,
  pixeldrain, browser-fallback, etc. Open-ended, user-driven priority
  via the `priority: u8` field. Manager sorts on register; first match
  wins, but order is **explicit** not registration-order accident.

### Memory ownership rules

- Every `init` has a matching `deinit`. Document allocator ownership in
  the doc comment.
- Services own their repositories. Repositories own their connection
  handles. App owns services.
- Returned strings from repositories are caller-owned (use the same
  allocator that was passed into the call). Document with `// Caller
  frees.` comments.
- No globals. Allocator is always passed explicitly.

### Error sets

Each context has its own error set in `errors.zig`. Public functions
return `<Context>Error!T` rather than `anyerror!T`. This lets callers do
exhaustive switching.

```zig
// library/errors.zig
pub const Error = error{
    GameNotFound,
    InstallNotFound,
    DuplicateGame,
    InvalidVersion,
    DatabaseError,
};
```

### Logging

Use `std.log.scoped` directly at call sites. No central enum, no
wrapper module. Each file declares:

```zig
const log = std.log.scoped(.library);
log.info("loaded {d} games", .{count});
```

Scope tags are comptime strings, no registration needed.

### Configuration

`config.zig` defines the schema; loaded from `~/.config/f69/config.toml`
on startup, with env var overrides for select fields. Passed by
`*const AppConfig` to services that need it.

**Versioned.** First field is `version = N`. Loader:
- Newer-than-binary version → refuse to load, ask user to upgrade.
- Older version → run a migration chain (`config_migrations.zig`) to
  bring it forward; back up the original to `config.toml.v<N>.bak`.

Notable fields:
- `version` — config schema version (integer, current = 1)
- `library_root` — where games are installed (`~/games/f69/`)
- `cache_root` — where downloads stage (`~/.cache/f69/`)
- `recipe_local_dir` — where user-authored recipes live
- `f95_rate_limit_ms` — default 1500
- `sandbox_default` — bool, default true
- `prune_old_after_days` — default 0 (never)
- `prefer_native_http` — bool; if true, `handlers/http.zig` over `aria2.zig`
- `aria2_path` — override, otherwise PATH lookup
- `aria2_rpc_secret` — auto-generated random token; passed via `--rpc-secret`
- `bwrap_path` — override
- `sandboxie_path` — override (Windows)

## UI structure

Two top-level screens, one active at a time (no popups for primary
content):

```
Screen = enum { library, detail }
```

### Library screen

Three regions, all anchored:

```
┌──────────────────────────────────────────────────┐
│  Top bar: search, view-toggle, settings button   │
├────────────┬─────────────────────────────────────┤
│            │                                     │
│  Sidebar   │     Main area (grid OR list)        │
│  ────────  │     toggleable per the top bar      │
│  filters:  │                                     │
│  - engine  │                                     │
│  - status  │                                     │
│  - rating  │                                     │
│  - tags    │                                     │
│            │                                     │
└────────────┴─────────────────────────────────────┘
```

- **Top bar:** persistent. Search box, view toggle (Grid / List), Settings.
- **Sidebar:** persistent (collapsible later). Filter group lives here:
  engine, completion status, rating range, tags. Filter state is held in
  a single `Filters` struct in `ui/state.zig`. Multi-select is
  inclusive-OR within a group, AND across groups.
- **Main area:** displays the filtered/sorted game list, one of:
  - **Grid:** card layout (cover thumb + name + rating). Mirrors
    XLibrary's primary view.
  - **List:** dense rows (cover thumb + name + version + rating + status).
- View toggle persists in `AppConfig.last_view`.

### Detail screen

Replaces the entire library view (no floating window). Lays out:

```
┌──────────────────────────────────────────────────┐
│  Back   <Game name>            actions: …        │
├──────────────────────────────────────────────────┤
│ Cover  │  developer · version · rating          │
│        │  status   · sandbox · last played      │
├────────┴───────────────────────────────────────────
│ Tabs: Overview | Versions/Installs | Mods | Notes
├──────────────────────────────────────────────────┤
│  (selected tab content)                          │
└──────────────────────────────────────────────────┘
```

- **Back** returns to library screen, restoring scroll + filter state.
- **Versions/Installs tab:** list of `installs[]` for this game.
- **Mods tab:** load-order list per install, drag-to-reorder (phase 7).
- Detail view is responsible for the "Open saves folder" + "Sync rating"
  + "Launch" actions in its top action bar.

### State management

UI state (`ui/state.zig`) holds:

- `screen: Screen` — current screen
- `view: View` — `.grid | .list`, used in library screen
- `filters: Filters` — engine/status/rating/tag selections
- `search: []const u8` — search box content
- `selected_thread: ?u64` — which game's detail is open
- `library_scroll: f32` — saved on library→detail transition

UI is "immediate-mode driven by reactive state." Each frame reads the
state and re-renders. The state struct lives in App; UI mutates it in
event handlers; never reads through Library directly during render
(load games once, use the cached slice).

## Recipe format (ZON)

Recipes are **ZON files** (Zig Object Notation), parsed via `std.zon.parse`
into typed Zig structs declared in `recipe/domain.zig`. No custom lexer,
no AST builder, no error reporter — `std.zon` already gives us all of
that with line/col diagnostics.

This is a deliberate downgrade from the originally planned custom DSL.
A custom parser was 1500+ LOC of forever-maintenance for negligible UX
gain. ZON is Zig-native, the syntax is already familiar to anyone using
build.zig.zon, and the schema rules — including the anti-RCE constraint
(no `run`/`exec` step) — are enforced in `recipe/validator.zig` regardless
of surface format.

### Game recipe (game.zon)

```zig
.{
    .id = "summertime-saga",
    .name = "Summertime Saga",
    .f95_thread = 14014,
    .version = "0.20.17",
    .engine = .renpy,
    .engine_version = "7.5.3",

    .sources = .{
        .{ .rpdl = .{ .id = 67890, .sha256 = "a1b2c3..." } },
        .{ .ddl = .{ .url = "https://attachments.f95zone.to/2024/01/foo.zip", .sha256 = "a1b2c3..." } },
        .{ .mirror = .{ .url = "https://mega.nz/...", .host = .mega, .label = "PC" } },
    },

    .install = .{
        .{ .extract = .{ .to = ".", .strip = 1 } },
        .{ .chmod_x = .{ "SummertimeSaga.sh" } },
    },

    .convert_linux = .{ .renpy = .{ .sdk_version = "7.5.3" } },

    .launch = .{
        .linux = "./SummertimeSaga.sh",
        .windows = "./SummertimeSaga.exe",
    },

    .sandbox = .{
        .network = true,
        .bind_extra = .{},
    },

    // Where the game stores save data, relative to the sandboxed $HOME
    // (or the real $HOME / %APPDATA% if sandbox is off for this game).
    // Used by:
    //   - "Open saves folder" button in the UI (resolves + xdg-open)
    //   - backup / migrate-save-on-update flows
    //   - sanity check during install (we can pre-create the dir)
    // Engine-specific defaults are filled in by `recipe/derive.zig` if
    // the recipe author omits this block — Ren'Py defaults to
    // `~/.renpy/<save_dir>` (read from `game/script.rpy`/`options.rpy`),
    // RPGM MV/MZ to `<install>/www/save/` and `<install>/save/`.
    .saves = .{
        .linux   = "$XDG_DATA_HOME/RenPy/SummertimeSaga-1454697768",
        .windows = "%APPDATA%\\RenPy\\SummertimeSaga-1454697768",
    },

    .update_strategy = .new_install,
    .prune_old_after_days = 0,
}
```

### Mod recipe (mod.zon)

```zig
.{
    .id = "summertime-saga.cheat-menu",
    .name = "Cheat Menu Mod",
    .f95_thread = 67890,
    .version = "1.4.2",
    .for_game = "summertime-saga",
    .for_game_version = ">=0.20.0,<0.21.0",

    .requires = .{
        .{ .target = "summertime-saga.ren-py-mod-loader", .version = ">=2.0" },
    },
    .conflicts = .{ "summertime-saga.god-mode" },
    .provides = .{},
    .load_after = .{ "summertime-saga.ren-py-mod-loader" },
    .load_before = .{ "summertime-saga.bug-fixes" },

    .sources = .{ .{ .ddl = .{ .url = "...", .sha256 = "..." } } },
    .install = .{ .{ .extract = .{ .to = "./game/" } } },
}
```

### Version comparator

Try semver first, fall back to natural sort. Constraints: `>=`, `<=`, `>`,
`<`, `=`, `,` for AND. F95 uses messy versions ("Episode 12 Public",
"Final-1.0") — comparator must be lenient and document its semantics.

### Anti-RCE constraint (schema-enforced)

The struct shape doesn't include `run` / `exec` / `script` fields at
all — they're not representable. Install steps are a tagged union of
`extract` / `copy` / `move` / `chmod` / `delete` only. If a mod
genuinely needs custom work, the recipe author bundles it into the
archive and the *user* runs it explicitly post-install. Wabbajack made
the opposite call and now has supply-chain attack surface.

## Concurrency model

Single dedicated **worker thread** owns all blocking work (downloads,
scrapes, conversions, install plan execution). UI thread stays
exclusively in dvui's immediate-mode loop.

**Communication:** per-job **single-producer/single-consumer ring** in
`util/spsc.zig`. Worker writes progress events; UI drains the ring at
the start of each frame.

**Job state for UI:** **atomic snapshot** — worker maintains a heap-
allocated `JobState` per job and atomically swaps the `*JobState`
pointer when state changes. UI reads via `@atomicLoad` once per frame.
At most one frame stale; never torn.

The concurrency primitives live in `util/`:
- `util/spsc.zig` — `Ring(comptime T, cap)` with cache-padded head/tail
- `util/snapshot.zig` — `Snapshot(comptime T)` — atomic-pointer swap
- `util/db.zig` — thin wrapper around zqlite, provides a connection pool
  for read concurrency (writes serialize through the worker thread)

This is all v1 needs. A general thread pool can wait until phase 6+ when
batched scrapes and parallel mod resolution justify it.

## Updates polling

How tracked games learn there's a new release without re-scraping every
thread. Two reference clients give the bounds:

- **F95Checker** (https://github.com/Willy-JL/F95Checker, `modules/api.py`)
  offloads to its own indexer service (`api.f95checker.dev`, override via
  `F95INDEXER_URL`). Per refresh: `GET /fast?ids=A,B,C` → `{id:
  last_changed_unix}` for up to 10 ids, then `GET /full/{id}?ts={ts}` for
  the ones that changed. Per-game DB columns `last_full_check`,
  `last_check_version`, `last_updated`. Rate-limited 1 req / 2 s
  (`aiolimiter.AsyncLimiter`). **Not viable for us — we don't run that
  indexer service and don't want a third-party hop.**
- **XLibrary** (Electron, `dist-electron/main/index.js` scheduler +
  renderer's `fetchF95Data`) hits F95's `latest_alpha` JSON directly,
  walks pages from `msg.pagination.total` down, with a server-side
  `date={daysBack}` window. Single global `settings.lastUpdateCheckDate`,
  no per-game checkpoint, 1500 ms between requests, `daysBack =
  clamp(daysSinceLastCheck+1, 14, 30)` (first run = 30). Renderer-side
  case-insensitive version compare → `updateInfo[].hasUpdate`. We borrow
  the endpoint and sharpen the checkpointing.

### Endpoint
```
GET https://f95zone.to/sam/latest_alpha/latest_data.php
    ?cmd=list&cat=games
    &page={N}&rows=90
    &sort=date
    &date={days_back}
```
Returns `{status:"ok", msg:{count, pagination:{total,current},
data:[{thread_id, title, version, date, ts, prefixes, creator, ...}]}}`.
The `date={days_back}` query param is the server-side window — that's
our "stop paging" primitive. No client-side bookmark walk.

### Checkpoint storage
Two-tier:
- **Global** `settings.last_updates_poll_ts` (unix seconds) — drives the
  `days_back` for the next sweep.
- **Per-game** `games.last_seen_thread_ts INTEGER` (unix seconds) — the
  newest `ts` we've seen on the feed for that thread. Migration adds
  the column with default `0`. Lets us skip already-known bumps even
  when the feed re-lists the same thread (e.g. a comment bumped the
  timestamp by one second between sweeps).
- Two more columns for UI signal: `games.has_updates INTEGER NOT NULL
  DEFAULT 0` and `games.latest_seen_version TEXT NULL`. Cleared by the
  user clicking Sync (which writes the fresh version) or by an explicit
  "Mark seen" action.

### Stop-paging rule
- Compute `days_back = clamp(days_since_last_poll + 1, 1, 30)`. First
  ever run = 30 (matches XLibrary).
- `fetch(page=1)` → read `msg.pagination.total`.
- Iterate pages `1..total` (newest first means we hit dupes early and
  short-circuit the rest). For each entry:
  - lookup `Library.getGameByThreadId(thread_id)`. If absent → ignore
    (this is a polling pass, not a discovery pass; bookmark import
    handles discovery).
  - if `entry.ts <= game.last_seen_thread_ts` → skip (already
    accounted for).
  - if `entry.version != game.version` (case-insensitive trim) →
    `game.has_updates = 1`, `latest_seen_version = entry.version`.
    Don't auto-run sync — sync hits the thread page (heavy) and the
    user may want to read the changelog first.
  - update `last_seen_thread_ts = max(old, entry.ts)` regardless of
    version match (so we don't keep re-flagging the same bump).
- After all pages drained successfully → write
  `settings.last_updates_poll_ts = now`.
- On HTTP 429: bail the cycle (don't advance the checkpoint) and
  double the next interval, capped at the configured max.

### Action on hit
Just set `has_updates = 1` + record `latest_seen_version`. UI shows a
yellow "update?" pill on the library row + a count in the top bar.
Clicking the pill runs the existing per-game Sync (which clears the
flag once the new version lands in `games.latest_version`).

### Cadence
- `settings.poll_interval_secs` — default `21600` (6 h), min `3600`
  (1 h), max `604800` (7 d). UI: "Check for updates every: [hourly /
  6 hours / daily / weekly / off]".
- First poll fires `60 s` after launch (avoid login dance race).
- 429-backoff doubles the interval up to `max`; resets on the next 200.

### Rate-limit
Route the poll through the same `f95.Client.get` chokepoint that
already enforces 1500 ms between f95zone.to requests via
`Io.Clock` / `Io.Mutex` / `Io.sleep`. No extra plumbing needed.

### Worker pattern
Reuse the documented single-worker model. New job kind
`UpdatesPollJob` enqueued by:
- a wakeup timer in the worker loop (compares `now -
  last_updates_poll_ts` against `poll_interval_secs`);
- a Settings screen "Check now" button;
- (later) a sync-completed hook for the active game's thread.
Job state exposed via the same atomic-snapshot pattern as
sync/bookmarks: `{ state, page, total_pages, hits, errors,
finished_at }`. UI shows a top-bar "Checking updates… N/M" spinner.

### Files touched (estimated)
- `src/f95/latest.zig` — new module: URL builder + JSON parse for
  `data[]` entries. Mirrors response struct.
- `src/library/library.zig` — schema migration (#4) adds
  `last_seen_thread_ts`, `latest_seen_version`, `has_updates` columns;
  helpers `markUpdateSeen` / `clearUpdateFlag` / `bumpLastSeen`.
- `src/ui/actions.zig` — `UpdatesPollJob` worker, `pollOnce(alloc,
  client, library, since_ts) !PollResult`, `startUpdatesPoll`,
  `drainUpdatesPoll`.
- `src/ui/screens.zig` — top-bar spinner + count badge; library row
  pill (clickable); Settings cadence dropdown + "Check now" button.
- `src/config.zig` — `poll_interval_secs` setting + persistence.
- 3-4 unit tests: `clamp` rule, version-compare, dedupe via
  `last_seen_thread_ts`, 429-backoff state machine.

### Explicit non-goals (for now)
- No notification daemon integration (XLibrary has it; F95Checker has
  it; deferred until phase 6+).
- No per-mod polling. Mods are 1:1 with their own thread; if/when we
  add a `mods.thread_id` column the same job can sweep them via the
  union of IDs.
- No alerts/inbox unread polling. F95Checker hits
  `f95_notif_endpoint = /conversations/popup?_xfResponseType=json` —
  out of scope for f69 (library-focused, not forum-client).
- No external indexer dependency à la F95Checker — we either hit F95
  ourselves or we don't poll.

## Schema migrations

Beyond zqlite's PRAGMA `user_version`, we keep an explicit
`_schema_version` table tracking each applied migration's id, hash, and
timestamp. This lets us:

- Detect partial-state failures (a migration that ran half-way) and
  refuse to start until manually resolved
- Reject a database file from a newer schema (downgrade prevention)
- Hash-check migrations on startup to catch accidental edits to applied SQL

Migrations are ordered SQL strings in `library/library.zig`. Down-
migrations are written only when a destructive change is unavoidable.
Migration failures are loud — we don't continue with a half-migrated DB.

## Crash diagnostics

Custom panic handler installed in `main.zig`. On panic:
1. Capture the message + stack trace.
2. Write `~/.cache/f69/crashes/<unix-ts>.log` with: zig version, git rev
   (baked at build time), platform, message, full stack.
3. Print a "wrote crash log to <path>" line to stderr.
4. Exit non-zero.

No telemetry, no phone-home. The user can attach the log to a bug
report manually.

## Disk layout

```
~/games/f69/<game-id>/
    <version>/
        base/                ← extracted base game
        mods/
            <mod-id>-<version>/
        overlay/             ← OverlayFS merged dir, OR flat-copied result
        saves/               ← bind target for sandbox $HOME redirect
        .install.log         ← every file written, for clean uninstall
~/.config/f69/
    config.toml
    games.db                 ← zqlite
    recipes/                 ← user-authored recipes
    sandbox/<game-id>/       ← per-game sandbox $HOME (shared across versions)
~/.cache/f69/
    downloads/<job-id>/      ← in-flight staging
    nwjs/                    ← cached nwjs versions for RPGM convert
    renpy-sdk/               ← cached Ren'Py SDKs for Ren'Py convert
    nwjs-syslibs/            ← cached system libs for self-contained packaging
    nwjs-ffmpeg/             ← cached codec-enabled libffmpeg.so per nwjs ver
```

## Database schema (zqlite)

`games` and `mods` use the F95 thread id (integer) as the primary key
— it's stable, unique, and natural. Saves a synthetic-id column +
indices and makes debugging by thread id direct. Only `installs` has a
synthetic UUID since `(game, version)` would be awkward to FK from
`mod_installs`.

```sql
CREATE TABLE _schema_version (
  id INTEGER PRIMARY KEY,
  hash TEXT NOT NULL,                   -- sha256 of the migration SQL
  applied_at INTEGER NOT NULL
);

CREATE TABLE games (
  f95_thread_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  developer TEXT,
  cover_url TEXT,
  description_md TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  rating REAL,
  vote_count INTEGER,
  user_rating REAL,
  completion_status TEXT NOT NULL DEFAULT 'not_started',
  engine TEXT NOT NULL DEFAULT 'unknown',
  latest_version TEXT,
  default_install_id TEXT REFERENCES installs(id) ON DELETE SET NULL,
  sandbox TEXT NOT NULL DEFAULT 'use_default',     -- always|never|use_default
  last_played_at INTEGER,
  total_playtime_s INTEGER NOT NULL DEFAULT 0,
  last_scraped_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE installs (
  id TEXT PRIMARY KEY,                  -- synthetic UUID
  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
  version TEXT NOT NULL,
  install_path TEXT NOT NULL UNIQUE,
  executable TEXT,
  launch_args TEXT,
  recipe_id TEXT NOT NULL,
  installed_at INTEGER NOT NULL,
  UNIQUE (game_thread_id, version)
);

CREATE TABLE mods (
  f95_thread_id INTEGER PRIMARY KEY,
  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  author TEXT,
  latest_version TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE mod_installs (
  install_id TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
  mod_thread_id INTEGER NOT NULL REFERENCES mods(f95_thread_id) ON DELETE CASCADE,
  mod_version TEXT NOT NULL,
  load_index INTEGER NOT NULL,           -- topo-sorted order
  applied_at INTEGER NOT NULL,
  PRIMARY KEY (install_id, mod_thread_id)
);

CREATE INDEX games_name ON games(name COLLATE NOCASE);
CREATE INDEX games_rating ON games(rating);
CREATE INDEX installs_game ON installs(game_thread_id);
CREATE INDEX mods_game ON mods(game_thread_id);
CREATE INDEX mod_installs_install ON mod_installs(install_id);
```

Migrations live as ordered SQL strings in `library/library.zig`,
applied within a single transaction per migration. The `_schema_version`
table records each migration's id + hash so we can detect tampering and
refuse newer-than-binary schemas.

## Phasing

**De-risk before ceremony.** The novel risks (sandbox, overlay,
convert) and the unknown-unknowns (dvui scale, RPDL auth)  go in
weeks 1–2 as throwaway spikes. Only after they clear do we build the
shipping app.

| # | Phase | Est | Notes |
|---|---|---|---|
| 0 | **Risk spikes (throwaway)** | 1 wk | (a) bwrap a Ren'Py game on Debian + Arch + NixOS — nail the arg list (steal from `steam-runtime-launcher-service`); (b) flat-copy a mod over a base game with file tracker; (c) port `fix-linux-games.sh` Ren'Py path to Zig and convert one Win-only game. **No DB, no UI, no recipes.** Throwaway code; informs everything below. |
| 1 | **Catalog + dvui scale test** | 1.5 wk | db + f95/client + f95/thread + minimal dvui. **Critical:** prototype the *busiest screen* (game-detail with 50-mod list, drag-to-reorder, modals) on day 7. Confirms dvui can carry the project before we sink weeks into it. |
| 2 | Recipe format (ZON) | 4 d | `std.zon.parse` → AST struct. Validator. Derive from F95 thread scrape. UI editor inline in detail view. |
| 3 | Bookmark import | 1 wk (was 3d) | F95 cookie login + Cloudflare + bookmarks page scrape. Budget includes a "paste cookie from browser" fallback for when direct login is blocked. |
| 4 | Downloads — RPDL + DDL via aria2 RPC | 1.5 wk | Auth'd `.torrent` fetch from F95 → handoff to aria2 RPC. Most likely reality-check; do *before* mods. |
| 5 | Convert (Win→Linux, port `fix-linux-games.sh`) | 1 wk | Now informed by the spike. Ren'Py + RPGM MV/MZ engine detection, SDK/nwjs download, syslib resolution. |
| 6 | Sandbox (bwrap on Linux, plus per-distro test matrix) | 1 wk | Build the real `sandbox/linux_bwrap.zig` with the spike's arg list. Test Debian 12 / Ubuntu 24.04 / Arch / NixOS. Sandboxie deferred. |
| 7 | Mod recipes + resolver + multi-version install | 2.5 wk | Backtracking-with-learning resolver (with explanation tree). Flat-copy overlay first. File-level conflict detection. |
| 7.5 | **Updates polling** | 4 d | Periodic `latest_data.php` sweep with two-tier checkpoint (global `last_updates_poll_ts` + per-game `last_seen_thread_ts`). Sets `has_updates` flag on tracked rows; UI surfaces yellow pill + top-bar count. See `## Updates polling` section. |
| 8 | Mirror handlers (mega/mediafire/gofile/browser fallback) | ongoing | Long tail; user-driven priority. |
| 9 | (later) OverlayFS optimization on top of flat-copy | 3 d | Where userns is available, swap to OverlayFS; flat-copy stays as fallback. |
| 10 | (later) Sandboxie integration on Windows | 1 wk | When we cross-compile for Windows. |
| 11 | (later) Native BitTorrent via libtransmission | 1.5 wk | Only if aria2-subprocess limitations bite. |
| 12 | (later) Hosted recipe repo + git-sync | 1 wk | Out of scope for v1. |

Total to "most of what you want": **~10 weeks** focused solo. Spikes
clear by week 1; you can show a working catalog by week 2.5.

## Sandbox details

### Linux (bubblewrap)

Per-game (NOT per-install): `~/.config/f69/sandbox/<game-id>/`
holds the fake $HOME shared across all versions.

The bwrap arg list above is illustrative; **the real list is borrowed
from `steam-runtime-launcher-service`** which already solves the
per-distro footguns: Pulse + PipeWire sockets, DBus session bus, GPU
device nodes, `/dev/shm`, fontconfig cache. Don't reinvent.

**Portability gotchas (validated by the phase-0 spike):**
- Debian 12 + default sysctl `kernel.unprivileged_userns_clone=0` blocks
  user namespace creation. Detect at startup; surface a clear "set
  `sysctl kernel.unprivileged_userns_clone=1`" message.
- Ubuntu 24.04 AppArmor profile blocks unprivileged userns. Same
  detect-and-explain.
- NixOS works out of the box.

When userns is unavailable, sandbox is degraded to a "best-effort"
mode (just $HOME redirection, no user namespace) — better than
nothing but not a real sandbox. Surface this to the user.

Each version's launcher runs in the same sandbox HOME, so Ren'Py saves
under `~/.renpy/<gamename>/` are visible to v0.5.7 and v0.5.8 alike.

### Windows (Sandboxie)

User installs Sandboxie Plus separately (we link to download in the UI
when sandbox is requested but `Start.exe` not found). Detection:

1. Check `HKLM\SOFTWARE\Sandboxie` for InstallPath
2. Fall back to `%ProgramFiles%\Sandboxie-Plus\Start.exe`
3. If neither found, surface "Install Sandboxie or disable sandbox in
   settings"

Box name: `xlib_<game-id-prefix-12chars>`. Box created on first sandboxed
launch via `sbiectrl.exe /reload` after writing a `Sandboxie.ini` block.
Same box reused across all versions of the same game — Sandboxie file
namespace persists, so saves live there.

XLibrary already has `useSandboxie` / `launchWithSandboxie` plumbing — we
mirror its conventions where they're sound.

**Caveat on shared-saves across versions:** Sandboxie's file namespace
is COW rooted at `C:\Sandbox\<user>\<box>\drive\C\…`. If both versions
write saves to the *same in-box path* (e.g. Ren'Py's `%APPDATA%\RenPy`
or RPGM's `www/save/`), saves carry. Engines that hard-code an
absolute install path may not. Document as best-effort.

**Sandboxie automation race:** `sbiectrl /reload` while another box is
running invalidates handles. Wrap config rewrite + reload in a process-
level lock (`util/sandboxie_lock.zig`).

## Convert details

### Engine detection

| Engine | Heuristic |
|---|---|
| Ren'Py | `renpy/` and `game/` subdirs exist |
| RPGM MV | `package.json` + `www/index.html` |
| RPGM MZ | `package.json` + `index.html` (no `www/`); `package.json` has `"main"` |
| Unity | `*_Data/` dir + `UnityPlayer.dll` |
| unknown | none of the above; recipe must declare manually |

### Ren'Py convert

1. Detect version from `renpy/__init__.py` (`version_tuple = (...)`) or
   `renpy/vc_version.py`.
2. Download SDK from `https://www.renpy.org/dl/<v>/renpy-<v>-sdk.tar.bz2`
   (fallback `.tar.gz`). Cache in `~/.cache/f69/renpy-sdk/`.
3. Copy `lib/{py3-,py2-,}linux-x86_64` and `lib/python*` into game dir.
4. Generate `<gamename>.sh` launcher that exports `LD_LIBRARY_PATH` and
   `RENPY_PLATFORM` and invokes `python` — wrapped in `steam-run` on
   NixOS, plain exec elsewhere.

### RPGM (MV/MZ) convert

1. Detect Chrome major version from `nw.dll` / `nw_elf.dll` (string scan
   for `Chrome/<N>`) or from `v8_context_snapshot.bin` (V8 major →
   Chrome major mapping).
2. Map Chrome → nwjs version (table in `convert/rpgm.zig`,
   sourced from https://nwjs.io/versions.json).
3. Download nwjs from `https://dl.nwjs.io/v<v>/nwjs-v<v>-linux-x64.tar.gz`.
   Cache.
4. Copy `nw` binary, `lib/`, paks, v8 snapshots, crashpad handler,
   locales, swiftshader.
5. Replace `lib/libffmpeg.so` with codec-enabled version from
   `nwjs-ffmpeg-prebuilt` releases.
6. Generate `launcher.sh` that sets `LD_LIBRARY_PATH=./lib`, forces X11
   on Wayland for older nwjs, and execs `nw .` (wrapped in `steam-run`
   on NixOS).

### Multi-distro syslib resolution

| Distro | Strategy |
|---|---|
| NixOS | `convert/nix_resolve.zig` calls `nix eval --raw nixpkgs#<pkg>.outPath` for a fixed list (gtk3, glib, nss, X libs, ...) and exports `NIX_LD_LIBRARY_PATH`. Cached at `~/.cache/f69/nixos-libs.cache`. |
| Arch / Debian / Fedora / other | `convert/syslibs.zig` uses `ldd` against the binary, copies missing `.so` files from `/usr/lib*` or `/lib*` paths into the game's `lib/`. Self-contained game dir. |
| Flatpak runtime present | Optional: bind `org.freedesktop.Platform/x86_64/<branch>/files/lib` for libs. |

Caching: `~/.cache/f69/nwjs-syslibs/` populated on first run via
`build_syslibs_cache` flow (port from user's `fix-linux-games.sh`).

## Open items

- Resolver explanation tree — what does the user see when their selected
  mod set is unsatisfiable? Cargo-style "because A requires B@>=2 but C
  requires B@<2" or just an error code? Cargo's UX is 60% of why people
  accept its resolver decisions. Plan the explanation surface up front.
- Mod load-order UI — drag-to-reorder vs pure rule-driven? Lean
  rule-driven (UI displays computed order; user only edits rules).
- Update notification UX — toast on detection? Banner on detail page?
  Defer until phase 7.
- Save-folder open: per-platform xdg-open vs `App.openPath()` with
  `std.fs` env-var expansion. Settle when wiring the UI button.
- Aria2 RPC bind: localhost-only, with auto-generated rpc-secret per
  app start so other local users can't drive the daemon. Confirmed.

## References

- XLibrary (this repo's older sibling at `~/projects/xlibrary-linux`) —
  reference for "what the app should look like."
- F95Checker (https://github.com/WillyJL/F95Checker, GPLv3) — reference
  for RPDL/DDL/mirror handling. Battle-tested Python.
- Wabbajack (https://github.com/wabbajack-tools/wabbajack) — modlist
  recipe precedent.
- CKAN (https://github.com/KSP-CKAN/CKAN) — backtracking dep resolver.
- bubblewrap (https://github.com/containers/bubblewrap) — Linux sandbox
  primitive.
- Sandboxie Plus (https://sandboxie-plus.com) — Windows sandbox.
- aria2 (https://aria2.github.io) — multi-protocol downloader (used
  via subprocess).
- User's `fix-linux-games.sh` and `nixos-libs.sh` (in
  `/media/shared/backup/FirefoxPortable/Cache/dls/games/`) — source of
  truth for Win→Linux conversion logic.

## Status

| Phase | State |
|---|---|
| 0 — risk spikes | **done**. spike-01 (bwrap) green on NixOS; spike-02 (flat-copy) green end-to-end with rollback; spike-03 (Ren'Py convert) green end-to-end (network fetch deferred to phase 5 real impl); spike-04 (dvui busy screen) green for window+render (perf check deferred to phase 1 real use). Debian/Arch/Ubuntu/Fedora bwrap testing deferred to phase 6. Findings: `docs/spike-0[1-4]-*-findings.md`. |
| 2 — downloads (aria2 RPC) | **done.** **Round 17 — RPDL + per-game button + restart persistence.** New `downloads/rpdl.zig` ports the F95Checker RPDL endpoints (`POST /api/user/login` returning `{data:{token}}`, `GET /api/torrent/download/{id}` with `Authorization: Bearer <token>` returning raw bencoded `.torrent` bytes) via short-lived `std.http.Client`s; bencoded-dict sanity check rejects HTML/JSON spillovers that slip past status==.ok. Token plain-text at `<config>/f69/rpdl_token` (mirrors `f95_cookie` pattern), loaded once at startup into `RuntimeInfo.rpdl_token`. `Daemon.addTorrent` RPC (base64-encoded torrent bytes) added next to `addUri`. `Manager.enqueueTorrent` mirrors `enqueueUrl` via shared `registerJob` bookkeeping. Detail screen gains a "Download" button (entypo.download icon); `actions.doDownloadGame` resolves the recipe via `Repo.findGameByThread`, dispatches the first source: `.rpdl` → `rpdl.fetchTorrent` → `Manager.enqueueTorrent`; `.ddl` / `.mirror` → `Manager.enqueueUrl`. New `State.download_msg_buf` surfaces result/error inline, cleared on back. `repository.zig` gains `findGameByThread` that walks `*.game.zon` files O(N). Cross-restart persistence: `Manager.enablePersistence(jobs_json_path, aria2_session_path)` (a) forwards the aria2 session path to `Daemon.init` → `--save-session` + `--input-file` + `--save-session-interval=60` so aria2 itself rehydrates queued/paused downloads; (b) persists our id ↔ gid ↔ url ↔ status table to `<cache>/f69/downloads/manager_jobs.json` (versioned schema, atomic tmp+rename) on every `registerJob` / `removeJob` / `clearCompleted`, and reloads at `enablePersistence` time. `ensureSessionFile` touches the aria2 session file on first launch since `--input-file` refuses a missing path. Tests: 8 rpdl (login parse + bencode sanity + appendJsonStr escapes), jobStatus round-trip, persistJobs/loadJobsJson round-trip (write/read through real `Io.Threaded`), missing-file load is a no-op. Test discovery via `test { _ = mgr; _ = aria2_rpc; ... }` in `downloads.zig` since 0.16 doesn't walk transitive imports for tests. **Round 16 — recipe parser (ZON).** `recipe/zon_loader.zig` parses via `std.zon.parse.fromSliceAlloc` into the typed `GameRecipe` / `ModRecipe` structs declared in `domain.zig`. Anti-RCE is structural (`InstallStep` is `extract` / `copy` / `move` / `delete` / `chmod_x` only — no `run` / `exec`). `validator.zig` enforces sha256 hex shape + path-safety (no absolute paths, no `..` escapes). `saveGame` / `saveMod` round-trip via `std.zon.stringify.serialize` with atomic tmp+rename. `derive.zig` builds a minimal recipe from a scraped F95 thread. Repo loads from `<config>/f69/recipes/<id>.game.zon`. 7 unit tests (parse minimal / parse mirror+install / reject malformed / mod parse / save round-trip / path checks / hex hash). **Round 15 — bookmarks pull, MVP closed.** Real `f95.bookmarks.fetchAll` walks `/watched/threads?page=N` from the user's session, scrapes every `/threads/<slug>.<id>/` link via `parseTrailingId`, dedupes across pages via a `StringHashMap`, stops on first empty page or after a 50-page safety cap. Returns `BookmarkEntry[]` with thread_id + title + canonical URL. Settings F95 section gains a "Pull bookmarks" button (logged-in only) that spawns `BookmarksJob` on a worker thread (atomic-flag pattern, `dvui.refresh` wakes the UI loop), drained per frame. On done: bulk `Library.insertIfMissing` per id, status message reports new vs. already-in-library, triggers the existing `reload_requested` + `start_sync_after_reload` so freshly-imported rows scrape themselves automatically. 4 unit tests cover trailing-id parsing + dedupe across calls. **MVP path is closed**: log in once → click Pull bookmarks → walk away. **Round 14 — F95 login.** Real `f95.auth.login` does the XenForo two-step (GET `/login/` → scrape `_xfToken` from form input or `data-csrf` attr; POST `/login/login` with URL-encoded form, capture `Set-Cookie: xf_*=…` headers via the lower-level `std.http.Client.request` + `response.head.iterateHeaders` flow). Combined cookie passed to `Client.setCookie`. Plaintext persistence at `<config>/f69/f95_cookie` (mode 0600 via `Permissions.fromMode`, atomic tmp+rename). Loaded at startup, applied to client. Settings screen "F95Zone account" section with username + password (masked) fields, Login/Logout buttons, status pill. Login/logout actions in `actions.zig` (`doLogin` / `doLogout`); password buffer wiped after login. **Trade-off:** login blocks the UI for the 1-2s of the login dance — no worker thread yet. Worker offload comes when we add bookmarks-API pull, which has the same shape. Auth tests (4) cover token extraction (form + data-csrf), cookie attr trimming, URL encoding. |
| 1 — catalog + scraper bones | feature-complete. **done:** zqlite wired; `Library.open` runs migrations against `_schema_version` with hash + downgrade protection; migration #2 added `games.notes`; real `upsertGame`/`insertIfMissing`/`listGames`/`applyScrape`/`setNotes` (all allocator-aware); tags persisted as JSON in `tags_json`, decoded back on `listGames` via `std.json.parseFromSlice`; main opens DB at `~/.config/f69/games.db`, seeds 5 fixtures on first run; UI top bar + sidebar + responsive grid + list + Settings + Import + Sync All; pink theme with active-state highlights; cover thumbnails on grid cards via 64-slot round-robin cache shared with detail view; `f95.Client.get` runs real `std.http.Client` rate-limited via `Io.Clock`/`Io.Mutex`/`Io.sleep`; `thread.zig` extracts rating, vote count, cover URL, name/version/developer (title brackets), and tag chips; Sync runs on a detached worker thread, drained per frame, full payload (incl. tags) persisted via `applyScrape`; sync-all queue iterates "(unsynced)" rows sequentially, skip-on-fail; cover bytes fetched + atomically written + rendered via `dvui.image`; bookmark importer paste-area accepts URLs / numeric IDs, dedupe via `INSERT OR IGNORE`; editable Notes tab with Save/Clear; editable `completion_status` (dropdown) and `user_rating` (★ buttons) on detail; tag pill chips on detail screen; library sort dropdown (name / rating / votes); search matches both name and developer. **Round 8 add-ons:** `Engine.fromBracket` maps F95 bracket tokens (Ren'Py / RPGM MV/MZ / Unity) to the enum, scraper auto-classifies engine; `last_scraped_at` stamped via `Io.Clock.real` on each apply, detail screen shows "synced N min/h/d ago"; Delete button + confirm banner removes row, evicts cover file via `Io.Dir.deleteFile`, invalidates the cache, returns to library. **Round 9:** "Open thread" button spawns `xdg-open https://f95zone.to/threads/<id>/`; auto sync-all kicks in after a successful import (returns to library, queues every "(unsynced)" row); sidebar "Unsynced only" filter; settings shows library stats — synced/unsynced split, mean F95 rating, engine breakdown, distinct-tag count, cover-cache fill. **Round 10 (review-driven):** four P0 bugs fixed — partial-allocation leak in `thread.scrape` got an `errdefer freeScraped` chain; dangling-pointer `app.zig` deleted (and its build entries); `drainSync` now advances the sync-all queue when the row disappeared; `applyScrape` clears `sort_applied` so live re-sort happens. Cookie state moved to its own `Io.Mutex` and snapshot-copied for the duration of `fetch`, closing a UAF window if `setCookie` raced with a worker GET. `openInBrowser` now spawns its own detached worker so xdg-open never blocks the UI. Cover cache gained on-hit promotion (FIFO + LRU mix). Stale comments cleaned, settings rows use a stable id counter, `seedIfEmpty` runs in a transaction, startup sweeps orphan `*.tmp` cover files, corrupt `tags_json` rows now log via `log.warn`. **Round 11:** ui.zig (1670 lines) split into `ui.zig` dispatcher (132) + `types.zig` (107) + `actions.zig` (498) + `screens.zig` (910) + existing `state.zig` (199). One-way deps: types ← actions ← screens ← ui. Cover prewarmer worker reads the first 64 cover files at startup (and after reload) to populate the OS page cache, eliminating first-paint disk-read stall. |
| 3 — recipe format (ZON) | **done** (Round 16 / 2026-05-09). Pure-data structs in `recipe/domain.zig`; `std.zon.parse` via `recipe/zon_loader.zig`; schema validator (sha256 hex + path-escape checks); auto-derive from F95 thread scrape; local Repo at `<config>/f69/recipes/`. `findGameByThread` added (Round 17) so the per-game Download button can resolve recipes by `Game.f95_thread_id` without authors needing a thread-id-derived filename. |
| 6 — sandbox (bwrap on Linux) | **done** (Round 18 / 2026-05-12). Production `sandbox/linux_bwrap.zig` ported from spike-01. `Bwrap.detect` (PATH lookup + `unshare -Ur true` userns smoke), pure `buildArgv` function (10 unit tests cover distro variants + network + display + bind_extra), `launch` arena-allocates path joins then `std.process.spawn`. Arg list adds NSS + fontconfig binds over the spike. `Sandbox` tagged union (bwrap / sandboxie / none) with exhaustive switch dispatch; `pickBackend` returns `.none` when bwrap missing or userns blocked, surfacing `BackendUnavailable` cleanly. `Frame.sandbox: *Sandbox` + per-game Launch action: resolves recipe via `Repo.findGameByThread`, verifies `<library_root>/<thread_id>/` exists (placeholder install dir convention, Phase 7 swaps for version-keyed dirs), creates per-game sandbox HOME at `<library_root>/<thread_id>/.f69-home/` (saves persist across versions), builds `SandboxConfig` from recipe + `RuntimeInfo.host` env snapshot, calls `Sandbox.launch`. State gains `launch_msg_buf` mirroring `download_msg_buf`. `spikes/spike-06-sandbox.zig` smoke binary exercises the real production path with a dummy `echo hello` script; NixOS-validated end-to-end. **Removed from spike's arg list:** redundant `/run/current-system/sw/lib` bind — bwrap overlay-collides with the parent `/run/current-system` mount. Sandboxie / "best-effort no-userns" fallback deferred. |
| 5 — convert (Win→Linux) | **mostly done** (Rounds 19+20+21a / 2026-05-12). **Round 21a — network SDK fetch:** `sdk_cache.zig.Cache.fetch(tag, version)` resolves the URL via `sdkUrl` (renpy → `https://www.renpy.org/dl/<v>/renpy-<v>-sdk.tar.gz`; nwjs → `https://dl.nwjs.io/v<v>/nwjs-v<v>-linux-x64.tar.gz`), GETs the body into an in-memory `Io.Writer.Allocating` (cap 1 GiB), wraps via `Io.Reader.fixed` → `std.compress.flate.Decompress(.gzip)` → `std.tar.extract` directly into `<cache>/f69/convert/sdks/<tag>-<version>/`. `strip_components=1` so the tarball's top-level `renpy-<v>-sdk/` / `nwjs-v<v>-linux-x64/` dir collapses. Idempotent: if `locate()` succeeds we return early without network. Best-effort cleanup of half-extracted dirs on tar-extract failure. `service.zig` + `rpgm.convert` both call `cache.fetch(...)` on `SdkNotCached` instead of returning the manual-prep error. +4 unit tests cover URL builders + strip-components + fetch idempotency. **Round 19 (Ren'Py):** `convert/detect.zig` recognizes Ren'Py / RPGM-MV / RPGM-MZ / Unity from install-dir markers. `convert/renpy.zig` ports spike-03 to production: `detectVersion` (vc_version.py first, `__init__.py` version_tuple fallback), `installLinuxLibs` (copies `lib/{py3-,py2-,}linux-x86_64` + every `lib/python*` from the cached SDK), `writeLauncher` (steam-run wrap on NixOS, plain exec elsewhere), `alreadyConverted`. **Spike's four carry-forwards fixed:** symlink preservation in `copyTree` (`Dir.symLink` recreate via `readLink`); streaming file copy (`File.Reader` → `File.Writer`, 64 KiB chunks); mode preservation (read source `Stat.permissions`, `setPermissions` on dest — keeps the python interpreter's +x bit); launcher chmod via `setPermissions(io, .executable_file)`. `convert/sdk_cache.zig` abstracts SDK lookup at `<cache>/f69/convert/sdks/<engine_tag>-<version>/`. `convert/service.zig` dispatches by `ConvertSpec` variant. UI: Convert button on detail screen, `actions.doConvertGame` translates `recipe.ConvertSpec` → `convert.ConvertSpec`. Recipe `recipe.ConvertSpec.renpy.sdk_version` relaxed to optional. **Round 20 (RPGM MV/MZ):** `convert/rpgm.zig` — `detectChromeMajor` streams the first 8 MiB of `nw.dll` looking for the embedded `Chrome/<N>` version string (pure `parseChromeMajor` is unit-tested); `nwjsVersionFor` chooses recipe pin → detected → `chromeToNwjs` table; `installNwjs` walks the cached SDK and copies every file (preserving symlinks + modes, skipping `credits.html`); `findLauncherName` prefers `Game.exe`, falls back to first non-noise `*.exe`, else "Game"; `writeLauncher` emits a bash launcher that sets `LD_LIBRARY_PATH=$(pwd)`, forces `GDK_BACKEND=x11` on Wayland (older nwjs has no Wayland support), `exec ./nw .`, optionally steam-run-wrapped; `alreadyConverted` checks `<name>.sh` + `./nw`. Service arm wired. **+13 unit tests:** chrome table (known + unknown), `parseChromeMajor` (basic / first-wins / missing / bad+good / non-digit), launcher template golden (NixOS + plain, LD_LIBRARY_PATH + GDK_BACKEND), `isSdkNoise`, `nwjsVersionFor` recipe-pin-wins + no-pin-no-nw. **Phase 5 close-out (Round 21):** network SDK fetch (Ren'Py `.tar.gz` from renpy.org, nwjs `.tar.gz` from dl.nwjs.io, eventually our own mirror), `libffmpeg.so` codec swap for RPGM (mp4 audio), multi-distro syslib bundling (`ldd` + copy on Debian/Arch/Fedora, `nix eval` on NixOS). |
| 0.5 — skeleton | done (compiles + tests pass) |
| 7 (mods / resolver / installer) | **MVP-complete — Rounds 22, 34, 35, 36, 37, 38, 39, 40 landed.** **Round 40 (2026-05-13):** mod Uninstall + Settings backup toggle. `Tracker.removeMod` / `hasMod` helpers. `actions.isModInstalled` scans the tracker for any entry with matching mod_id; `actions.doUninstallMod` loads InstallLog, calls `installer.uninstallMod`, then rewrites the tracker file without those entries. Detail Mods tab swaps Install ↔ Uninstall based on tracker state. Settings gets a new "Mods" section with a backup_mode dropdown ("no" / "yes — full backup") bound to `state.mod_backup_default`. **Resolver/explanation-tree UX and version-constraint matching deferred to a follow-up; the engine pieces are all wired.** **Round 38 (2026-05-13):** `installer/apply.zig`'s `applyModArchive` — extracts to `/tmp/f69-mod-staging-<nonce>/`, walks the staged tree, for each file dispatches by (target exists, backup_mode): adds vs modifies, full-backup copies pre-image to `<install>/.f69-backups/<mod_id>/<rel>`. `uninstallMod` walks the InstallLog in reverse for a given mod, deletes adds, restores from backups, warns on no-backup modifies. 5 fixture-based tests (3 skip when subprocess sandbox blocks `tar`). **Round 39 (2026-05-13):** mod Install button wired end-to-end. `Manager.enqueueUrl/enqueueTorrent` now take `kind: JobKind` + `mod_id`; `manager_jobs.json` schema additive (`@tagName(JobKind)`, default "game" on read). `drainCompletedDownloads` dispatches by `Job.kind`: `.game` → existing `postInstallOne`; `.mod` → new `postInstallMod` (resolves `latestInstallForGame`, loads tracker from `<install>/.f69-mods.json`, applies, flushes). New `actions.doInstallMod` enqueues the mod recipe's first source with `kind=.mod, mod_id=mod.f95_thread`. UI: Install button on each row in the Mods tab. `state.mod_backup_default: BackupMode = .none` per the 15GB-mod feedback (Settings toggle is Round 40). **Round 22 + 34 + 35 + 36 + 37 still apply.** **Round 36 (2026-05-13):** real mod resolver. `util/kahn.zig` is a proper Kahn topological-sort with cycle detection (6 unit tests). `resolver/solver.zig`: BFS expansion from `requested` → pull each `requires.target` from the `available` pool → declared-conflict detection both directions → topo sort over `load_after`/`load_before` via Kahn. Returns a `SolveResult` union (.ok / .conflict / .missing / .cycle) — the simple `solve` API collapses to `errs.Error`, `solveExplained` carries the payload. 9 unit tests cover empty, single, requires-chain, conflict, missing-mod, load_after order, cycle, dedup. Version-constraint matching still TODO; backtracking still TODO (only matters when multi-version pools land). **Round 37 (2026-05-13):** tracker persistence. `installer/domain.zig.InstallLog.Entry` gains `mod_id`, `BackupMode` enum (`.none` / `.full` per the 2026-05-13 UX call — quality mods routinely 5-15 GB so backup-by-default is a non-starter), `backup_path` for full-mode entries, `sha256` for drift detection. `installer/tracker.zig` Tracker.flush (atomic tmp+rename, line-delimited JSON) + Tracker.load (missing file → empty log, not an error) + InstallLog.deinit. 5 round-trip tests (empty, single added, full-mode with backup_path, mixed entries in order, missing file). **Round 22 + 34 + 35 still apply.** **Round 34 (2026-05-13):** `installs` DB table now wired (was a scaffold-only column). `Library.upsertInstall` / `listInstalls` / `latestInstallForGame` / `freeInstall(s)` / `deleteInstall`. `Library.open` enables `PRAGMA foreign_keys = 1` so the schema's `ON DELETE CASCADE` actually fires. 4 new tests (install round-trip, ordering, deleteInstall, cascade-from-deleteGame). **Round 35 (2026-05-13):** post-install now extracts into `<library_root>/<thread_id>/<version>/` and inserts an `installs` row (UUID v4 generated via `randomSecure`+formatting). `doLaunchGame` / `doConvertGame` resolve the install dir via `latestInstallForGame`; fall back to the legacy `/<thread_id>/` placeholder when no row exists (back-compat for installs predating this round). Per-game sandbox HOME pinned at the game level — `<library_root>/<thread_id>/.f69-home/` — so saves carry across versions per the original PLAN promise. **Round 22 (post-download install) still applies.** `downloads/archive.zig` now extracts `.zip` (via `std.zip.extract`) and `.tar.gz` (via `std.compress.flate.Decompress(.gzip)` → `std.tar.extract`); unsupported formats (.7z, .rar, .tar.bz2/.xz) surface `ExtractionFailed` with a logged hint. `Job.game_id` (replacing the dead `[36]u8` UUID buffer) carries the F95 thread id end-to-end: through `Manager.enqueueUrl(url, game_id)` / `enqueueTorrent(label, bytes, game_id)`, persisted additively in `manager_jobs.json` (default 0 on read so older files still load), into `Daemon.getFiles(gid)` which returns the first on-disk path via aria2's `aria2.getFiles` RPC. New `actions.drainCompletedDownloads(frame)` runs in `guiFrame`: for each `.done` job with `game_id != 0` and not already in `state.post_installed` (lazy-init `AutoHashMap`), it locates the file, picks a format, extracts into `<library_root>/<game_id>/`. Skips if the dest dir already has any entries (manual extract or prior run). Failures are logged but don't block other jobs — every job's id is marked seen regardless so a broken archive doesn't loop. `Downloads`-screen raw-URL paste passes `game_id=0` → post-install correctly skips it. **Still missing for Phase 7:** mod recipe parsing (ZON loader exists), backtracking resolver, multi-version install table (currently `<library_root>/<thread_id>/` flat — Phase 7 proper introduces version-keyed subdirs + an `installs` SQLite table), flat-copy overlay for mods. |

**UI layout decision (2026-05-08):**
- Library screen: top bar + left sidebar (filter panel) + main area; main area toggles between grid + list view.
- Detail screen: full-window page (NOT a floating dialog). "Back" returns to library, scroll + filter state preserved.
- State machine in `ui/state.zig` with `screen: enum { library, detail }`.

**Recent decisions (2026-05-08, post-architect-review):**
- Recipe DSL → ZON (cancelled custom parser).
- Phasing reordered: spikes before catalog before downloads before mods.
- Concurrency model documented: single worker thread + SPSC ring + atomic snapshot.
- Schema migrations get an explicit `_schema_version` table.
- Crash diagnostics path defined.
- Service-over-Repo passthroughs collapsed.
- F95 thread id is the natural primary key for games + mods.
- Recipe gains a `saves` block + UI gets an "Open saves folder" button.
- Aria2 RPC mode from day one (skip stdout parsing).
- OverlayBackend / Sandbox become tagged unions; download Handler stays vtable + priority field.

**Recent decisions (2026-05-12, convert round 19):**
- **Convert is engine-keyed, not recipe-DSL.** Variance across games of the same `(engine, version)` is small enough that built-in engine handlers cover the common case; a per-game declarative steps DSL would be over-engineering. User explicitly OK'd this. Recipe just declares `engine + sdk_version + extras`; convert/renpy.zig + convert/rpgm.zig do the work.
- **No crowdsourced convert recipes.** We host the SDKs ourselves when the time comes (Round 21). The recipe `convert_linux` block stays small.
- Recipe's `renpy.sdk_version` relaxed to `?[]const u8`. Null = let `convert.renpy.detectVersion` read it from `renpy/__init__.py` / `vc_version.py`. Recipe authors can still pin for reproducibility.
- **SDK cache layout:** `<cache>/f69/convert/sdks/<engine_tag>-<version>/`. `<engine_tag>` is "renpy" / "nwjs" / etc. — distinct from the engine enum because RPGM uses nwjs as its SDK. Flat namespace is easier to inspect than per-engine subdirs.
- **Network fetch deferred to Round 21.** Manual cache layout is documented in the `SdkNotCached` error message. Lets us land the working Ren'Py path without bringing in tar/gz parsing complexity now.
- **Idempotency check ported from `fix-linux-games.sh`:** `<name>.sh` present + at least one `lib/*linux-x86_64` dir = already converted. `force=true` re-runs.

**Recent decisions (2026-05-12, sandbox round):**
- Placeholder install dir is `<library_root>/<thread_id>/` until Phase 7 lands a real installer; Phase-7 will rewrite the action's `install_path` derivation to look at the `installs` table.
- Per-game sandbox HOME co-located at `<install_path>/.f69-home/` (NOT under XDG_CONFIG_HOME). Decision rationale: backing up a game = `tar` the install dir, no scattering. Trade-off: deleting the install dir wipes saves; we'll document this and add a "Backup saves" UI button before the Phase 7 installer can prune old installs.
- `buildArgv` is a pure function — its arena-allocator contract is documented in the doc comment, callers (`launch()` and tests) wrap in a transient `std.heap.ArenaAllocator` so path joins don't leak.
- Removed the explicit `/run/current-system/sw/lib` bind from the NixOS arg set. Bwrap aborts with "Can't mkdir" because the parent `/run/current-system` is already a read-only mount; NSS plugin paths are reachable transitively through the parent.
- Sandbox tagged union has a `none` variant that surfaces `BackendUnavailable` rather than silently launching unsandboxed — users explicitly asked for the sandbox; failing loud is correct.
- "best-effort no-userns" (just `$HOME` redirection without unshare) deferred to a follow-up. Debian/Ubuntu users today get a clear "userns blocked" log line + the launch fails.

**Recent decisions (2026-05-12, RPDL + persistence round):**
- RPDL endpoints ported verbatim from F95Checker (`POST /api/user/login`, `GET /api/torrent/download/{id}`). Token stored plaintext at `<config>/f69/rpdl_token` for now; libsecret integration deferred (`util/secret.zig` is still a stub).
- RPDL `.torrent` bytes go to aria2 via `aria2.addTorrent` (base64) rather than persisting a temp file + `addUri(file://…)`. Fewer moving parts, atomic from aria2's POV.
- Recipe lookup for the per-game Download button uses `findGameByThread` (O(N) directory scan over `*.game.zon`). Acceptable for tens-to-hundreds of recipes; promote to an index if it ever becomes hot.
- The handler-vtable dispatch in `downloads/handler.zig` stays reserved-for-later. RPDL is implemented as free functions in `downloads/rpdl.zig`, called directly from `actions.zig` — the vtable would have added indirection without earning it.
- `downloads/handlers/*.zig` stubs are kept for now (mega/mediafire/gofile/browser fallback) since architects asked for the dispatch shape; they'll either get real implementations in a follow-up "mirror handlers" round or be deleted wholesale.
- Cross-restart persistence is two-layer: aria2's `--save-session` for the byte-level state + our own `manager_jobs.json` for the id ↔ gid ↔ url mapping. Both are atomic-write, both versioned (manager_jobs.json carries `"version":1` and the loader refuses unknown versions).
- 0.16 stdlib quirk: `zig build test` test discovery only walks test blocks reachable through *referenced declarations*. `downloads.zig` now carries an explicit `test { _ = mgr; _ = aria2_rpc; … }` block to surface nested module tests.

**Test-time tooling (2026-05-13):**
- **Portable data layout (Round 42).** All persistent state now lives under a single `data_root`, default `<exe_dir>/data/`. Override via `F69_DATA_DIR`. New tree: `<root>/{f69.db, f95_cookie, rpdl_token, browser, recipes/, covers/, library/<tid>/<version>/, library/<tid>/.f69-home/, cache/{downloads/, convert/sdks/}, save-backups/<tid>/<ts>/}`. `resolveDataRoot` reads `/proc/self/exe` for the exe dir. Diagnostics screen surfaces `data_root` first. `doBackupSaves` now writes under `data_root/save-backups/` instead of `$HOME/.local/share/f69/`. Old XDG-scattered helpers (`defaultDbPath`, `defaultCoversDir`, etc.) deleted. Drop the f69 folder anywhere and it's a self-contained app.
- **Diagnostics screen (Round 41).** Top-bar "Diagnostics" icon between Downloads and Settings. Read-only state dump for bug reports: every `RuntimeInfo` path, sandbox backend name, host env snapshot (`$HOME` / `$XDG_RUNTIME_DIR` / `$WAYLAND_DISPLAY` / `$DISPLAY`), F95 + RPDL login state, mod backup-mode default, all `Downloads.Manager` jobs with kind/status/game_id/mod_id/source URL, every game's installs from SQLite, tracker entries for the currently-selected game. Screenshot or paste during a NixOS test session and we have everything needed to diagnose.

**Follow-up work (post-2026-05-12, deferred):**
- RPDL Settings UI: **shipped in Round 28 / 2026-05-12.** New `renderRpdlAccount` panel sits between the F95 and Browser sections in Settings, mirroring the F95 login UX (status pill, username + masked password text entries, Login + Logout buttons). `actions.doRpdlLogin` calls `downloads.rpdl.login` → atomic 0600 write to `<config>/f69/rpdl_token` → `state.rpdl_token` updated live (`enqueueOneSource` now reads from state, not info). `actions.doRpdlLogout` clears in-memory + on-disk. Token ownership moved out of `RuntimeInfo` into `State.rpdl_token` (heap-owned, freed in runMainLoop defer); `RuntimeInfo` now just carries the path. No restart needed after login.
- Download fallback: **shipped in Round 27 / 2026-05-12.** `drainCompletedDownloads` now observes `.failed` too. On terminal failure for a job with `game_id != 0`, `tryNextSource` advances the per-game `state.download_attempts` index and enqueues `recipe.sources[next_idx]`. Status line reflects "Source N/M failed; trying next (job X)" or "All N source(s) failed" when exhausted. `doDownloadGame` calls `resetAttempt(game_id)` so the chain re-starts cleanly on a fresh user click. Both `.done` and `.failed` mark the same `post_installed` set so each job is handled exactly once.
- Hash-verify pipeline: **shipped in Round 24 / 2026-05-12.** `verify.zig.verifyFile` streams the file through SHA-256 and compares; `Manager.enqueueUrl/enqueueTorrent` take optional `expected_sha256: ?[32]u8` and carry it into `Job.expected_sha256`; `actions.enqueueOneSource` hex-decodes `recipe.Source.sha256` for `.ddl` + `.mirror` (skips `.rpdl` since the recipe hash refers to the torrent payload, not the single file `aria2.getFiles` returns); `drainCompletedDownloads`'s `postInstallOne` runs `verifyFile` *before* extract — mismatch logs loud and skips extract entirely (still marks seen). +8 verify tests (Hasher empty/abc, hexDecode happy/length/non-hex, verifyFile hit/miss/missing-file).
- Mediafire / Mega / Gofile real handlers (or delete the stubs).
- Per-host rate limiting for RPDL (the F95 client's chokepoint doesn't cover dl.rpdl.net).
- Sandbox: **best-effort no-userns mode shipped in Round 25 / 2026-05-12.** `NoSandbox.launch` now actually spawns: clones the host's environ via `Environ.createMap`, overrides `HOME` with `cfg.sandbox_home`, sets `cwd = install_path`, spawns `cfg.executable + cfg.launch_args` with inherited stdout/stderr. No isolation, but games run on Debian/Ubuntu hosts where bwrap fails the userns smoke. Users see `backend=none` in the Launch result line so they know there's no sandbox. Still needed: distro testing (Debian 12, Ubuntu 24.04 with AppArmor, Arch, Fedora SELinux).
- Sandbox: **Stop button + running-game tracking shipped in Round 30 / 2026-05-12.** `state.running_games` is a per-game (thread_id → pid) map populated after each successful `sandbox.launch`. Detail screen swaps the "Launch" button for "Stop" when the game is in the map. `doStopGame` sends SIGTERM via `std.posix.kill(pid, .TERM)`. Each guiFrame calls `drainRunningGames` which probes via `kill(pid, 0)` (existence check, no signal) and prunes dead entries — keeps the button swap honest when a game exits on its own.
- Phase 7 installer: replace the placeholder `<library_root>/<thread_id>/` install dir with version-keyed dirs + an `installs` DB table; rewrite `doLaunchGame`'s `install_path` derivation accordingly.
- "Backup saves" UI button — **shipped Round 33 / 2026-05-13.** Detail-screen Backup button next to Open saves. `doBackupSaves` recursively copies `<library_root>/<tid>/.f69-home/` → `<HOME>/.local/share/f69/save-backups/<tid>/<unix-seconds>/`. Plain mode-preserving file/dir walk; no symlink magic (saves are normally regular files). Status surfaces via `launch_msg_buf`.
- **Round 20 — RPGM convert.** Port `fix-linux-games.sh`'s RPGM path: Chrome major from `nw.dll`/`v8_context_snapshot.bin` → nwjs version via `chromeToNwjs` table → copy `nw` + `lib/` + paks + locales + swiftshader → replace `libffmpeg.so` with codec-enabled build → generate `launcher.sh` (force X11 on Wayland for older nwjs, steam-run wrap on NixOS).
- **Round 21a — network SDK fetch:** shipped (see Phase 5 row).
- **Round 21b — multi-distro syslibs:** **shipped 2026-05-13.** `convert/syslibs.zig` ports `fix-linux-games.sh`'s `bundle_syslibs` flow. Pure `parseLddOutput` extracts `=> not found` lib names (6 unit tests cover Debian/multi-arch/empty/trim cases incl. real-tab via `\x09`). `bundle(alloc, io, install_dir, binary_hint, distro)` spawns `ldd <binary>`, parses, looks each missing lib up in per-distro paths (`searchPathsFor`: Debian/Ubuntu lead with `/usr/lib/x86_64-linux-gnu`, Fedora with `/usr/lib64`, Arch with `/usr/lib`, NixOS is empty — `steam-run` handles it), copies hits into `<install>/lib/`. Wired into `rpgm.convert` when `bundle_syslibs=true` (recipe default). Single pass; transitive deps via re-run is a follow-up. NixOS is a documented no-op.
- **Round 21c — self-hosted SDK mirror:** stand up our own host so we control versioning + don't depend on renpy.org / dl.nwjs.io availability.
- **libffmpeg.so codec swap (Round 29 / 2026-05-12):** shipped. `sdkUrl("nwjs-ffmpeg", v)` resolves the nwjs-ffmpeg-prebuilt release zip; `sdk_cache.Cache.fetch` now dispatches by `ArchiveFormat` (.tar_gz | .zip), with a tmp-file zip extract path since `std.zip.extract` needs random access. `rpgm.installFfmpegCodecs` fetches the prebuilt + overwrites `<install>/lib/libffmpeg.so`. Called from `rpgm.convert` when `ffmpeg_codecs=true` (default). Best-effort: a fetch failure logs a warning but doesn't abort the convert.
- Auto-convert on Launch: **shipped in Round 23 / 2026-05-12.** `doLaunchGame` checks if `recipe.launch.linux` exists under the install dir; if not + `recipe.convert_linux != .none`, runs `convert_svc.convert(install_path, spec, force=false)` first with a "Converting before launch…" status line. Idempotent — re-Launch after a clean convert is a no-op for the convert phase.

Update on each session: which phase is current, what's the next thing
to touch, any new constraints learned.
