# Compat recipes — follow-ups

Three improvements queued for the `src/compat/` module after the initial
Ren'Py SDL FHS-libs recipe landed (2026-05-17). All three are additive
and independent — they can ship in any order, separately or bundled.

## Context (so you don't have to reconstruct it)

The compat module shipped with one real recipe: `linux.renpy.sdl-fhs`.
Its detector boils down to "is Ren'Py + is `libX11.so.6` missing from
the host loader path." Its apply step prepends our `renpy-fhs-libs`
bundle (a `symlinkJoin` in `flake.nix`, materialised into
`zig-out/bin/data/compat-resources/renpy-fhs-libs/lib/`) to
`LD_LIBRARY_PATH`, sets `SDL_VIDEODRIVER=x11`, and the launcher
auto-injects `/run/opengl-driver/lib` and `__GLX_VENDOR_LIBRARY_NAME`
for hardware accel.

The bundle currently has X11 client libs + Wayland client libs + GLU +
GLEW transitive deps + audio client libs + libglvnd, ≈ 119 `.so`s,
~50 MB.

Cross-distro: on Arch/Debian/Fedora the detector returns false (system
has the libs) and the recipe never fires. On NixOS the detector
returns true and the bundle is brought into the sandbox via
`bind_extra` + `LD_LIBRARY_PATH`.

## 1. Per-engine bundles

**Why:** today everything lives in `renpy-fhs-libs`. RPGM-MV / RPGM-MZ
games need a different lib set (their nwjs runtime has different
dlopen patterns). Unity games need yet another. Reusing a single fat
bundle blows up the install size for every user even when they only
play one engine.

**Shape:**

- Add a derivation per engine in `flake.nix`:
  - `renpy-fhs-libs` (already exists)
  - `rpgm-mv-fhs-libs` — nwjs deps: `nss`, `nspr`, `gtk3`, `at-spi2-atk`,
    `libdrm`, `libgbm`, etc. Investigate exact list when first game crashes.
  - `unity-fhs-libs` — Unity ports vary by year; start with the
    `libcurl-gnutls`, `libpng12`, `libstdc++` triad that bites most.
- Export each as a separate `F69_COMPAT_<NAME>` env var in the dev shell.
- Register each via `installCompatResource(b, "<name>", "F69_COMPAT_<NAME>")`
  in `build.zig`.
- One `.compat.zon` recipe per engine, each pointing at its bundle by id.

**Test:** detector for RPGM-MV is `file_exists "www/js/rpg_managers.js"`
(already supported by `engine_fingerprint`); pair with one or two
`host_lacks_soname` checks against deps the bundled nwjs needs.

**Estimated effort:** half a day per engine — most of it is figuring
out which libs the engine's bundled runtime actually wants. Run
`ldd <bundled-binary>` against a representative game; missing entries
go into the symlinkJoin.

## 2. Better detectors — `host_lacks_any_soname`

**Why:** today's recipe uses `host_lacks_soname "libX11.so.6"` as a
proxy for "this host needs FHS-compat help." That's a NixOS-shaped
proxy. A stripped Debian container that has libX11 but lacks libXmu
hits the same Ren'Py ImportError but won't trip our detector.

**Shape:** new variant on `Detect`:

```zig
host_lacks_any_soname: []const []const u8,  // true if ANY missing
host_lacks_all_sonames: []const []const u8, // true only if ALL missing
                                            // (we already have this
                                            // as `host_lacks_sonames_all`)
```

The Ren'Py recipe becomes:

```zon
.detect = .{ .all = .{
    .{ .engine_fingerprint = .renpy },
    .{ .file_exists_any = .{
        "lib/linux-x86_64/libSDL2-2.0.so.0",
        "lib/linux-i686/libSDL2-2.0.so.0",
    } },
    .{ .host_lacks_any_soname = .{
        "libX11.so.6", "libXmu.so.6", "libGLU.so.1", "libGLEW.so.1.7",
    } },
} },
```

Fires on any host missing any of those, regardless of distro flavour.

**Files to touch:**

- `src/compat/domain.zig` — add the union variant
- `src/compat/detect.zig` — implement evaluator
- `src/compat/validator.zig` — validate non-empty list
- `src/compat/recipes/linux.renpy.sdl-fhs.compat.zon` — switch to it
- Add a test that exercises both predicates against synthetic Hosts

**Estimated effort:** an hour.

## 3. Engine-version scoped recipes

**Why:** Ren'Py 7 needs `libGLEW.so.1.7` (old, bundled with the game,
ABI-pinned). Ren'Py 8 dropped GLEW — uses SDL2's renderer directly.
The current recipe targets the Ren'Py 7 dlopen pattern via
`file_exists_any` on the bundled `libSDL2-2.0.so.0` paths, which
happens to match both — but the cure may be subtly wrong for Ren'Py 8
(e.g., we'd be pointing LD_LIBRARY_PATH at a bundle full of libs
Ren'Py 8 doesn't want, which could shadow newer SDL2 internals).

**Shape:**

- Add a `renpy_version` engine-fingerprint helper that peeks
  `renpy/__init__.py` or `renpy/vc_version.py` (the Ren'Py SDK already
  knows how — see `src/convert/renpy.zig`'s `detectVersion`).
- Add a new Detect variant:
  ```zig
  engine_version_at_most: struct { engine: Engine, version: []const u8 },
  engine_version_at_least: struct { engine: Engine, version: []const u8 },
  ```
- Split the current recipe in two:
  - `linux.renpy7.sdl-fhs.compat.zon` — `engine_version_at_most "7.99"`
    → keeps current apply (libGLEW + libXmu + libGLU friends).
  - `linux.renpy8.sdl-fhs.compat.zon` — `engine_version_at_least "8.0"`
    → narrower bundle without GLEW/GLU; just the SDL2 video deps.
- Add tests with synthetic Ren'Py 7 + 8 install fixtures.

**Note:** `src/convert/renpy.zig` already reads the version from
`vc_version.py`. Reuse via a thin domain helper rather than duplicating
the parser.

**Estimated effort:** a day. The new Detect variant is small; the work
is splitting the bundle into renpy7-fhs-libs + renpy8-fhs-libs and
authoring/testing the second recipe.

## Picking order if you get to this later

1. **(2)** first — cheap, makes future recipe authoring more pleasant,
   and covers the "stripped Debian container" case immediately.
2. **(1)** when the first non-Ren'Py game fails to launch.
3. **(3)** when Ren'Py 8 games show up in the library (they will).
