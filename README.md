# f69

F95Zone-focused game library manager, written in Zig 0.16 with a dvui +
SDL3-GPU front end. Tracks installs, scrapes thread metadata, manages mod
recipes, and runs games through an optional bwrap sandbox.

Status: alpha (0.9.x). Linux x86-64 only. NVIDIA + Mesa GPUs.

## Quick start

f69 has no released binaries yet (alpha) — to install, clone and build a
portable bundle:

```sh
git clone <repo-url> f69
cd f69
direnv allow                    # NixOS / direnv users; or: nix develop

zig build portable
./zig-out/bin/run.sh
```

That gives you a self-contained `zig-out/bin/` folder (~78 MB, binary +
bundled libs + launcher). Move it anywhere on disk — the app's data
travels with it.

NixOS users can skip the bundle and run directly via the flake:

```sh
nix run github:your-org/f69        # once published; or `.#f69` from a clone
```

## Data directory

The app's state — DB, library, covers, recipes, downloaded mod
archives — lives in `<dir-of-the-binary>/data/` by default. Drop the
binary's folder onto a USB stick or another machine and the data
travels with it.

Override the location with the `F69_DATA_DIR` env var; the bundled
`run.sh` launchers set it explicitly so data lands next to the
launcher (not next to the loader inside `lib/`).

## Running

### From a portable bundle

```sh
zig build portable
./zig-out/bin/run.sh
```

`run.sh` execs the bundled glibc loader and primes `LD_LIBRARY_PATH`
with the host's standard GPU driver paths (`/run/opengl-driver/lib`,
`/usr/lib*`) so it works on every major distro. GPU vendor libs
(libGL_*, libGLX_nvidia, etc.) always come from the host driver —
never from the bundle.

To ship the bundle:

```sh
tar --exclude=data -C zig-out -czf f69-portable.tar.gz bin
```

### From a slim bundle

```sh
zig build portable-slim
cat zig-out/portable-slim/DEPS.md     # check the deps list for your distro
sudo apt install libvulkan1 libwayland-client0 libxkbcommon0 ...    # Debian/Ubuntu
./zig-out/portable-slim/run.sh
```

The slim bundle is ~57 MB vs ~78 MB full. Use it if you trust your
users to install runtime deps themselves, or if you want one binary
that benefits from the host's library updates instead of carrying a
frozen copy.

### Via a distro package

| Distro          | Steps                                                                                 |
| --------------- | ------------------------------------------------------------------------------------- |
| Arch            | `zig build aur -Dcontainer-build=true && sudo pacman -U zig-out/aur/f69-*.pkg.tar.zst`   |
| Debian / Ubuntu | See `zig-out/debian/README.txt` — manifest is ready, build on a Debian host              |
| Fedora / RHEL   | See `zig-out/rpm/README.txt` — stages an `rpmbuild` source tree                          |
| NixOS / Nix     | `nix build .#f69 && ./result/bin/f69`                                                 |

### Via the Nix flake

```sh
# From a fresh clone:
nix build .#f69
./result/bin/f69

# Or run without installing:
nix run .#f69

# As an input from another flake:
inputs.f69.url = "github:your-org/f69";
# then reference f69.packages.x86_64-linux.f69
```

The flake's `packages.f69` derivation wraps the binary with
`makeWrapper`, so `result/bin/f69` works directly without sourcing
the dev shell — the wrapper bakes the runtime `LD_LIBRARY_PATH` into
the binary.

## Building from source

### Prerequisites

- **NixOS / Nix users**: `flake.nix` provides every dep. `direnv
  allow` (or `nix develop`) drops you in a shell with zig, zls,
  SDL3, sqlite, openssl, libavif, dav1d, libarchive, libdbus,
  libwayland, libxkbcommon, libdecor, libvulkan-loader, and the
  X11 client libs all on the path.
- **Other distros**: install the build deps listed in §
  *Dependencies* below; bring your own Zig 0.16.

### Build targets

All flavors run via `zig build <step>`. Default `install` is the dev
binary; the others are for distribution.

