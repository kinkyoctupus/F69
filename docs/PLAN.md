# f69 — Plan

Single source of truth. Combines what was in PLAN.md, PLAN-OPEN.md,
PLAN-modding-tools.md, PLAN-compat-recipes-followups.md, REVIEW-2026-05-08.md,
TEST-PLAN-NIXOS.md, and the spike-findings docs.

A native rewrite of XLibrary, scoped to F95Zone-only, with first-class
support for downloads, multi-version installs, mods (with dependency /
conflict resolution), Windows→Linux conversion, and sandboxed launch.

XLibrary is the reference for "what the app should look and feel like"
but not for behavior — XLibrary is download/launch-naïve. We are building
a small declarative package manager on top of F95Zone.

Two sections below: **1. Finished** (decisions in effect + work shipped),
**2. Still planned** (open work).

---

# 1. Finished

## 1.1 Hard constraints

- **Language:** Zig 0.16.0 (latest stable).
- **GUI:** dvui (SDL3 backend), pulled from main. No tagged release pinning.
- **DB:** zqlite (karlseguin) — transactions + blob handling + connection
  pool. Reject `vrischmann/zig-sqlite` (maintainer hiatus).
- **Platforms:** Linux primary (Arch, Debian, Fedora, NixOS); Windows secondary.
- **No telemetry.** No phone-home. No auto-updater (we own the binary).

## 1.2 Decisions in effect

| Topic | Decision |
|---|---|
| F95Zone integration | Yes (only provider) |
| Steam / itch / GOG / DLsite | **Out** |
| Google Drive sync | **Out** |
| Bookmark import | Direct HTTP from app, libsecret-stored login cookie. **No extension dependency for v1.** |
| Browser extension | **Build our own** in phase 6+ as a sibling repo (`xlibrary-zig-extension`). MV3, F95-only scope. App is fully functional without it. |
| Mass scrape with rate limit | Single client chokepoint, 1500 ms between f95zone.to requests. |
| Game downloads | RPDL primary (torrents via aria2c subprocess), DDL fallback, public mirrors as link-list. |
| Plain HTTP fallback | `handlers/http.zig` next to `handlers/aria2.zig`; user-toggleable per-source. |
| Game updates | Install new version into separate dir, keep old, user re-picks mods. |
| Mods | Recipe-driven, with deps / conflicts / load-order. |
| Recipe format | **ZON** — `std.zon.parse`. No custom lexer/parser. Anti-RCE is enforced as a schema check in the validator. |
| Recipe sources | Local files + auto-derived from F95 thread; community repo deferred. |
| Conflict resolution | Backtracking-with-learning (Cargo-style), not SAT. |
| Overlay strategy | **Flat-copy first.** OverlayFS as later optimization (Debian/Ubuntu sysctl + AppArmor commonly block unprivileged userns mounts). |
| Multi-version installs | Each version is its own `Install` row + dir. |
| Sandbox scope | **Per-game**, not per-install. Saves carry across versions. |
| Sandbox impl (Linux) | bubblewrap (`bwrap`). |
| Sandbox impl (Windows) | Sandboxie (sandboxie-plus). User installs separately; we shell out to `Start.exe /box:<box> ...`. |
| Sandbox default | Global setting + per-game override (always / never / use_default). |
| Win-only games on Linux | Recipe declares `convert linux { ... }` block; runtime downloads matching SDK/nwjs and bundles syslibs. |
| Win→Linux SDK reference | Logic ported from user's `fix-linux-games.sh` and `nixos-libs.sh`. |
| Auto-prune old installs | Default: never; opt-in `prune_old_after: 30d`. |
| Token storage | libsecret / Secret Service (no plaintext default). |
| Save data location | Recipe carries an optional `.saves` block. UI exposes "Open saves folder" + "Backup saves". Defaults auto-derived per engine. |
| WS server bind | 127.0.0.1 only. |
| Concurrency | Single dedicated worker thread + per-job SPSC progress ring. UI thread reads via atomic snapshot. No general thread pool yet. |
| Aria2 | RPC mode from day one. Stdout-parsing skipped (brittle, version-coupled). |
| Schema migrations | Explicit `_schema_version` table + ordered up-migrations. Failures fail-loud, not partial-state. |
| Settings versioning | `config.toml` carries a `version` field. |
| Crash diagnostics | Custom `panic` handler writes `~/.cache/f69/crashes/<ts>.log`. No phone-home. |
| Natural keys | F95 thread id (integer) is the primary key for `games` and `mods`. Synthetic UUIDs only for `installs`. |
| Data layout | `data_root` = `<exe_dir>/data/` by default, overridable via `F69_DATA_DIR`. Self-contained portable folder. |

## 1.3 Architecture

### Bounded contexts

```
<context>/
  <context>.zig         ← public face: top-level type(s) + key call sites
  domain.zig            ← entity types (pure data, no IO)
  errors.zig            ← module-specific error set
  <internal>.zig        ← implementation files imported only within the context
```

**No Service-over-Repo passthroughs.** When a context's "service" would just
forward calls to the repo, collapse them into one type. Distinct `Service`
only when there's real cross-repo orchestration (currently: `installer/`).

**No public re-export walls.** `<context>.zig` exposes the top-level
struct(s); everything else stays internal. The build graph enforces module
boundaries.

