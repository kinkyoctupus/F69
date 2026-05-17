# f69 — NixOS test plan

Goes basic → complex. Each tier should pass before moving to the next.
When something breaks: open the **Diagnostics** screen (top bar, `?` icon),
screenshot the relevant section, paste back with the last ~30 lines of
stderr.

**Run:** `zig build && ./zig-out/bin/f69 2> /tmp/f69.log`
(stderr captured to a file so you have logs after a crash.)

**Reset between major test passes:**
```fish
# Portable layout (Round 42 onward) — everything's under one dir.
rm -rf ./zig-out/bin/data
```

**Optional data-dir override:**
```fish
# Move data anywhere you like (USB stick, scratch dir, etc).
F69_DATA_DIR=/path/to/somewhere ./zig-out/bin/f69
```

---

## Tier 1 — smoke (≈ 5 min)

- [ ] **T1.1** `zig build test` passes (131/136 ok, 5 skipped due to subprocess sandbox)
- [ ] **T1.2** `zig build` produces `./zig-out/bin/f69`
- [ ] **T1.3** App launches, library screen renders, 5 seeded games visible
- [ ] **T1.4** Click each top-bar button: **Settings**, **Downloads**, **Diagnostics**, **Import** — every screen renders without crash
- [ ] **T1.5** Super-Q / window-X quits cleanly (no panic, no SDL leak in stderr)
- [ ] **T1.6** Diagnostics shows: `db_path = ~/.config/f69/games.db`, `library_root = ~/games/f69`, `sandbox backend = bwrap` (we're on NixOS), all env vars set
- [ ] **T1.7** Second launch: 5 games still there (DB persists)

## Tier 2 — library UX (≈ 10 min)

- [ ] **T2.1** Click any game → detail screen renders, cover image loads
- [ ] **T2.2** Click **Back** → returns to library, scroll position preserved
- [ ] **T2.3** Notes tab: type "test note", click **Save**, navigate to another game + back → note persisted
- [ ] **T2.4** Sort dropdown: change to **rating** desc — order changes immediately
- [ ] **T2.5** Search field: type "summer" — list filters to matching games
- [ ] **T2.6** Sidebar **Unsynced only** toggle — list narrows
- [ ] **T2.7** Engine filter chips work (renpy / rpgm-mv etc.)
- [ ] **T2.8** Delete button on detail → confirm banner → row gone from library

## Tier 3 — F95 login + sync (≈ 10 min, real network)

- [ ] **T3.1** Settings → F95 section: **Login** with empty fields → red status, "username and password required"
- [ ] **T3.2** Login with your real F95 creds → status flips to "logged in", "loaded stored F95 cookie" log line
- [ ] **T3.3** Restart f69 → still logged in (cookie persisted to `~/.config/f69/f95_cookie`)
- [ ] **T3.4** Library top bar: **Pull bookmarks** button — bookmarks fetched, new games appear in library, "Sync All" auto-kicks in
- [ ] **T3.5** Pick a single unsynced game → detail → **Sync** — metadata fills in (rating, votes, version, tags, cover)
- [ ] **T3.6** Import screen: paste a raw F95 thread URL → import succeeds, auto sync-all
- [ ] **T3.7** Import screen: paste a numeric thread ID → same result
- [ ] **T3.8** Cover image renders on detail screen (the `images/` cache populates under `~/.cache/f69/covers/`)
- [ ] **T3.9** Logout → status flips, cookie file deleted; restart confirms

## Tier 4 — recipes (manual authoring) (≈ 15 min)

Recipes live at `~/.config/f69/recipes/<id>.game.zon`. Hand-author one for
a synced game.

- [ ] **T4.1** Pick a known-working Linux Ren'Py game from F95 (e.g. one already in your library that ships a Linux build). Create `~/.config/f69/recipes/test-game.game.zon` with a minimal recipe pointing at its DDL URL + sha256
- [ ] **T4.2** Open Diagnostics → no install row yet, recipe doesn't show up directly (recipes aren't listed in Diagnostics — we trust the filesystem)
- [ ] **T4.3** On the detail screen for that game: **Download** button should be enabled (recipe found by thread_id). **Convert** button enabled too. **Launch** says "No install at …"

## Tier 5 — RPDL (≈ 5 min, real network)

- [ ] **T5.1** Settings → RPDL section: **Login** with your RPDL creds — status flips to "logged in"
- [ ] **T5.2** Diagnostics: RPDL row says "logged in (token set)". File `~/.config/f69/rpdl_token` exists with mode 0600
- [ ] **T5.3** Restart f69 — RPDL still logged in
- [ ] **T5.4** Logout — token file deleted, status flips

## Tier 6 — downloads (≈ 30 min, real network)

