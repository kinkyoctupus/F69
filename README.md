# f69

A native F95 game manager for Linux and Windows. You can also add custom games.

<p align="center"><img src=".github/images/f69-library.png" alt="f69 library view — 1509 games in a sidebar-filtered grid"></p>

Status: alpha (0.10.x).

## Inspiration:

f69 stands on the shoulders of two great projects:

- **[F95Checker](https://github.com/WillyJL/F95Checker)** — The first app I found, was nice to easily import my library and check for updates. I took inspiration from how it worked and bits from it's UI.
- **xLibrary** — Later I found Xlibrary, also a great app, I took most inspiration from it's UI.



## Features:

- **F95Zone scraping** — sync thread metadata (rating, votes, version, dev status, last-updated, cover image), pull your bookmark list, watch for updates. Backed by an in-tree F95Indexer client (toggleable, default on) for faster bulk metadata.
- **Multi-protocol downloads** — For automatic download and install you can use rpdl and donor ddls. Or you can manually download something through the downloads links. Seeding controls (seed ratio, seed-time cap) can be changed live without a restart, and a per-host rate limiter keeps f69 polite to servers.
- **Recipe-based mod installs** — Through mod recipes, modding has never been easier. There are several default recipes for renpy and rpgm games. And for more involved mods you can make a custom recipe that you can save and reuse later, or share.(would be great if modders added this themselves)
- **Built-in mod tools** — one-click actions on a game's detail page: **RPG Maker MV/MZ** asset decryption, **Ren'Py** `.rpa` archive extraction, and Ren'Py developer-console enable. No external scripts.
- **Universal mods** — set a mod up once and apply it across every compatible game, with a per-game opt-out when you don't want it on a particular title. If a mod set can't be applied, f69 tells you *why*.
- **Sandboxed game launches** via `bwrap` — Optional sandbox. Safer, and keeps your saves in a single place.
- **Custom launch commands** — override how any install starts (point it at a specific runtime, add flags) right from the detail page.
- **Engine fix-ups** — Not all games are released with linux support, but it's possible to add it most of the time, I've included several fix-ups that add native linux support to Ren'Py and RPGM games that don't include it. RPG Maker XP/VX/VX Ace games run natively via a vendored mkxp-z runtime — no Wine, no win32.
- **Library views, your way** — browse as a grid, a sortable/resizable **list table** (whole-row click, star ratings, status dots), or a **Kanban board** grouped by how far you've gotten. Tag games with your own **labels** and filter on them, and spot **NEW** / **UPDATE** badges at a glance (with filters to show only those).
- **Themes** — light and dark modes, ready-made presets (Midnight, Paper, …) and custom accent colors, picked from a live preview in Settings → Appearance. Your choice persists across runs.
- **Always-on activity bar** — a left icon rail for navigation and a bottom status bar showing live downloads, installs, and syncs.
- **Update notifications** — desktop notification when a sync finds new releases, plus **version pinning** to hold a game on a version and suppress auto-update.
- **Portable data layout** — for the portable bundle, DB, library, covers, recipes and downloads all live in `<dir-of-binary>/data/` — drop the folder on a USB stick and the state travels with it. For system installs (`/usr/bin/f69` from a `.deb` / `.rpm` / AUR / Nix package), data falls back to `$XDG_DATA_HOME/f69` (default `~/.local/share/f69/`).
- **F95Checker / xLibrary importer** — fold an existing library into f69 without re-downloading. F95Checker imports go through a review screen showing every game from the upstream DB (opened read-only) with a Move / Copy / **Link in place** picker — link is the default and never mutates source files.
- **F95Checker DB export** — write your f69 library back to a F95Checker-shaped `db.sqlite3` (backup-rename never overwrites).
- **Per-version playtime journal** — every launch records a play session against the installed version; a per-game **Journal tab** shows your session history broken down by version, and the library row flags an unplayed update when you install a newer release than you've played past the threshold.

## Download:

Tagged releases publish prebuilt artifacts on the [Releases page](https://github.com/Moordp/F69/releases/latest): portable + slim Linux x86_64 tarballs, a Windows x86_64 zip (`f69-windows.zip`, exe + DLLs), and (where the CI matrix succeeds) `.pkg.tar.zst` / `.deb` / `.rpm`.

Or build from source:

```sh
git clone git@github.com:Moordp/F69.git f69
cd f69
direnv allow                    # NixOS users; or `nix develop` on other Nix
zig build portable
./zig-out/bin/run.sh
```

That gives you a self-contained `zig-out/bin/` folder (~78 MB, binary + bundled libs + launcher). Move it anywhere — the data travels with it.

NixOS users can skip the bundle:

```sh
nix run github:Moordp/F69#f69
```

## Running:

The launcher (`run.sh`) execs the bundled glibc loader and primes `LD_LIBRARY_PATH` with the host's standard GPU driver paths (`/run/opengl-driver/lib`, `/usr/lib*`). GPU vendor libs (libGL, libGLX_nvidia, libvulkan) **always come from the host driver** — never from the bundle. A Vulkan driver from one machine generally won't work on another.

The slim bundle (`zig build portable-slim` → ~57 MB, no bundled libs) is the alternative if you trust your users to install runtime deps via their distro package manager. See `zig-out/portable-slim/DEPS.md` for the per-distro install commands.

To ship a portable bundle as a tarball:

```sh
tar --exclude=data -C zig-out -czf f69-portable.tar.gz bin
```

## Roadmap:

Not a strict plan — more things that I would like to add and improve:

- **Stable release** — fix all the bugs people report for the first stable release
- **More engine fix-up recipes** — Godot, Ren'Py 6, Unity edge cases (uses fix-up library for missing libGLU.so.1 / libcurl-gnutls)
- **Mod recipe server** — for mod recipe submissions / sharing and browsing
- **Cache server** — like xlibrary and f95checker for faster game info retrieval
- **Browser extension** — F95Checker's pattern of "right-click thread → add to library" is hard to beat
- **macOS support** — not sure... I don't have a mac, so perhaps someone can make a PR for it if they want it.


## Building from source:

`zig build` lists every target. The headline ones:

| Step            | Output                   | What it is                                                                 |
| -----------------| --------------------------| ----------------------------------------------------------------------------|
| `install`       | `zig-out/bin/f69`        | Dev binary; respects `-Doptimize=` and `-Dgui=true`                        |
| `portable`      | `zig-out/bin/`           | ReleaseSafe binary + bundled libs + `run.sh` — drop on any glibc distro    |
| `portable-slim` | `zig-out/portable-slim/` | ReleaseSafe binary + `run.sh` + `DEPS.md` — host supplies the libs         |
| `aur`           | `zig-out/aur/PKGBUILD`   | Arch PKGBUILD; add `-Dcontainer-build=true` to also produce `.pkg.tar.zst` |
| `deb`           | `zig-out/debian/`        | Debian source pkg; container build is experimental (see below)             |
| `rpm`           | `zig-out/rpm/f69.spec`   | Fedora / RHEL / openSUSE spec; container build is experimental             |
| `flake`         | —                        | Sanity-checks `flake.nix` (consumer uses `nix build .#f69`)                |
| `packages`      | all of the above         | Aggregate                                                                  |
| `test`          | —                        | Every module's `test {}` blocks                                            |

**Build flags:**

```sh
-Doptimize=Debug          # default, fast compile, assertions on
-Doptimize=ReleaseSafe    # asserts + opt — "release with debug info"
-Doptimize=ReleaseFast    # max speed, no safety, panics give no info
-Dgui=true                # link dvui + SDL3-GPU (default)
-Dgui=false               # headless build, for CI smoke tests
-Dcontainer-build=true    # invoke podman/docker for aur/deb/rpm (opt-in, see below)
```

## Distribution targets:

The `aur` / `deb` / `rpm` steps produce **source manifests** that downstream packagers feed to their distro's native packaging tool (`makepkg`, `dpkg-buildpackage`, `rpmbuild`). They're the durable handoff contract.

Pass `-Dcontainer-build=true` to also invoke podman or docker against the target distro's image and produce the actual binary package alongside the manifest:

- **AUR** (`archlinux:latest`): working end-to-end. Produces `f69-<ver>-1-x86_64.pkg.tar.zst`.
- **Debian** (`debian:bookworm-slim`): incomplete. Cross-distro static-libarchive symbol mismatch (xml2). Needs a Debian-host packager to wire the right `linkSystemLibrary` call.
- **RPM** (`fedora:latest`): working as of v0.9.1. Data trees install under `%{_datadir}/f69/` (FHS-correct) when invoked with `-Dfhs-layout=true`, which the spec template sets automatically.

The deeper constraint: each distro builds its static libraries with different feature flags, so "one build script, every distro" hits a long tail of per-distro fixes. Run the build on the target distro itself (your dev box or a CI matrix) for the reliable path; the container shortcut from a NixOS dev host is a convenience, not a guarantee.

## CI / releases:

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on every push to `main`, every PR, and every `v*` tag. The matrix:

- `test` — `zig build test` + `zig build test-integration` (headless GUI tests on the dvui testing backend) on Ubuntu
- `portable` — uploads `f69-portable-linux-x86_64.tar.gz`
- `portable-slim` — uploads `f69-slim-linux-x86_64.tar.gz`
- `arch` — runs `makepkg` inside `archlinux:latest`, uploads `.pkg.tar.zst`
- `debian` / `fedora` — native `dpkg-buildpackage` / `rpmbuild` in their target containers, upload `.deb` / `.rpm`
- `windows` — cross-compiles `f69-windows.zip` (exe + resolved DLL closure)
- `nix` — *continue-on-error* (impure-fetch story documented in `flake.nix`)
- `release` — on `v*` tag, collects every successful artifact and posts a GitHub Release

To cut a release: `git tag v0.10.0 && git push origin v0.10.0`.

## FAQ:

<details>
<summary><b>Why a new app instead of contributing to F95Checker?</b></summary>

F95Checker is a Python + ImGui + browser-extension stack. f69 is single-binary native + Linux-only + sandbox-first. Different design point; the codebases share basically zero in implementation while sharing many UX ideas.

If you don't need bwrap sandboxing or native rendering, F95Checker is the more mature option.

</details>

<details>
<summary><b>Why Zig?</b></summary>

Static linking story is straightforward, the language is small enough that contributors can be productive without months of ramp-up, and the cross-compile + build system handle producing the portable bundles without external tooling. Zig 0.16's `std.Io` made the aria2-RPC + concurrent-download story particularly clean.

</details>

<details>
<summary><b>Where does my data live?</b></summary>

Three tiers, first match wins:

1. `$F69_DATA_DIR` env var — explicit override, always wins. The bundled `run.sh` launchers set this to `<bundle>/data/` so data lands next to the launcher (not next to the loader inside `lib/`).
2. **Portable install** (binary anywhere user-writable) — `<dir-of-binary>/data/`.
3. **System install** (binary under `/usr/bin/`, `/nix/store/...`, or `/opt/...`) — `$XDG_DATA_HOME/f69`, defaulting to `~/.local/share/f69/`.

Layout under the resolved root: `f69.db`, `library/`, `covers/`, `recipes/`, `downloads/`, `f95_cookie`.

</details>

<details>
<summary><b>Does f69 store my F95 password?</b></summary>

No. It does an XenForo login dance once and persists the resulting session cookie at `<data_dir>/f95_cookie`. The cookie is what authenticates donor DDL pulls and the bookmark importer.

</details>

<details>
<summary><b>How do I clean up build artifacts?</b></summary>

```sh
rm -rf zig-out/
```

If you've run `-Dcontainer-build=true`, podman/docker may have written root-owned files under `zig-out/<distro>/work/`. The container scripts chown back to host UID at the end, but a crashed container leaves them as root — `sudo rm -rf zig-out/<distro>/work/` clears them.

</details>

<details>
<summary><b>What about Windows / macOS?</b></summary>

**Windows** is supported as of 0.10.0 — the CI cross-compiles `f69-windows.zip` (exe + DLL closure) and games launch natively. The Linux-only bits (bwrap sandbox, FHS compat layer) simply don't apply there; on Windows games run unsandboxed.

**macOS** isn't done — I don't have a Mac. Zig's cross-compile and the SDL3 / dvui / sqlite / libavif stack all build on Mac, so a PR would be welcome.

</details>

## Contributing:

The codebase lives under `src/`, one bounded context per directory:

```
src/
  main.zig          entry point; resolves data root, spawns aria2, opens DB
  ui/               dvui screens, state, components, actions
  f95/              F95Zone scraper (XenForo login, donor DDL, BBcode → plain)
  library/          SQLite-backed game store (migrations, queries)
  downloads/        aria2 JSON-RPC client + queue manager
  installer/        post-download extract / apply / sandbox launch
  importers/        F95Checker / xLibrary / folder-scan migration
  recipe/           mod recipes (JSON DAG, version constraints)
  resolver/         Kahn-style topological mod ordering
  convert/          Ren'Py SDK + nwjs / Unity / RPGM fix-ups
  compat/           per-engine FHS lib bundles (NixOS workarounds)
  sandbox/          bwrap wrapper for game launches
  util/             atomic_io, http, archive, version, paths, db, …
```

Build deps are in [`flake.nix`](flake.nix); on non-Nix systems install them with your distro's package manager (the slim-bundle `DEPS.md` has per-distro names).

Dev loop:

```sh
zig build install -Dgui=true
./zig-out/bin/f69
```

Inside the dev shell, `direnv` / `nix develop` supplies the runtime libs so the bare binary launches without `run.sh`. Watch stderr for logs.

Tests:

```sh
zig build test
```

Style + workflow notes live in [`CLAUDE.md`](CLAUDE.md). tldr: caveman prose, lead with files-modified lists, no unnecessary abstractions.

## LLM usage:

This has been supervised vibe coded. I as a software engineer told it how I wanted the code structure to be and Claude made it.

## License:

MIT — see [`LICENSE`](LICENSE).

Thanks to **WillyJL** for F95Checker — the workflow and ideas this app builds on. And to whoever maintained xLibrary before this rewrite.