| Context | Purpose |
|---|---|
| `library` | Game / Install / Mod entities + zqlite-backed `Library`. Core domain. |
| `recipe` | ZON loader + validator + derive-from-scrape + local FS storage. |
| `resolver` | Dependency / conflict resolution + topo sort. Pure logic, no IO. |
| `f95` | F95Zone HTTP client + scrapers. |
| `downloads` | Job queue + handler vtable + per-host implementations. |
| `installer` | Apply install plans, overlay layering, file tracker, uninstall. |
| `convert` | Windows→Linux conversion (Ren'Py, RPGM MV/MZ). |
| `compat` | Runtime compatibility recipes (LD_LIBRARY_PATH bundles for stripped hosts). |
| `sandbox` | bwrap (Linux) / Sandboxie (Windows) launch wrappers. |
| `server` | WS + JSON-RPC server. Deferred until our browser extension exists. |
| `ui` | dvui screens. Presentation only — never imports `library/library.zig`. |

Plus `main.zig`, `app.zig`, `config.zig`, and `util/*` (paths, secret, kahn,
db, spsc, snapshot, crash, version, file_picker, archive, renpy).

### Polymorphism — vtable vs tagged union

**Tagged union** for closed sets (≤ a few impls), compile-time known:
`installer/overlay.zig` (overlayfs vs flat-copy), `sandbox/sandbox.zig`
(bwrap vs sandboxie vs none). Exhaustive switching, compiler devirtualises.

**Vtable** for open sets (n>2, plugin-shaped): `downloads/handlers/*` —
http, aria2, rpdl, mega, mediafire, gofile, pixeldrain, browser-fallback.
`priority: u8` on each handler; manager sorts on register.

### Memory, errors, logging, config

- Every `init` has a matching `deinit`. Allocator ownership documented.
- Services own repositories. Repositories own connection handles. App owns
  services. No globals.
- Returned strings are caller-owned (same allocator that was passed in).
- Each context has its own error set in `errors.zig`. Public functions
  return `<Context>Error!T`, not `anyerror!T`.
- `std.log.scoped` directly at call sites. No central enum.
- `config.zig` defines a versioned schema loaded from
  `<data_root>/config.toml`. Loader refuses newer versions, migrates older.

## 1.4 Recipe format (ZON)

ZON files parsed via `std.zon.parse` into typed structs in
`recipe/domain.zig`. No custom lexer; `std.zon` provides line/col diags.

**Anti-RCE is structural.** The `InstallStep` union has only `extract` /
`extract_inner` / `copy` / `move` / `delete` / `chmod_x`. No `run` /
`exec` / `script` variant exists — it can't be expressed.

Game recipe carries: id, name, f95_thread, version, engine, sources (rpdl
/ ddl / mirror), install steps, convert_linux, launch (linux/windows),
sandbox (network/bind_extra), saves (linux/windows), update_strategy.

Mod recipe carries: id, name, f95_thread, version, for_game, version
constraints, requires/conflicts/provides, load_after/load_before, sources,
files (declared writes for conflict detection), install steps.

Validator enforces sha256 hex shape + path-safety (no absolute paths, no
`..` escapes).

## 1.5 Concurrency model

Single dedicated **worker thread** owns all blocking work (downloads,
scrapes, conversions, install plan execution). UI thread stays in dvui's
immediate-mode loop.

- Per-job **single-producer/single-consumer ring** in `util/spsc.zig`.
  Worker writes progress events; UI drains at the start of each frame.
- Job state for UI: **atomic snapshot** — worker maintains a heap-
  allocated `JobState` per job and atomically swaps the `*JobState` pointer.
- Connection pool in `util/db.zig` for read concurrency; writes serialise
  through the worker.

## 1.6 Disk layout

`data_root` (default `<exe_dir>/data/`, overridable via `F69_DATA_DIR`):

```
<data_root>/
  f69.db                          — zqlite, schema versioned
  f95_cookie, rpdl_token          — plain (0600), Secret Service migration deferred
  browser                         — preferred browser persisted from Settings
  recipes/                        — user-authored *.game.zon, *.mod.zon
  covers/                         — fetched cover bytes (+ .t thumbs)
  library/<tid>/                  — per-game tree
    <version>/                    — install dir for that version
      base/, mods/, overlay/      — installer flat-copy layout
      .f69-mods.json              — mod tracker for this install
      .f69-backups/<mod_id>/      — pre-overlay backups when backup_mode=full
    .f69-home/                    — sandbox $HOME (shared across versions)
  cache/
    downloads/                    — in-flight aria2 staging + manager_jobs.json
    convert/sdks/<tag>-<ver>/     — cached SDKs (renpy / nwjs / nwjs-ffmpeg)
  save-backups/<tid>/<ts>/        — manual backups (Detail → Backup saves)
  compat-resources/<id>/lib/      — FHS-libs bundles for compat recipes
```

## 1.7 Database schema

`games` and `mods` keyed by F95 thread id (integer). `installs` keyed by
synthetic UUID (composite of game+version would be awkward as FK).

```sql
CREATE TABLE _schema_version (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, applied_at INTEGER NOT NULL);

CREATE TABLE games (
  f95_thread_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL, developer TEXT, cover_url TEXT, description_md TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  rating REAL, vote_count INTEGER, user_rating REAL,
  completion_status TEXT NOT NULL DEFAULT 'not_started',
  engine TEXT NOT NULL DEFAULT 'unknown',
  latest_version TEXT,
  default_install_id TEXT REFERENCES installs(id) ON DELETE SET NULL,
  sandbox TEXT NOT NULL DEFAULT 'use_default',
  last_played_at INTEGER, total_playtime_s INTEGER NOT NULL DEFAULT 0,
  last_scraped_at INTEGER, created_at INTEGER NOT NULL,
  notes TEXT, screenshots_json TEXT
  -- + columns added by later migrations
);

CREATE TABLE installs (
  id TEXT PRIMARY KEY,
  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
  version TEXT NOT NULL, install_path TEXT NOT NULL UNIQUE,
  executable TEXT, launch_args TEXT, recipe_id TEXT NOT NULL,
  installed_at INTEGER NOT NULL,
  UNIQUE (game_thread_id, version)
);

CREATE TABLE mods ( /* same shape: thread_id PK, FK to games */ );
CREATE TABLE mod_installs ( /* (install_id, mod_thread_id) composite */ );
```

`PRAGMA foreign_keys = 1` so `ON DELETE CASCADE` actually fires.

## 1.8 Shipped phases

### Phase 0 — risk spikes (done, 2026-05-08)

Throwaway code validating the four novel risks before any production work:

- **spike-01 bwrap** — Ren'Py game ran cleanly in bwrap on NixOS. Arg list
  validated. Debian/Arch/Ubuntu/Fedora deferred to Phase 6.
- **spike-02 flat-copy** — synthetic mod overlay over a synthetic base
  game; tracker captures every write; rollback restores byte-for-byte.
  Streaming file copy, mode preservation, hash verification all green.
- **spike-03 Ren'Py convert** — Ren'Py 7.6.1 game converted end-to-end via
  cached SDK; `<game>.sh` launcher generated; carry-forwards identified
  (symlink preservation, streaming copy, mode preservation, launcher chmod).
- **spike-04 dvui busy screen** — 1500-card grid + 50-mod modal rendered
  on NixOS Wayland via SDL3GPU backend. Window opens, layout completes.
  Scroll perf + modal interaction deferred to phase 1 real use.

### Phase 1 — catalog + scraper + UI (done)

zqlite wired, migrations against `_schema_version` with hash + downgrade
protection. Real `upsertGame` / `insertIfMissing` / `listGames` /
`applyScrape` / `setNotes`. Tags as JSON. F95 client with rate-limited
`std.http.Client`; thread scrape extracts rating, votes, cover, name,
version, developer, engine bracket, tag chips.

UI: top bar + sidebar + responsive grid + list + Settings + Import +
Sync All. Pink theme. Cover thumbnails via 64-slot round-robin cache.
Sync runs on a worker thread, drained per frame. Sync-all queue
sequential, skip-on-fail. Notes tab. Editable completion_status +
user_rating. Engine + completion filters. Sort dropdown (name / rating /
votes). Search matches name + developer. "Open thread" button. Delete
with confirm banner.

### Phase 2 — downloads (done)

Aria2 RPC mode from day one. Token-secured RPC. RPDL endpoints
(`POST /api/user/login`, `GET /api/torrent/download/{id}`) ported from
F95Checker. RPDL `.torrent` bytes go via `aria2.addTorrent` (base64),
not temp-file + `addUri`. Per-game Download button on detail screen.

Cross-restart persistence is two-layer: aria2's `--save-session` for
byte-level state + our own `manager_jobs.json` for the id↔gid↔url
mapping. Both atomic-write and versioned.

Hash-verify pipeline: `verify.zig.verifyFile` streams SHA-256 + compares.
Recipe `.ddl` / `.mirror` sources carry expected hash; mismatch logs
loud and skips extract. Download fallback chain: on terminal failure,
`tryNextSource` advances per-game `state.download_attempts` index and
enqueues the next source.

RPDL Settings UI (Round 28): login panel mirrors F95 UX. Token stored
plaintext at `<data_root>/rpdl_token` (libsecret integration deferred).

### Phase 3 — recipe format (done)

`recipe/zon_loader.zig` parses via `std.zon.parse.fromSliceAlloc`.
Anti-RCE structural. `validator.zig` enforces sha256 hex + path-safety.
`saveGame` / `saveMod` round-trip via `std.zon.stringify.serialize` with
atomic tmp+rename. `derive.zig` builds a minimal recipe from a scraped
F95 thread. `findGameByThread` resolves recipes by thread id.

### Phase 5 — convert Win→Linux (done)

Engine detection (`convert/detect.zig`): Ren'Py / RPGM-MV / RPGM-MZ /
Unity from install-dir markers.

**Ren'Py** (`convert/renpy.zig`): version detection from `vc_version.py`
+ `__init__.py` fallback (shared with `compat/` via `util/renpy.zig`);
SDK copy; launcher with `steam-run` wrap on NixOS, plain exec elsewhere;
idempotency check.

**RPGM MV/MZ** (`convert/rpgm.zig`): `detectChromeMajor` streams the first
8 MiB of `nw.dll` for the embedded `Chrome/<N>` string; `nwjsVersionFor`
chooses recipe pin → detected → table lookup. Full Chrome→nwjs table
ported from `fix-linux-games.sh` (51 rows: 41, 80-131). `installNwjs`
copies SDK; `findLauncherName` prefers `Game.exe`; `writeLauncher` emits
bash launcher with `LD_LIBRARY_PATH=$(pwd)` + `GDK_BACKEND=x11` on
Wayland.

**Network SDK fetch** (`convert/sdk_cache.zig`): URL builders for renpy /
nwjs / nwjs-ffmpeg; GET → in-memory `Io.Writer.Allocating` → gzip
decompress → `std.tar.extract` (or zip extract for nwjs-ffmpeg) into
`<cache>/convert/sdks/<tag>-<version>/`. `strip_components=1`. Idempotent.

**Codec swap** (Round 29): `installFfmpegCodecs` fetches the
nwjs-ffmpeg-prebuilt release zip + overwrites `<install>/lib/libffmpeg.so`.
Best-effort: a failure logs a warning but doesn't abort.

**Multi-distro syslibs** (Round 21b, `convert/syslibs.zig`): ports the
`bundle_syslibs` flow from `fix-linux-games.sh`. Pure `parseLddOutput`
extracts `=> not found` names. `bundle()` spawns `ldd <binary>`, parses,
copies hits from per-distro paths (Debian leads with
`/usr/lib/x86_64-linux-gnu`, Fedora with `/usr/lib64`, Arch with
`/usr/lib`, NixOS no-ops — `steam-run` handles it). Single pass;
transitive deps via re-run is a follow-up.

**Auto-convert on Launch** (Round 23): `doLaunchGame` checks if
`recipe.launch.linux` exists under the install dir; if not + `convert_linux
!= .none`, runs `convert_svc.convert(install_path, spec, force=false)`
first.

### Phase 6 — sandbox (done on NixOS; multi-distro testing open)

Production `sandbox/linux_bwrap.zig` ported from spike-01. `Bwrap.detect`
(PATH lookup + `unshare -Ur true` userns smoke). Pure `buildArgv`
function (10 unit tests cover distro variants + network + display +
bind_extra). `launch` arena-allocates path joins then `std.process.spawn`.

`Sandbox` tagged union (bwrap / sandboxie / none). `pickBackend` returns
`.none` when bwrap missing or userns blocked, surfacing
`BackendUnavailable` cleanly.

**NoSandbox fallback** (Round 25): clones the host environ via
`Environ.createMap`, overrides `HOME`, spawns with inherited stdout/stderr.
No isolation but games run on Debian/Ubuntu hosts where bwrap fails the
userns smoke. UI surfaces `backend=none` so the user knows.

**Stop button + running-games tracking** (Round 30): `state.running_games`
maps thread_id → pid. Detail screen swaps Launch ↔ Stop. `doStopGame`
sends SIGTERM via `std.posix.kill`. `drainRunningGames` probes via
`kill(pid, 0)` per frame and prunes dead entries.

Per-game sandbox HOME at `<library>/<tid>/.f69-home/` so saves carry
across versions. **Backup saves** (Round 33): Detail-screen Backup
button copies `.f69-home/` → `<data_root>/save-backups/<tid>/<ts>/`.

### Phase 7 — mods (MVP done)

`installs` DB table wired (Round 34): `upsertInstall` / `listInstalls` /
`latestInstallForGame` / `freeInstall(s)` / `deleteInstall`. Foreign keys
enforced.

Post-install extracts into `<library>/<tid>/<version>/` (Round 35) and
inserts an `installs` row (UUID v4). Per-game sandbox HOME at the game
level (NOT version level) per the original PLAN promise.

**Resolver** (Round 36): `resolver/solver.zig` does BFS expansion +
declared-conflict detection + topo sort over `load_after`/`load_before`
via Kahn (`util/kahn.zig` with 6 unit tests). Returns a `SolveResult`
union (.ok / .conflict / .missing / .cycle). 9 unit tests.

**Tracker persistence** (Round 37): `InstallLog.Entry` gains `mod_id`,
`BackupMode` enum (`.none` / `.full`), `backup_path`, `sha256`. Atomic
tmp+rename, line-delimited JSON. 5 round-trip tests.

**Install / uninstall pipeline** (Rounds 38-40): `applyModArchive`
extracts to staging, walks the tree, dispatches by (target exists,
backup_mode). `uninstallMod` walks the InstallLog in reverse, deletes
adds, restores from backups, warns on no-backup modifies. Detail Mods
tab swaps Install ↔ Uninstall. Settings has a `mod_backup_default`
toggle (default `.none` per the 15GB-mod feedback).

### Cross-cutting work shipped today (2026-05-17)

These haven't been folded into the per-phase narrative above yet:

- **Two-phase sync** — `syncWorker` does scrape + cover only; new
  background `imageWorker` fetches screenshots async with its own banner
  row. Library row usable immediately after phase-1 commit. Files:
  `src/ui/{state,actions,screens,ui}.zig`.
- **Mods-page render cache** — `actions.modsPageCache` keyed by
  (thread_id, install_id). Previously the page re-iterated the recipes
  dir, re-parsed every ZON, and reloaded the install tracker on every
  mouse-move frame. Invalidation: thread/install change inside
  `modsPageCache()`, `freeModfileCacheState` cascade, and any terminal
  mod-job transition in `drainModJobs`.
- **`util/renpy.zig` extraction** — Ren'Py version parsers de-duplicated
  out of `convert/renpy.zig` and `compat/detect.zig` into a shared
  `util/renpy.zig`. Both modules now thin-shim through it. Tests moved
  along with the implementation.
- **Direnv / repo hygiene** — `git init`'d the project so flake source
  filtering respects `.gitignore`; 93G of build caches cleaned (the
  flake was hashing them on every direnv reload because no git filter
  was active). Dev shell load time went from "hangs" to ~2.5s.

### Compat recipes — followups (shipped 2026-05-17)

The compat module shipped earlier with one recipe (`linux.renpy.sdl-fhs`).
Three follow-ups landed today:

- **`host_lacks_any_soname` Detect variant** — fires when ANY listed
  soname is missing on the host. Recipe-author-friendly: a stripped
  Debian container that has libX11 but lacks libXmu still trips it.
- **`engine_version_at_most` + `engine_version_at_least` Detect
  variants** — gate recipes on the engine's detected version. Used by
  the Ren'Py 7 vs 8 split. Implemented for Ren'Py via `util/renpy.zig`;
  other engines stub to "no match" until their probes land.
- **Ren'Py 7 / Ren'Py 8 split** — `flake.nix` ships `renpy7-fhs-libs`
  (with GLEW + libXmu + libGLU friends) and `renpy8-fhs-libs` (leaner,
  drops the GLEW transitives Ren'Py 8 doesn't need). Two recipes,
  scoped via `engine_version_at_*`. `linux.renpy.sdl-fhs.compat.zon`
  deleted in favour of `linux.renpy7.sdl-fhs` + `linux.renpy8.sdl-fhs`.
- **RPGM-MV + Unity scaffold bundles + recipes** — `flake.nix` ships
  `rpgm-mv-fhs-libs` (full nwjs runtime: NSS internals, GTK3, accessibility,
  X11 surface — lib list distilled from the user's `fix-linux-games.sh`
  + `nixos-libs.sh`) and `unity-fhs-libs` (X11 + GL + audio + libcurl-gnutls
  starter). Two recipes with `host_lacks_any_soname` detectors. `GDK_BACKEND=x11`
  env_set in the RPGM recipe matches the user's launcher behaviour.

### Architectural review (2026-05-08) — all top-5 actions executed

- Phasing reordered to de-risking order (spikes before catalog before
  downloads before mods).
- Recipe DSL → ZON (cancelled custom parser).
- Concurrency model documented (single worker + SPSC + atomic snapshot).
- Schema migrations get an explicit `_schema_version` table.
- Crash diagnostics path defined.
- Service-over-Repo passthroughs collapsed.
- F95 thread id is the natural primary key for games + mods.
- Recipe gains a `saves` block + UI gets an "Open saves folder" button.
- Aria2 RPC mode from day one (skip stdout parsing).
- OverlayBackend / Sandbox become tagged unions; download Handler stays
  vtable + priority field.
- Flat-copy first; OverlayFS later.

---

# 2. Still planned

## 2.1 Mod tools as recipe blocks (high priority)

Native port of two community tools, integrated as new `InstallStep`
variants in the mod recipe schema so authors can compose them like any
other step (`extract`, `copy`, `chmod_x`). No external Python / shell-out
— the recipe schema's anti-RCE invariant (closed-set tagged union, no
`run`/`exec`/`script`) stays intact.