| Step             | Output                       | What it is                                                                  |
| ---------------- | ---------------------------- | --------------------------------------------------------------------------- |
| `install`        | `zig-out/bin/f69`            | Plain binary; respects `-Doptimize=` and `-Dgui=true`                       |
| `portable`       | `zig-out/bin/` (full folder) | ReleaseSafe binary + bundled libs + `run.sh` — runs on any glibc distro     |
| `portable-slim`  | `zig-out/portable-slim/`        | ReleaseSafe binary + `run.sh` + `DEPS.md` — relies on host packages         |
| `aur`            | `zig-out/aur/PKGBUILD`          | Arch PKGBUILD; add `-Dcontainer-build=true` to also produce `.pkg.tar.zst`  |
| `deb`            | `zig-out/debian/`               | Debian source pkg (control / rules / changelog); container build incomplete |
| `rpm`            | `zig-out/rpm/f69.spec`          | RPM spec for Fedora / RHEL / openSUSE; container build untested             |
| `flake`          | —                            | Sanity-checks `flake.nix` (consumer uses `nix build .#f69`)                 |
| `packages`       | all of the above             | Runs every distribution target                                              |
| `test`           | —                            | Runs every module's `test {}` blocks                                        |

### Build flags

```sh
zig build install -Doptimize=Debug         # default — fast compile, assertions on, no opt
zig build install -Doptimize=ReleaseSafe   # asserts + opt — best "release with debug info"
zig build install -Doptimize=ReleaseFast   # max speed — no safety checks, panics give no info
zig build install -Dgui=true               # link dvui + SDL3-GPU (default true)
zig build install -Dgui=false              # headless build — for CI / non-GUI smoke tests
zig build aur -Dcontainer-build=true       # also invoke podman/docker (see below)
```

The `portable*` steps always force `ReleaseSafe -Dgui=true` regardless
of the flag you pass — they're meant for distribution.

### Container builds (opt-in)

Pass `-Dcontainer-build=true` to make `aur` / `deb` / `rpm` also
invoke podman or docker against the target distro's image and produce
the actual binary package alongside the manifest. **Status:**

- **AUR** (`archlinux:latest`) — working end-to-end; produces
  `f69-<ver>-1-x86_64.pkg.tar.zst` in `zig-out/aur/`.
- **Debian** (`debian:bookworm-slim`) — incomplete. Apt deps are
  resolvable, source extraction works, but the project's static
  `libarchive` link strategy references xml2 symbols that Debian's
  libarchive13 build expects to find but Zig isn't told to link.
  Workaround left to a Debian-host packager who can fix the
  `linkSystemLibrary` call to match local conditions.
- **RPM** (`fedora:latest`) — script written but not yet exercised.
  Expected to hit similar cross-distro static-lib mismatches that
  need polish on a Fedora host.

The fundamental constraint: each distro builds its static libraries
with different feature flags, so a "one build script, every distro"
container approach hits a long tail of per-distro fixes. The
manifests themselves (PKGBUILD / debian/ / .spec) are the durable
contract — downstream packagers on each distro use them to build
properly, with that distro's normal CI.

Recommendation:
- Default `zig build packages` for the manifest set.
- AUR users get a bonus working `-Dcontainer-build=true` path.
- Debian / Fedora `.deb` / `.rpm` builds: run on the target distro
  (a dev box or a CI matrix) using the generated manifest — that's
  the reliable path; the container shortcut from a NixOS host is a
  convenience, not a guarantee.

## Development

### Dev iteration loop

```sh
zig build install -Dgui=true
./zig-out/bin/f69
```

Inside the dev shell, `direnv` (or `nix develop`) supplies the runtime
libs so the bare binary launches without `run.sh`. Watch stderr for
the per-frame log output.

The codebase follows the workflow + style notes in `CLAUDE.md`. tldr:
caveman prose, lead with files-modified lists, no unnecessary
abstractions.

### Running tests

```sh
zig build test
```

Tests live in each module's `test {}` block.

### Project layout