- [ ] **T6.1** Downloads screen: paste a small public test URL (e.g. `https://speed.cloudflare.com/__down?bytes=1048576`) → click **Download** — progress bar fills, status flips to `[done]`
- [ ] **T6.2** Game with `.ddl` source in recipe + valid sha256 → detail screen **Download** → archive downloads + auto-extracts into `~/games/f69/<thread_id>/<version>/`. Diagnostics shows the new install row
- [ ] **T6.3** Game with same setup but **wrong** sha256 in recipe → stderr logs `SHA-256 MISMATCH`, no extract happens, install dir absent
- [ ] **T6.4** Recipe with 3 sources, set the first to a 404 URL → Download → "Source 1/3 failed; trying next" status, second source succeeds, install row appears
- [ ] **T6.5** Game with `.rpdl` source (requires RPDL login from T5) → Download → torrent fetched from `dl.rpdl.net`, handed to aria2 via `addTorrent`, files come down, extract works
- [ ] **T6.6** Mid-download: Quit f69 → restart → in-flight job resumes (aria2 session + manager_jobs.json restored). Diagnostics confirms job still listed
- [ ] **T6.7** Click **Cancel** on a row → status flips to `[cancelled]`. Click **Clear completed** → done/failed/cancelled rows removed

## Tier 7 — convert (≈ 30 min, network for first run)

Pick a Win-only Ren'Py game to test the convert pipeline.

- [ ] **T7.1** Detail screen for the Win-only install → **Convert** button → convert runs. First run downloads the SDK from renpy.org (`~/.cache/f69/convert/sdks/renpy-<v>/` populates). Subsequent runs use cache
- [ ] **T7.2** After convert: install dir gains `lib/py3-linux-x86_64/`, `lib/python<v>/`, `<gameName>.sh` (with `chmod +x`)
- [ ] **T7.3** Click **Convert** again — log says "install already converted; use force=true to rebuild" (idempotent)
- [ ] **T7.4** RPGM MZ Win-only game → same flow. nwjs auto-fetched. libffmpeg.so swapped in. launcher.sh generated. Test MP4 audio in-game (without ffmpeg swap, mp4 audio crashes)
- [ ] **T7.5** Engine mismatch: recipe says `.renpy` but install is RPGM → Convert surfaces "EngineMismatch"
- [ ] **T7.6** SDK fetch with bad version (e.g. `renpy: sdk_version = "9.9.9"`) → 404 → "Convert failed: NetworkError" or similar; cache dir not polluted with partial extract

## Tier 8 — sandbox / launch (≈ 30 min)

- [ ] **T8.1** Converted Ren'Py game → **Launch** → game window opens, Wayland works
- [ ] **T8.2** Audio plays inside the sandbox (PipeWire socket bound correctly)
- [ ] **T8.3** Game writes saves → check `~/games/f69/<tid>/.f69-home/.renpy/<game>/` populates
- [ ] **T8.4** Win-only game launched fresh (no manual convert click) → auto-convert kicks in: status reads "Converting before launch…", then bwrap fires
- [ ] **T8.5** Launch a game with `sandbox.network = false` in recipe → game can't reach internet (test by browsing in-game if applicable, or `bwrap --unshare-net` arg shows in stderr)
- [ ] **T8.6** **Stop** button replaces Launch when game is running → click → SIGTERM, game exits, button returns to Launch
- [ ] **T8.7** Game exits on its own → `kill(pid, 0)` probe detects → button flips back to Launch within one frame
- [ ] **T8.8** Diagnostics shows the running pid while game is up

## Tier 9 — saves (≈ 10 min)

- [ ] **T9.1** Detail screen → **Open saves** → file manager opens `~/games/f69/<tid>/.f69-home/`
- [ ] **T9.2** With recipe carrying `.saves.linux = "$XDG_DATA_HOME/RenPy/<gamename>"` → Open saves opens the resolved path under the sandbox HOME
- [ ] **T9.3** **Backup** button → status reads "Saves backed up to …". Verify `~/.local/share/f69/save-backups/<tid>/<unix-seconds>/` populated
- [ ] **T9.4** Two installs of the same game at different versions → both write to the same `.f69-home/` → saves carry across version switch

## Tier 10 — mods (≈ 45 min, needs a mod recipe + archive)

Hand-author a mod recipe targeting one of your installed games.