### Source tools (reference; we don't ship these)

**UnRen v0.8.2** — `~/Downloads/UnRen v0.8.2/`. Bash menu driving:
1. `rpatool` (~600 LOC Python) — extracts `.rpa` Ren'Py archives.
   RPA-1.0 / RPA-2.0 / RPA-3.0 / RPA-3.2: pickle-serialised index →
   optional XOR obfuscation → zlib bodies.
2. `unrpyc.py` (~5000 LOC Python + `decompiler/` helpers) — decompiles
   `.rpyc` to `.rpy`. Pickle + Ren'Py AST opcodes + emitter.
3. `.rpy` injection — drops short Ren'Py snippets into `game/` to enable
   dev console, quick save/load, force-skip unseen, force-rollback.

**RPG-Maker-MV-Decrypter** — `~/projects/RPG-Maker-MV-Decrypter/`. Pure JS.
"Encryption" is: strip 16-byte fake PNG header → XOR first 16 bytes with
a 16-byte key (from `data/System.json` → `encryptionKey`, hex). That's
the whole algorithm. Re-encrypt is the inverse.

### Recipe block design

Extend `src/recipe/domain.zig` `InstallStep` with:

```zig
decrypt_rpgmv: struct { dir: []const u8 = "www", key: ?[]const u8 = null },
decrypt_rpgmz: struct { dir: []const u8 = "img", key: ?[]const u8 = null },
extract_rpa:   struct { dir: []const u8 = "game", delete_after: bool = false },
renpy_enable_console:  struct {},
renpy_enable_quick:    struct {},
renpy_enable_skip:     struct {},
renpy_enable_rollback: struct {},
decompile_rpyc: struct { dir: []const u8 = "game", overwrite: bool = false },
```