```
src/
  main.zig          # entry point; resolves data root + spawns aria2 + opens DB
  ui/               # dvui screens, state, components, actions
  f95/              # F95Zone scraper (XenForo login, donor DDL, BBcode → plain)
  library/          # SQLite-backed game store (migrations, queries)
  downloads/        # aria2 JSON-RPC client + queue manager
  installer/        # post-download extract / apply / sandbox launch
  importers/        # folder-scan + F95Checker + xLibrary migration
  recipe/           # mod recipes (JSON DAG, version constraints)
  resolver/         # Kahn-style topological mod ordering
  convert/          # Ren'Py SDK + nwjs / Unity / RPGM fix-ups
  compat/           # per-engine FHS lib bundles (NixOS workarounds)
  sandbox/          # bwrap wrapper for game launches
  util/             # atomic_io, http, archive, version, paths, db, …
flake.nix           # dev shell + packages.f69 derivation
build.zig           # all build steps, including every distribution
                    # target as a custom Step.MakeFn (no shell scripts)
```

### Dependencies — build time

The repo's `flake.nix` is the single source of truth. The short list:

- Zig 0.16 (build tool)
- pkg-config, wayland-protocols, wayland-scanner (linker glue)
- SDL3 (rendering backend)
- SQLite (game library DB)
- OpenSSL (TLS for HTTPS)
- libavif + dav1d (cover-image decoding; statically linked into the
  binary)
- libarchive (`.7z` / `.tar.bz2` / `.tar.xz` / `.rar` extraction)
- zlib, bzip2, xz (libarchive transitive deps)
- libdbus (file-picker XDG portal)
- libwayland / libxkbcommon / libdecor / libX11 + extensions (SDL3
  runtime dlopens — only needed at runtime, not at link)

### Dependencies — runtime

GPU vendor libraries (NVIDIA proprietary, Mesa) MUST come from the
host. We deliberately never bundle them — a Vulkan driver from one
machine generally won't work on another.

The `portable-slim` bundle's `DEPS.md` lists exact runtime package
names per distro.

## CI / releases

`.github/workflows/build.yml` runs on every push to `main`, every PR,
and every `v*` tag:

| Job             | What it does                                                                                  |
| --------------- | --------------------------------------------------------------------------------------------- |
| `test`          | `zig build test` on Ubuntu with apt-installed deps. Fast feedback for PRs.                    |
| `portable`      | `zig build portable` → uploads `f69-portable-linux-x86_64.tar.gz`                             |
| `portable-slim` | `zig build portable-slim` → uploads `f69-slim-linux-x86_64.tar.gz`                            |
| `arch`          | Runs `makepkg` inside `archlinux:latest` → uploads `.pkg.tar.zst`                             |
| `debian`        | Runs `dpkg-buildpackage` inside `debian:bookworm-slim` → uploads `.deb` *(continue-on-error)* |
| `fedora`        | Runs `rpmbuild` inside `fedora:latest` → uploads `.rpm` *(continue-on-error)*                 |
| `nix`           | `nix flake check` + `nix build .#f69` *(continue-on-error — impure fetch)*                    |
| `release`       | On `v*` tag: collects every artifact and creates a GitHub Release                             |

The `debian` / `fedora` / `nix` jobs are marked `continue-on-error: true`
because cross-distro static-libarchive quirks (xml2 link, etc.) and the
flake's Zig-fetch-needs-network story aren't resolved yet — they're
documented under §*Container builds (opt-in)*. They run on every push
so we get telemetry on what's still broken, but a failure doesn't block
the release.

To cut a release: `git tag v0.9.1 && git push origin v0.9.1`. The
pipeline gathers every artifact that succeeded and posts them as a
GitHub Release with auto-generated notes.

## Cleaning generated artifacts

`zig build packages` writes everything under `zig-out/` (gitignored).
Clear it any time:

```sh
rm -rf zig-out/
```

If you've run `-Dcontainer-build=true`, podman/docker may have
written root-owned files under `zig-out/<distro>/work/` (the container
scripts chown back to the host UID at the end, but a crashed
container leaves them as root). Those need `sudo rm -rf
zig-out/<distro>/work/` to clear.

## LLM usage

This has been supervised vibe coded. 
I as a software engineer told it how I wanted the code structure to be and claude made it.

## License

MIT — see `LICENSE`.