- [ ] **T10.1** Drop `~/.config/f69/recipes/test-mod.mod.zon` with `for_game = "<your-game-recipe-id>"` and a `.ddl` source pointing at a small test archive. Open detail → Mods tab → mod appears with name + version, no Install yet
- [ ] **T10.2** Click **Install** on the mod row → archive downloads, applies. Diagnostics → Tracker section shows entries for that mod_id (with `added_file` / `modified_file` kinds)
- [ ] **T10.3** Mod button flips to **Uninstall** (red) after apply completes
- [ ] **T10.4** Open install dir — mod files visible. If the mod added a new file, it's there. If it overwrote `options.rpy`, the modified content is in place
- [ ] **T10.5** Default `backup_mode = .none` → no `<install>/.f69-backups/` dir created
- [ ] **T10.6** Settings → **Mods** section → flip backup to "yes — full backup" → install a different mod → backup dir appears at `<install>/.f69-backups/<mod_id>/`
- [ ] **T10.7** Click **Uninstall** on the `.none`-mode mod → added files deleted, modified files left as-is with stderr warning "was modified but no backup — leaving as-is"
- [ ] **T10.8** Click **Uninstall** on the `.full`-mode mod → added files deleted, modified files **restored** from backup, backup files cleaned up
- [ ] **T10.9** After T10.8: re-launch the game, verify it still runs (modified files came back cleanly)
- [ ] **T10.10** Mod recipe with `requires = .{ .target = "other-mod" }` where `other-mod` recipe is also on disk → solver pulls in the dep when you install the parent. *(Today the UI only installs one mod at a time — verify via Diagnostics that tracker has both mods' entries after install)*
- [ ] **T10.11** Mod recipe with `conflicts = .{"installed-mod"}` → trying to install hits the resolver's conflict path. *(End-to-end UI surface for conflicts is a follow-up; for now check stderr for "DependencyConflict")*
- [ ] **T10.12** Two mods with `load_after` constraint → Diagnostics → Tracker entries appear in topo-sorted order

## Tier 11 — persistence across restart (≈ 15 min)

- [ ] **T11.1** Mid-download → quit → restart → download resumes, no duplicate row in manager_jobs
- [ ] **T11.2** Restart with `installs` rows present → Launch reads the latest from DB, no fallback to legacy `<tid>/` path
- [ ] **T11.3** Quit with a game running → on restart, the running-games map is empty (we don't reattach to orphaned children — that's expected, document if not)
- [ ] **T11.4** Quit with mods installed → restart → tracker still on disk, Uninstall button still works

## Tier 12 — failure modes (≈ 20 min)

- [ ] **T12.1** Remove bwrap from PATH temporarily (`PATH=/usr/bin ./zig-out/bin/f69` if nix profile path is the only bwrap) → Diagnostics shows `backend = none` → Launch works via NoSandbox fallback (no isolation, but the game still runs)
- [ ] **T12.2** Set sysctl `kernel.unprivileged_userns_clone=0` temporarily → bwrap detection should fail → falls to `.none` (you can `sudo sysctl kernel.unprivileged_userns_clone=1` to restore)
- [ ] **T12.3** Remove aria2c from PATH → Download click → status reads "AriaSpawnFailed" or similar, app doesn't crash
- [ ] **T12.4** Disconnect network mid-download → fallback chain trips, "All N sources failed for game …" surfaces
- [ ] **T12.5** Hand-corrupt `~/.cache/f69/downloads/manager_jobs.json` (random bytes) → restart → "manager_jobs.json parse failed" warning, app starts cleanly with empty job list
- [ ] **T12.6** Hand-corrupt a recipe file (truncate mid-string) → `loadGame` returns ZonParseError → other recipes still load
- [ ] **T12.7** Recipe with invalid sha256 (non-hex chars) → recipe validator rejects, log warning

## Tier 13 — edge cases (≈ 15 min)

- [ ] **T13.1** Game with no `launch.linux` in recipe → Launch → "Recipe has no `launch.linux` entry"
- [ ] **T13.2** Game with no recipe at all → Download / Convert / Launch all surface "No recipe for this game"
- [ ] **T13.3** Re-Download an already-installed game → `dirNonEmpty` check skips extract → "already populated, skipping" log
- [ ] **T13.4** Click Download on a game with `.rpdl` source while RPDL is logged out → "Mod download failed: RpdlTokenMissing" *(or similar — the action should not crash)*
- [ ] **T13.5** Install a mod with backup, then install another mod that touches the **same file** → backup chain works (first backup preserved, second backs up the first mod's overwritten version → uninstall chain restores in reverse order)
- [ ] **T13.6** Convert + Launch on a game with a relative `launch.linux = "./run.sh"` → bwrap chdir to `/game`, runs `./run.sh` — verify it doesn't try to resolve against `$HOME` or anywhere weird

## Tier 14 — known-skipped (not testable on this NixOS host)

- [ ] **T14.1** Multi-distro: Debian 12, Ubuntu 24.04 (AppArmor), Arch, Fedora (SELinux) — needs VMs. **Save for the multi-distro phase.**
- [ ] **T14.2** Sandboxie integration on Windows — Windows not currently a target.

---

## Bug-report template

Paste this when you find a problem:

```
**What I did:** <one-line action>
**What I expected:** <one-line outcome>
**What happened:** <one-line failure>

**Diagnostics → Paths:**
<paste path lines>

**Diagnostics → Downloads:**
<paste job rows if relevant>

**Diagnostics → Installs:**
<paste matching rows>

**stderr (last 30 lines):**
```
tail -30 /tmp/f69.log
```
```

---

## Notes for the reviewer

- The 5 skipped tests (`Tier 1.1`) are tar/zip integration tests that need a real subprocess — they'd pass outside the build sandbox.
- Tiers 7 (network SDK fetch), 10 (mod resolver chains), and 13 (edge cases) are the most likely to surface bugs since they exercise the most code paths in series.
- The current sandbox HOME path is `<library_root>/<thread_id>/.f69-home/`. If you re-org `<library_root>` mid-test, saves don't follow.