`key: null` means "read from `<install>/data/System.json` → `encryptionKey`"
(MV/MZ standard).

### Module placement: extend `src/convert/`

New files:
- `rpgmv_crypt.zig` — MV/MZ decrypt + re-encrypt.
- `rpa.zig` — RPA archive extractor (pickle subset + zlib).
- `unren_toggles.zig` — `.rpy` snippet writers.
- `rpyc.zig` — `.rpyc` decompiler (native port of unrpyc; see Phase 3
  below).

Each exports a small `apply(io, alloc, install_root, opts)` entry point
the installer's step dispatcher calls.

### Phases

| Phase | Scope | Effort |
|---|---|---|
| 1 | `rpgmv_crypt.zig` + `unren_toggles.zig` + `InstallStep` variants + installer dispatch | ½ day |
| 2 | `rpa.zig` (RPA-1/2/3/3.2 extractor — pickle subset + zlib) | 1 day |
| 3a | Pickle parser + AST node scaffolding for `.rpyc` (no emitter yet) | 1 session |
| 3b | `.rpy` emitter for the 10 most common AST nodes (Say/Menu/Init/Label/Define/Jump/Call/Image/Show/Hide) | 1-2 sessions |
| 3c | Screen language (sl1+sl2), translate blocks, testcase blocks — the long tail of `unrpyc` | 1-2 sessions |

### Tracker integration

Each variant logs what it touched so uninstall can reverse it.
- Decrypt reverses by re-encrypting with the same key (cheap).
- `.rpy` snippet writes reverse by deletion (trivial).
- RPA extract reverses by re-archiving — probably impractical; mark
  uninstall-unsupported and rely on the `new_install` update strategy.

### Open design questions

- `decompile_rpyc` on un-supported opcode: soft-warn + skip, or hard-fail?
  Lean **soft-warn** (decompilation is informational, not load-bearing).
- `decrypt_rpgmv` backup policy: keep originals (lots of disk) or delete
  in place (irreversible without the key)? Lean **keep originals** with
  a per-recipe override.
- RPA `delete_after` default: false (safer than UnRen's default of true).

### License notes

- `unrpyc` — BSD-3 (Yuri K. Schlesner, CensoredUsername). Port should
  credit original authors in file header.
- `rpatool` — MIT (Shizmob).
- `RPG-Maker-MV-Decrypter` — GPL-3 (Petschko). Studying the algorithm
  for re-implementation is fine; XOR-of-16-bytes is not copyrightable.
- Our Zig ports are independent works.

## 2.2 Updates polling — Phase 7.5 (high priority)

How tracked games learn there's a new release without re-scraping every
thread. Borrow XLibrary's endpoint + sharpen the checkpointing.

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
our "stop paging" primitive.

### Checkpoint storage

Two-tier:
- **Global** `settings.last_updates_poll_ts` (unix seconds) — drives
  `days_back` for the next sweep.
- **Per-game** `games.last_seen_thread_ts INTEGER` — newest `ts` we've
  seen on the feed for that thread. Migration adds the column.
- `games.has_updates INTEGER NOT NULL DEFAULT 0` and
  `games.latest_seen_version TEXT NULL` — cleared by user Sync or
  explicit "Mark seen".

### Stop-paging rule

- `days_back = clamp(days_since_last_poll + 1, 1, 30)`. First ever run = 30.
- `fetch(page=1)` → read `pagination.total`. Iterate `1..total`.
- For each entry:
  - lookup `getGameByThreadId`; if absent → ignore (polling, not discovery).
  - if `entry.ts <= last_seen_thread_ts` → skip.
  - if version differs → set `has_updates = 1`, record
    `latest_seen_version`. Don't auto-run sync.
  - update `last_seen_thread_ts = max(old, entry.ts)` regardless.
- After all pages drained → write `last_updates_poll_ts = now`.
- HTTP 429 → bail the cycle, double the next interval (capped at max).

### Cadence + UX

`poll_interval_secs` default 21600 (6 h), min 3600, max 604800.
Settings: "Check for updates every: [hourly / 6 hours / daily / weekly / off]".
First poll fires 60 s after launch.

UI: yellow "update?" pill on the library row + count in the top bar.
Click runs the per-game Sync (clears the flag once the new version
lands in `latest_version`).

### Files

- `src/f95/latest.zig` — new module: URL builder + JSON parse.
- `src/library/library.zig` — migration #4 + helpers.
- `src/ui/actions.zig` — `UpdatesPollJob` worker + `pollOnce` + start/drain.
- `src/ui/screens.zig` — top-bar spinner, library row pill, Settings cadence.
- `src/config.zig` — `poll_interval_secs`.
- 3-4 unit tests.

### Explicit non-goals

- No notification daemon integration.
- No per-mod polling (until mods get a `thread_id` column).
- No alerts/inbox unread polling.
- No external indexer dependency à la F95Checker.

## 2.3 Resolver completions (high priority)

MVP shipped BFS + topo-sort + conflict detection. Three deferred pieces:

- **Version-constraint matching** — `requires = .{ .target = "X", .version = ">=2.0" }`
  is parsed but the solver ignores the constraint. Wire `util_version.satisfies`
  (already exists) through `resolver/solver.zig`.
- **Explanation tree UI** — when a mod set is unsatisfiable, render the
  Cargo-style "because A requires B@>=2 but C requires B@<2" chain. The
  solver already returns a structured `SolveResult` union — UI just
  needs to walk it.
- **Backtracking-with-learning** — Cargo-style. Only meaningful once
  multi-version mod pools exist. Currently each mod has exactly one
  version on disk.

Order: version-constraint → explanation tree → backtracking. The first
two are useful immediately; backtracking pays off later.

## 2.4 Multi-distro sandbox testing (medium priority)

bwrap shipped + green on NixOS. Untested on:
- Debian 12 (sysctl `kernel.unprivileged_userns_clone=0` may block userns)
- Ubuntu 24.04 (AppArmor profile may block userns)
- Arch (expected to work; verify)
- Fedora (SELinux confinement to check)

`NoSandbox` fallback already exists. What's missing is actual VM runs to
confirm detect/fallback works in each case. ~½ day per distro once a VM
is up; ~2 days for the whole matrix with write-up.

## 2.5 Mirror handlers — Phase 8 (medium priority)

Stub handlers exist for Mega / Mediafire / Gofile / browser-fallback
(`downloads/handlers/*.zig`). Either implement them (recipe sources of
those host types would go from "browser handoff" to "auto-downloaded")
or delete the stubs.

Vtable dispatch shape is reserved but unused — current RPDL goes through
free functions in `downloads/rpdl.zig`.

1-2 days per handler, gated by each host's actual API availability.

## 2.6 Per-host rate limiting (medium priority)

The F95 client's 1500ms chokepoint doesn't cover `dl.rpdl.net`. Add a
`per_host_limiter` map keyed by hostname so heavy RPDL fetches don't
trip rate limits. ½ day.

## 2.7 Lower-priority / deferred

- **Self-hosted SDK mirror (Round 21c)** — stand up our own host so we
  control versioning + don't depend on renpy.org / dl.nwjs.io. Defer
  until upstream availability becomes a real problem.
- **Hosted recipe repo + git-sync — Phase 12** — sibling repo, git-pull
  on a schedule, recipe override semantics (user > community > bundled).
  1 week.
- **Browser extension — sibling repo** — `xlibrary-zig-extension`, MV3,
  F95-only. Targets `src/server/` WS+JSON-RPC. 1-2 weeks.
- **OverlayFS optimization — Phase 9** — second `OverlayBackend` variant
  where userns is available; flat-copy stays as fallback. 3 days.
- **Sandboxie integration — Phase 10** — Windows sandbox; box-name
  convention, `Sandboxie.ini` write + `sbiectrl /reload` race lock.
  Deferred until Windows becomes a target. 1 week.
- **Native BitTorrent via libtransmission — Phase 11** — only if
  aria2-subprocess limits bite. Not currently a problem. 1.5 weeks.

## 2.8 UX polish

- **Update notification UX** — once 2.2 polling lands, decide between
  toast / banner / library-row pill / top-bar count (probably all four,
  but priority order matters).
- **Mod load-order UI** — today the resolver computes load order from
  `load_after`/`load_before` rules; UI shows the result but doesn't let
  users edit. Lean rule-driven (no drag-to-reorder); UI just shows
  computed order + explains why.
- **Save-folder open cross-platform** — currently shells `xdg-open`.
  Cross-platform: `open` on macOS, Explorer on Windows. Settle when
  wiring across platforms.

## 2.9 Manual verification

Tiered checklist intended for a confidence pulse on a NixOS dev host.
Every tier still has unchecked items. Run when wanted; file bugs against
failures.

| Tier | Scope | Est |
|---|---|---|
| T1 | Smoke (build/test/launch/quit) | 5 min |
| T2 | Library UX (sort/filter/search/notes/delete) | 10 min |
| T3 | F95 login + sync (real network) | 10 min |
| T4 | Recipes (manual authoring) | 15 min |
| T5 | RPDL login (real network) | 5 min |
| T6 | Downloads (DDL, RPDL, fallback chain, hash verify, mid-restart) | 30 min |
| T7 | Convert (Ren'Py + RPGM, SDK fetch, idempotency, engine mismatch) | 30 min |
| T8 | Sandbox / launch (Wayland, audio, sandbox HOME, Stop button) | 30 min |
| T9 | Saves (Open / Backup / cross-version) | 10 min |
| T10 | Mods (install / uninstall / backup mode / resolver chains) | 45 min |
| T11 | Persistence across restart | 15 min |
| T12 | Failure modes (no bwrap, sysctl off, broken JSON, bad sha) | 20 min |
| T13 | Edge cases (no launch.linux, no recipe, re-download, relative paths) | 15 min |
| T14 | Multi-distro (covered by §2.4 above; needs VMs) | TBD |

### Bug-report template

```
**What I did:** <one-line action>
**What I expected:** <one-line outcome>
**What happened:** <one-line failure>

**Diagnostics → Paths:** <paste path lines>
**Diagnostics → Downloads:** <paste job rows if relevant>
**Diagnostics → Installs:** <paste matching rows>
**stderr (last 30 lines):** <tail -30 /tmp/f69.log>
```

## 2.11 Codebase refactor — design-pattern sweep

A structured review across **30 explicit lenses** (not just "look at the
code and notice repetition") surfaced 30 specific consolidation
opportunities. Some land obvious wins; others I considered and ruled out
with reasons. This section documents both so future-self doesn't
relitigate.

### Lenses examined

| # | Lens | What I looked for |
|---|---|---|
| L1 | File size + function clustering | Where files exceed 1k LOC and could split cleanly |
| L2 | Cross-module dependency graph | Cycles, leakage, unintended deps |
| L3 | Bounded-context fidelity (DDD) | Domain type duplication across contexts |
| L4 | Shared kernel candidates | Value objects used by ≥2 contexts (Engine, Distro, Os) |
| L5 | Anti-corruption layer shape | Parser/scraper/loader consistency |
| L6 | Repository pattern | Where Library / Repo carry their weight vs are passthroughs |
| L7 | Service-over-Repo passthroughs | Plan says "avoid"; reality says? |
| L8 | Aggregates + invariants | Game/Install/Mod boundaries enforced where? |
| L9 | Tagged unions (Sum types) | Are existing closed sets used well? |
| L10 | Polymorphism — vtable vs union | Right tool per dispatch site |
| L11 | Strategy / Factory patterns | Source/handler dispatch shapes |
| L12 | Command pattern | Install steps are commands — is dispatch tidy? |
| L13 | Visitor pattern | Multiple walkers over one tagged union? |
| L14 | Composite pattern | Recursive tree types (compat Detect, resolver Plan) |
| L15 | Chain of Responsibility | Download fallback, recipe override chain |
| L16 | Builder pattern | bwrap argv, SandboxConfig, complex constructors |
| L17 | Decorator pattern | HTTP middleware (rate-limit, UA, cookie) |
| L18 | Observer / Pub-sub | Job progress, state changes |
| L19 | State machine | Job phases, sync states |
| L20 | Concurrency primitives | Worker spawn shape, cancel mechanism, SPSC ring usage |
| L21 | Error sets + recovery | Per-context errors, conversion patterns |
| L22 | I/O abstraction | `std.Io` everywhere; HTTP/process spawn concentration |
| L23 | Memory ownership | Arena vs gpa usage, errdefer consistency |
| L24 | Test fixture sharing | Helpers per file vs shared helpers |
| L25 | Logging scopes | Per-module scope naming, consistency |
| L26 | UI render primitives | dvui call density, DSL candidates |
| L27 | Frame god-object | What everyone depends on |
| L28 | State god-object | Mutable shared state |
| L29 | Persistence pattern | Atomic write, schema versioning, settings sprawl |
| L30 | Domain language | thread_id vs f95_thread vs id consistency |

### 30 findings (with measured evidence)

Each row links the lens(es) that surfaced it. Severity scale:
**🟥 high** = touches >5 sites or actively breeds bugs;
**🟧 medium** = drag on readability/extensibility but localised;
**🟨 low** = polish.

#### Structural / organisation

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F1 | 🟥 | `screens.zig` is **9001 LOC** mixing 8 unrelated screens + 99 `render*` helpers | L1 L26 | one file, 193 fns |
| F2 | 🟥 | `actions.zig` is **10154 LOC** mixing every worker / drain / cache helper / launch flow for the whole app | L1 L27 | 152 `frame: *Frame` sigs |
| F3 | 🟥 | `State` is a **338-field god-object** with filter UI, draft buffers, atomic flags, message buffers, cache pointers, edit fields, modals, ~25 type-erased pointers all in one struct | L28 | `src/ui/state.zig` |
| F4 | 🟧 | `Frame` is a **14-pointer god-object** granting every action access to every service | L27 | 245 functions take `*Frame` |

#### Concurrency / job lifecycle

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F5 | 🟥 | **15 `drainXxx(frame)`** functions share an identical shape (load atomic phase → return if pending → cast opaque → cleanup + apply) | L19 L20 | `drainSync`, `drainImage`, `drainBookmarks`, …, `drainManualInstall` |
| F6 | 🟥 | **12+ Job structs** repeat the same shape: `phase: atomic.Value(u8)`, `cancel: atomic.Value(bool)`, `thr`, `alloc`, `win`, payload | L10 L19 | `SyncJob`, `ImageJob`, `BookmarksJob`, `UpdateCheckJob`, `RpdlDownloadJob`, `DonorDownloadJob`, `RefreshTagsJob`, `ImportJob`, mod-queue jobs |
| F14 | 🟧 | Worker-spawn boilerplate (alloc job → dupe url → spawn → detach → set pending slot → rollback on catch) **replicated 10+ times** | L20 | `src/ui/actions.zig` × 8 |
| F15 | 🟧 | `guiFrame` hand-lists 15 `drainXxx` calls; **no registry**. New worker = touch `ui.zig` + `cancelAllWorkers` + `workersBusy` | L18 L20 | three coupled lists |
| F23 | 🟧 | **Two concurrency models coexist** undocumented: per-job-spawn (sync/image/RPDL/donor/…) and long-lived worker with crash recovery (`mod_job_queue`). Same primitives, different lifecycles | L20 | `mod_job_queue.zig` vs `actions.zig` |
| F10 | 🟨 | `util/spsc.zig` + `util/snapshot.zig` (cache-padded SPSC ring + atomic snapshot) declared, tested, **never imported anywhere** | L20 | grep -r returns 0 hits |

#### Type system / shared kernel

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F16 | 🟥 | **`Engine` declared 4×** across modules with **divergent variants**: `library` (15), `recipe` (5), `convert` (5), `compat` (4 — missing `unknown`). Diverging shapes = silent bugs | L3 L4 | grep -n 'pub const Engine = enum' |
| F17 | 🟧 | **`Distro` declared 2×** (`convert/domain.zig` and `sandbox/domain.zig`), **`ConvertSpec` declared 2×** (`recipe/domain.zig` and `convert/domain.zig`) | L3 L4 | dup grep |
| F7 | 🟥 | **~25 `?*anyopaque` fields in `State`** exist solely to avoid pulling internal types into `state.zig`. Every read goes through `@ptrCast(@alignCast)` | L9 L23 | `pending_sync`, `image_active`, `modfile_cache`, `mods_page_cache`, … |
| F11 | 🟧 | `downloads.Service` re-exported but **zero callers** (same shape as the four Services deleted today) | L7 | grep `downloads.Service` |

#### Cross-cutting plumbing

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F8 | 🟧 | **47 `_buf[N] + _len` pairs** + ~14 hand-written get/set helpers all encoding the same "fixed-cap sentinel-trimmed string" pattern | L1 L26 | `sync_msg_buf`, `login_msg_buf`, `rpdl_msg_buf`, … |
| F9 | 🟧 | **Atomic tmp+rename re-implemented 10+ times** across modules | L22 L29 | `f95/tags.zig`, `installer/tracker.zig`, `recipe/zon_loader.zig`, `recipe/preset.zig`, `convert/preset.zig`, `installer/mod_archives.zig`, `downloads/manager.zig`, `ui/mod_job_queue.zig`, `installer/apply.zig`, `ui/actions.zig` |
| F18 | 🟧 | **`std.http.Client` constructed directly in 5+ places** (rpdl × 3, sdk_cache, f95/auth, f95/client, aria2_rpc) with identical user-agent boilerplate | L17 L22 | dup `http: std.http.Client = ...` |
| F19 | 🟧 | **`USER_AGENT = "f69/0.0"` hardcoded in 4 files**, doesn't track the version string (still says 0.0 after the 0.9 bump) | L22 | `f95/client.zig`, `f95/auth.zig`, `downloads/rpdl.zig`, `convert/sdk_cache.zig` |
| F20 | 🟧 | **14 `std.process.spawn` sites**, no abstraction. Each rolls its own argv/env/stdout-capture/timeout | L22 | aria2, bwrap, ldd, tar, libarchive shellouts, … |
| F21 | 🟧 | **15 small-file settings persisted in `main.zig`** (aria2_port, seed_ratio, browser, ui_scale, auto_check, auto_convert, sandbox_default, auto_update_default, last_update_check, …) each with its own `load*` helper | L29 | 15 `_path = try std.fmt.allocPrint(...)` in main.zig |
| F22 | 🟨 | **Two hand-rolled JSON escape helpers** (`appendJsonStr` in rpdl, `writeJsonString` in mod_archives) coexist with `std.json.Stringify` — pick one | L22 | three writers, inconsistent |

#### Dispatch / polymorphism

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F12 | 🟧 | **5 sites switch on `InstallStep`** (validate, simulate, apply, ui-actions × 2). Adding the 8 mod-tools variants in §2.1 means touching every site. Visitor pattern via `walkSteps(steps, visitor, ctx)` would localise | L13 L14 | grep `switch (step)` |
| F24 | 🟨 | **Download fallback chain is hand-rolled**: `tryNextSource(game_id)` reads `download_attempts` map, increments, refetches recipe sources, enqueues `sources[next_idx]`. Classic Chain of Responsibility, but only one consumer — Strategy/iterator is sufficient | L15 | `actions.zig:9738` |
| F25 | 🟨 | **Recipe `Source` variants (rpdl/ddl/mirror)** each dispatched ad-hoc in `enqueueOneSource`. Could be a method on `Source` itself, but with 3 variants and one caller it doesn't earn the indirection | L11 L12 | `actions.zig` `enqueueOneSource` |

#### Caches / state

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F13 | 🟨 | **Per-cache trio replicated** (`dropX(frame)` + `freeXState(state, alloc)` + `castX(p) → *X` + invalidation hooks) for: modfile_cache, mods_page_cache, preset_cache, running_games, import_job, post_install_jobs. Each cache is different enough that a single generic doesn't fit, but the **trio collapses naturally after F7** | L23 | grep `castModfileCache`, `castModsPageCache`, … |
| F28 | 🟧 | **"What's installed where" is split across three stores**: `installs` SQL table (Library), `<install>/.f69-mods.json` (Tracker), `<mod_archives_dir>/<tid>/index.json` (mod_archives). Each is authoritative for its slice but the boundaries aren't enforced by types — easy to get out of sync | L6 L8 | three load paths |

#### Anti-corruption / external boundaries

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F26 | 🟨 | **10+ `parseX` functions** (HTML scrapers, ZON loaders, JSON loaders) — each its own shape (`pub fn parse(alloc, bytes) !Output`). Already de facto-uniform; no further abstraction needed | L5 | `parseTagsFile`, `parseAllTags`, `parseGameFromBytes`, `parseModFromBytes`, `parseLoginResponse`, `parseSearchResponse`, `parseVcVersion`, `parseVersionTuple`, `parseJsonEntry`, `parseLddOutput` |
| F27 | 🟨 | **`InstallStep` simulate/apply pair** walk the same union with mirrored switches. Visitor (or a `StepRunner` trait) unifies the loop and makes "new variant = compile error in every visitor" the failure mode | L13 | covered by F12 |

#### Rendering / UI

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F29 | 🟧 | **393 raw `dvui.box`/`dvui.label`/`dvui.button`** calls in `screens.zig` — recognisable patterns ("section header", "labelled row", "pill button", "card") begging for a tiny `src/ui/components.zig` DSL on top of dvui | L26 | grep count |
| F30 | 🟨 | **18 `render*Section`** helpers exist but are scattered through `screens.zig` (not a shared module). Lifting them into `components.zig` would consolidate UI vocabulary | L26 | grep `^fn render.*Section` |

#### Testing

| # | Sev | Finding | Lens | Evidence |
|---|---|---|---|---|
| F31 | 🟨 | **No shared test fixtures**. `compat/service.zig` has a private `touchTestFile`; every other test file rolls its own tmpdir + setup. A `util/test_env.zig` `TestEnv` (auto-cleanup tmpdir, synthetic install builder, hand-rolled Host) would compress fixture LOC significantly | L24 | grep finds 1 helper |

### Patterns / approaches considered and rejected (with reasons)

I want this documented so we don't relitigate.

| Pattern | Considered for | Verdict | Why |
|---|---|---|---|
| Dependency Injection container | Frame god-object | **Reject** | Zig has no reflection; a hand-rolled container is more boilerplate than the direct struct. Use per-domain ctx structs (R8 below) instead if and when needed. |
| Visitor pattern (full) | `InstallStep` dispatch (F12, F27) | **Adopt narrow form** | A `walkSteps(steps, visitor, ctx)` helper centralises the iteration loop. Visitor "trait" itself is implicit via Zig's duck-typed `anytype` parameter — no vtable needed. |
| `Cache(K, V)` generic | Per-cache trio (F13) | **Reject** | Each cache has different semantics (slot-array vs hash-map vs single-slot vs FIFO-with-LRU-promotion). One generic doesn't fit all. The dropX+freeX+castX trio collapses naturally after F7 lands. |
| Pure Strategy / vtable for downloads handlers | The unused `Handler` vtable | **Defer** | Vtable scaffold exists in `downloads/handler.zig`; no concrete handlers ship today (RPDL goes through free functions). Wire it up only when implementing Phase 8 mirror handlers (§2.5) — premature otherwise. |
| Event bus / pub-sub for state changes | "Game updated, refresh sidebar" flows | **Reject** | dvui's immediate-mode + atomic-snapshot pattern already gives one-frame-stale semantics for free. Event bus adds indirection and lifecycle bugs without earning anything. |
| Singleton for `f95.Client` | "Single chokepoint for rate limit" | **Already done** | `App` owns one `f95.Client`; it's passed around explicitly. The chokepoint property holds without `Singleton` pattern. |
| Result type / Either monad | Error sets per context | **Reject** | Zig errors already do this with better ergonomics + exhaustive switching. |
| Per-`build.zig` `addImport` helper | 30 repetitive lines (was F-something) | **Reject** | Readable as-is. A helper adds indirection without earning anything. |
| Splitting `library.zig` | 1282 LOC | **Reject** | It's a Repository — 43 SQL strings + transactions + migrations cluster naturally. Splitting buys nothing. |
| Builder pattern for `bwrap` argv | `linux_bwrap.zig:buildArgv` | **Reject** | One consumer, pure function with clear shape. Builder would be ceremony. |
| Anti-corruption parser trait | 10+ `parseX` functions | **Reject** | Already de facto-uniform shape (`pub fn parse(alloc, bytes) !Output`). No further abstraction needed. |
| Decorator chain for HTTP middleware | UA, cookie, rate-limit (F18 F19) | **Adopt simplified form** | A single `util/http.zig` with `client.fetch(url, opts) → Body` that injects UA from `build_options` + handles status classification. Not a full middleware chain — just one helper + one struct. |

### Status of the refactor (2026-05-17)

8 of 11 phases shipped as separate commits (find with `git log --grep="refactor R"`):

| Phase | Status | Commit | Scope |
|---|---|---|---|
| R1 | ✅ shipped | `c690f31` | `util/atomic_io.zig` + dead Service deleted + `util/spsc`/`util/snapshot` deleted + USER_AGENT from `build_options.version` + RPDL JSON via `std.json.Stringify` |
| R2 | ✅ shipped | `8bbcec2` | `util/domain.zig` shared kernel (`Engine` 4× → 1×, `Distro` 2× → 1×, `Os`); compat's missing `unknown` variant is gone |
| R3 | ✅ shipped | `1686abd` | `src/ui/buf.zig` `MessageBuf(N)`; 9 paired `_buf`+`_len` fields collapsed |
| R4 | ✅ shipped | `36f94f9` + `c44f7ea` | `src/ui/owned.zig` — all 25 `?*anyopaque` slots on `State` retyped, **0** remain. Part 1 (`36f94f9`) covered containers + caches; part 2 (`c44f7ea`) covered jobs + modal. `@ptrCast(@alignCast)` in `actions.zig` dropped 39 → 5 (the 5 remaining are legit thread-spawn / vtable boundaries — writer ctx, BookmarksJob worker entry, RunnerCtx, mod_job_queue.Job worker entry). **R6 now unblocked.** |
| R5 | ✅ shipped | `6f0ed4b` | `util/http.zig` + `util/proc.zig` primitives; **call-site migrations are a follow-up — 5 HTTP and 14 process-spawn sites still in their original shape** |
| R7 | ✅ shipped | `3c94d21` | `recipe.walkSteps` Visitor primitive + `recipe/validator.zig` demo migration; simulate/apply/ui-actions switches deliberately left as-is (step-local state doesn't compose with the duck-typed visitor) |
| R10 | ✅ shipped | `be6d7aa` | `util/setting.zig` (`readSingleLine`, `parseBool`, `loadBool`, `loadInt`, `loadFloat`); **main.zig's 15 bespoke `loadX` helpers still in place — migration is a follow-up** |
| R11 | ✅ shipped | `ba35fa9` | `util/test_env.zig` `TestEnv` (auto-cleanup tmpdir + writeFile/touchFile/path helpers); **existing tests still use their bespoke fixtures — migration is a follow-up** |
| R6 | ⏳ remaining | — | `Job(Payload)` template + `spawnJob` + `drainBackgroundJob` + `worker_registry`. R4 prerequisite is now in. Touches every one of 12+ Job structs (all in `owned.zig` now). |
| R8 | ⏳ remaining | — | Split `screens.zig` (9001 LOC) into 8 per-screen files + `components.zig`. Pure organisation. |
| R9 | ⏳ remaining | — | Split `actions.zig` (10154 LOC) into 10 per-domain files. Pure organisation. |

**Follow-up migrations** queued from shipped phases:
- R5: 5 `std.http.Client` and 14 `std.process.spawn` sites should migrate to `util/http` / `util/proc`.
- R10: 15 `main.zig` settings (aria2_port, ui_scale, auto_check, …) should migrate to `util/setting`.
- R11: existing tests should migrate to `util/test_env.TestEnv`.
- R3: remaining `_buf`+`_len` pairs (err_msg in WizardBlock, aria2_port_msg / aria2_seed_ratio_msg with inline memcpy, modfile_id, for_game).
- R4: phase enums other than `SyncJobPhase`/`ImageJobPhase` (UpdateCheckPhase, RpdlDownloadPhase, DonorDownloadPhase, RefreshTagsPhase, TestInstallPhase, ManualInstallPhase, PostInstallPhase, BookmarksJobPhase) stayed file-local in `actions.zig` — nothing reads them outside actions, so moving would be churn.

**To resume in a fresh session**: read this status table first, then `git log --grep="refactor R" --oneline` to see history, then pick a remaining phase from the plan below.

### Refactor plan — risk-ascending, dependency-aware order

Each phase ships independently. Tests stay green on every boundary.
The dependencies between phases matter (R3 unblocks R5, etc.).

#### R1 — tight wins, low risk (½ day)

- **F9 → `util/atomic_io.zig`** with `writeFileAtomic(io, path, bytes)`. 10+ open-codings collapse to one line each.
- **F11**: delete dead `downloads.Service` (zero callers).
- **F10**: delete unused `util/spsc.zig` + `util/snapshot.zig`. Re-add when a real second consumer appears.
- **F19**: read USER_AGENT from `build_options.version` everywhere. Delete the 4 hardcoded `"f69/0.0"` constants. Side benefit: bump propagation works.
- **F22**: pick one JSON write path (`std.json.Stringify.value` — stdlib already does it). Delete the two hand-rolled escape helpers.

#### R2 — shared kernel for value objects (½ day)

- **F16 + F17 → `src/util/engine.zig` + `src/util/os.zig`** (or one `src/util/domain.zig`). Move the richest `Engine` enum (with `fromBracket` / `fromStr`) into the util kernel. Move `Distro` and `Os` too. Every context re-exports as `mymod.Engine = util.Engine` rather than re-declaring.
- Compat's missing `unknown` variant becomes a non-issue.
- `ConvertSpec` stays per-module (recipe ConvertSpec is the parsed-from-ZON shape; convert ConvertSpec is the internal handler input — keeping them lets each evolve independently). Adopt an explicit `recipe.ConvertSpec.toConvert(): convert.ConvertSpec` translator with a unit test.
- Net delete ~80 LOC. **Bug class eliminated**: silent divergence between Engine variants.

#### R3 — generic `MessageBuf(N)` (½ day)

- **F8 → `src/ui/buf.zig` `MessageBuf(comptime cap: usize) type`.** Replaces 47 `_buf[N]` + `_len` pairs and ~14 get/set helpers. Each site becomes one line. Pure data type, trivially testable.
- Net delete ~200 LOC; trims `state.zig` by ~25%.

#### R4 — kill the `*anyopaque` workaround (1 day) ← prerequisite for R6

- **F7 → `src/ui/owned.zig`.** Holds the heap-allocated state types that today are private to `actions.zig` (`ModfileCache`, `ModsPageCache`, `PresetCache`, `RunningGames`, `DonorJobs`, `ImportJob`, `PostInstallJobs`, …). `state.zig` and `actions.zig` both import it.
- Every `?*anyopaque` field becomes `?*owned.ModfileCache` etc. Every `castX` helper vanishes. Every `@ptrCast(@alignCast(...))` call vanishes.
- Risk: wide but mechanical (touches every cache lifecycle site).
- Net delete ~150 LOC; major readability win; **prerequisite for R6** (drain template needs typed slots).

#### R5 — small `util/http.zig` + `util/proc.zig` (½ day)

- **F18 → `util/http.zig::get(io, alloc, url, opts) ![]u8`** that owns the `std.http.Client` lifecycle + injects UA + classifies status. RPDL, sdk_cache, f95/auth, etc. delegate. f95/client.zig keeps its rate-limit + cookie wrapper around it.
- **F20 → `util/proc.zig::run(io, alloc, argv, opts) !Output`** (or `runCapture`, `runIgnoreOutput`). 14 sites collapse to one-call dispatch with consistent error mapping.
- Risk: low; replace one ad-hoc spawn at a time.
- Bonus: F22 (USER_AGENT propagation) lands inside `util/http.zig` constructor.

#### R6 — generic `Job(Payload)` + `Worker(Spawn, Drain)` template (1 day)

- **F6 + F14 + F5 + F15 → `src/ui/job.zig`.** `Job(comptime Payload: type)` carries the common shape:
  ```zig
  pub fn Job(comptime Payload: type) type { return struct {
      phase: atomic.Value(u8),
      cancel: atomic.Value(bool) = .init(false),
      thr: std.Thread,
      alloc: std.mem.Allocator,
      win: *dvui.Window,
      payload: Payload,
      // markDone(), markFailed(err), cancelRequested(), …
  };}
  ```
- `spawnJob(comptime Worker, alloc, win, payload, slot) !*Job(P)` factors the alloc+spawn+detach+slot-set chain.
- `drainBackgroundJob(frame, slot, comptime onDone)` factors the per-frame reap. Each existing `drainXxx` becomes a one-liner pointing at the per-job `onDone` function.
- A `worker_registry.zig` const slice lists every drain. `guiFrame`, `cancelAllWorkers`, `workersBusy` walk the registry. **Adding a new worker = one entry in one place.**
- Net delete ~400-700 LOC depending on how thoroughly we collapse each Job.
- Risk: every worker touched. R4 (typed slots) is a prerequisite so we don't fight `*anyopaque` while migrating.

#### R7 — Visitor / `walkSteps` for `InstallStep` (½ day)

- **F12 + F27 → recipe/domain or installer.** Single helper:
  ```zig
  pub fn walkSteps(steps: []const InstallStep, visitor: anytype, ctx: anytype) !void {
      for (steps) |step| switch (step) {
          .extract => |x| try visitor.onExtract(ctx, x),
          .extract_inner => |x| try visitor.onExtractInner(ctx, x),
          .copy => |x| try visitor.onCopy(ctx, x),
          .move => |x| try visitor.onMove(ctx, x),
          .delete => |x| try visitor.onDelete(ctx, x),
          .chmod_x => |x| try visitor.onChmodX(ctx, x),
          // new variants land here once; any visitor missing a handler
          // is a compile error — exactly the safety property we want.
      }
  }
  ```
- `simulate.zig` and `apply.zig` each become a visitor struct with the methods. The 5 switch sites collapse to one.
- Risk: low; behaviour-preserving.
- Pays off immediately when §2.1 (mod-tools) adds 8 new variants — they land in one place.

#### R8 — split `screens.zig` into per-screen files (½ day)

- **F1 + F30 + F29:** mechanical move:
  ```
  src/ui/screens/library.zig
  src/ui/screens/detail.zig
  src/ui/screens/mods.zig
  src/ui/screens/recipe_editor.zig
  src/ui/screens/settings.zig
  src/ui/screens/import.zig
  src/ui/screens/downloads.zig
  src/ui/screens/diagnostics.zig
  src/ui/components.zig          ← iconButton, iconOnly, diagSection, diagRow, pillButton, sectionHeader
  ```
- `screens.zig` becomes a thin re-export.
- Risk: zero behaviour change. Pure organisation.

#### R9 — split `actions.zig` by domain (1 day)

- **F2:** the 152 actions cluster naturally:
  ```
  src/ui/actions/sync.zig           — syncGame, syncWorker, drainSync, image queue
  src/ui/actions/downloads.zig      — doDownloadGame, drainCompletedDownloads, fallback chain
  src/ui/actions/installer.zig      — postInstallOne/Mod, drainPostInstall, doInstallMod
  src/ui/actions/launch.zig         — doLaunchGame, doStopGame, drainRunningGames, auto-convert
  src/ui/actions/bookmarks.zig      — doPullBookmarks, drainBookmarks
  src/ui/actions/auth.zig           — doLogin, doLogout, doRpdlLogin/Logout, doDonorLogin
  src/ui/actions/mods.zig           — modfilesForGame + modsPageCache + isModInstalled
  src/ui/actions/tags.zig           — startRefreshTags, drainRefreshTags
  src/ui/actions/imports.zig        — F95Checker / xLibrary importers
  src/ui/actions/common.zig         — Frame helpers, Library helpers, error formatters
  ```
- `actions.zig` becomes a re-export wall.
- Risk: pure organisation. Slightly more migration than R8 (internal helpers cross domains — clean while splitting).

#### R10 — settings unification (½ day)

- **F21:** today main.zig wires 15 `<data_root>/<key>` files each with its own `loadType` helper. Introduce `src/util/setting.zig`:
  ```zig
  pub fn Setting(comptime T: type, comptime parser: fn ([]const u8) ?T) type {
      return struct {
          path: []u8,
          value: T,
          pub fn load(...): T { ... reads file, parses, falls back to default ... }
          pub fn save(...) !void { ... writeFileAtomic ... }
      };
  }
  ```
- Each setting becomes `aria2_port: Setting(u16, parseU16) = .{ .path = ..., .value = 0 }`.
- Net delete ~150 LOC across main.zig + the load helpers. Bonus: settings UI in screens.zig can iterate the registry rather than hand-call each save.

#### R11 — test fixtures (½ day) ← optional

- **F31 → `src/util/test_env.zig`.** Provides:
  - `TestEnv.init(name) → tmpdir + auto-cleanup` (deinit runs `deleteTree`).
  - `TestEnv.touchFile(rel, contents) !void`.
  - `TestEnv.makeRenpyInstall(version, scripts) !RenpyFixture`.
  - `TestEnv.makeRpgmInstall(engine, chrome_version) !RpgmFixture`.
  - `TestEnv.makeHost(opts) !Host` for compat tests.
- Most tests will be ~30% shorter. Not blocking anything.

#### R12 — narrow `Frame` (back-burner)

- **F4:** per-domain ctx slices (`FrameSyncCtx`, `FrameDownloadsCtx`, etc.). Functions take the narrower ctx; Frame keeps `toSyncCtx()` adapters.
- Pays off in test isolation (no longer need a full Frame to test one action).
- **Defer** unless tests get hard to write. Currently they don't.

#### R13 — State decomposition (back-burner)

- **F3:** State → nested sub-states (`Filters`, `SyncState`, `DownloadsState`, …). Every `state.foo` access becomes `state.SUB.foo`.
- Wide ripple; pays off only when State god-object actively causes bugs.
- **Defer** until clear motivating bug.

### Suggested execution order

`R1 → R2 → R3 → R4 → R5 → R6 → R7 → R8 → R9 → R10 → R11` then defer R12/R13.

Total estimated effort: **5-6 days** for R1 through R11, sized to fit in
half-day chunks. Each phase is mergeable independently with passing
tests. Dependencies among phases:

- **R6 depends on R4** (typed slots needed to avoid fighting `*anyopaque` while migrating Job templates).
- **R7 stands alone** but enables §2.1 mod-tools landing without 5-switch-site touches.
- **R8 / R9** can run any time after R3 (because `MessageBuf` simplifies the State touches inside the screen splits).
- **R10** stands alone.

### Expected end-state metrics

| Metric | Today | After R1–R10 |
|---|---|---|
| Total source LOC | ~46k | ~44k |
| `actions.zig` LOC | 10154 | ~9 files × ~1000 each |
| `screens.zig` LOC | 9001 | 8 files × ~800 each + `components.zig` |
| `state.zig` LOC | 1331 | ~1000 |
| `state.zig` fields | 338 | ~285 |
| `?*anyopaque` fields in State | ~25 | 0 |
| Distinct Job structs | 12+ | 1 generic + 12 payloads |
| `drainXxx` functions | 15 | 1 generic + registry |
| Tmp+rename re-implementations | 10+ | 1 |
| `Engine` enum copies | 4 (divergent) | 1 |
| `std.http.Client` construction sites | 5+ | 1 (in `util/http.zig`) |
| `std.process.spawn` sites | 14 | 1 (in `util/proc.zig`) |
| USER_AGENT string copies | 4 hardcoded | 1 derived from `build_options` |
| Hardcoded JSON-escape helpers | 2 + stdlib | 1 (stdlib) |
| Settings load helpers in main.zig | 15 | 1 generic + 15 registrations |

None of this is required to ship v1; it's pure ergonomics + bug-prevention.
Pick R1–R3 + R7 if you want only the highest-payoff cleanups before the
next feature; pick the full chain if you want the codebase healthy
before the mod-tools recipe blocks (§2.1) land 8 new InstallStep variants.


Default order if picking up cold:
1. **§2.1 Phase 1** — ½ day, deterministic, lands immediate value.
2. **§2.3 version-constraint matching** — cheap completion of the
   resolver, unblocks recipe authors.
3. **§2.2 Updates polling** — the next big user-visible feature.
4. **§2.4 multi-distro testing** — confirm shipped sandbox is portable
   before more features pile on top.

Don't start §2.1 Phase 3 (rpyc) without a clear runway — it's the
biggest single chunk in the open list.
