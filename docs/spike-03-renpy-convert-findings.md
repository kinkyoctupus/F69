# spike-03-renpy-convert — findings

PoC code: `spikes/spike-03-renpy-convert.zig`. Run via `zig build spike-renpy-convert -- <game_src> <target>`.

Goal: validate the Ren'Py convert pipeline before sinking phase-5 effort into `convert/renpy.zig`.

## Test — ✅ tested 2026-05-08

**Setup:** `AHouseInTheRift-0.8.09r1-pc` (Ren'Py 7.6.1) at `/media/shared/.../games/`. Cached SDK at `~/.cache/renpy-sdk/renpy-7.5.3-sdk` (close-enough version; symlinked as `renpy-7.6.1-sdk` for the spike, removed after).

**Result:** convert produced `/tmp/f69-renpy-out/` containing the full game tree + Linux runtime libs + `ahitr.sh` launcher with `exec steam-run`-wrapped python invocation.

```
[spike] detected Ren'Py: 7.6.1
[spike] major: 7
[spike] SDK: /home/moortu/.cache/renpy-sdk/renpy-7.6.1-sdk
[spike] preparing target /tmp/f69-renpy-out (copy of …/AHouseInTheRift-0.8.09r1-pc) ...
[spike]   copy lib/py2-linux-x86_64 → /tmp/f69-renpy-out/lib/py2-linux-x86_64
[spike]   copy lib/python2.7 → /tmp/f69-renpy-out/lib/python2.7
[spike] copied 2 lib subdirs from SDK
[spike] launcher base: ahitr
[spike] wrote launcher: /tmp/f69-renpy-out/ahitr.sh (steam-run: true)
```

The launcher script:

```bash
#!/usr/bin/env bash
cd "$(dirname "$(readlink -f "$0")")"
ARCH="x86_64"
if   [ -d "lib/py3-linux-${ARCH}" ]; then LIB="lib/py3-linux-${ARCH}"
elif [ -d "lib/py2-linux-${ARCH}" ]; then LIB="lib/py2-linux-${ARCH}"
elif [ -d "lib/linux-${ARCH}" ];     then LIB="lib/linux-${ARCH}"
else echo "no Linux runtime libs found" >&2; exit 1; fi
export LD_LIBRARY_PATH="${LIB}:${LD_LIBRARY_PATH:-}"
export RENPY_PLATFORM="linux-${ARCH}"
if   [ -x "${LIB}/python" ];  then PYTHON="${LIB}/python"
elif [ -x "${LIB}/pythonw" ]; then PYTHON="${LIB}/pythonw"
elif [ -x "${LIB}/python3" ]; then PYTHON="${LIB}/python3"
else echo "no python in ${LIB}" >&2; exit 1; fi

exec steam-run "${PYTHON}" -EO "ahitr.py" "$@"
```

Permissions: `chmod 755` via `Io.File.setPermissions(io, .executable_file)`.

## What this validated

- **Version detection** from `renpy/vc_version.py` (modern Ren'Py 7.4+) using a simple `version = u'X.Y.Z.BUILD'` parse + take-first-3-components. Fallback path for older Ren'Py 7.0–7.3 reads `version_tuple = (X, Y, Z, ...)` from `__init__.py`.
- **SDK lookup** at `~/.cache/renpy-sdk/renpy-<v>-sdk/` (matches user's `fix-linux-games.sh` cache convention).
- **Engine-specific lib detection** — iterates `lib/python*` and looks for `lib/{py3-,py2-,}linux-x86_64`, copies whichever the SDK has.
- **Launcher base detection** — first `*.py` at root wins (Ren'Py convention), falls back to `*.exe` basename.
- **Distro-conditional `steam-run` wrapping** — NixOS-only, plain exec elsewhere.
- **Permissions write** via `setPermissions(io, .executable_file)`.

## What this did NOT validate (still TODO for phase 5 real impl)

- **Network download.** Spike skips the SDK fetch entirely; just expects the cache. Real impl needs `std.http.Client.fetch` + `std.tar.extract` (with `std.compress.flate` for `.tar.gz`; bz2 isn't in std, fall back to `.tar.gz` URL or shell out to `bunzip2`). Ren'Py's `.tar.bz2` is a problem if we want pure-Zig — they also publish `.tar.gz` so use that.
- **Symlink preservation.** copyTree currently follows symlinks (turning them into regular files in the target). Ren'Py SDKs ship `lib/python` as a symlink to the real python binary in `lib/python3.9` etc. Convert breaks if we don't preserve symlinks. **Real impl: handle `.sym_link` in walker, recreate via `Dir.symLink`.**
- **Streaming copy.** `readFileAlloc` + `writeFile` reads each file fully into memory. AHouseInTheRift game tree is several hundred MB; copy was noticeably slow. **Real impl: stream via `File.Reader` → `File.Writer`.**
- **Permissions of executable inside SDK.** The python interpreter we copy from SDK already has +x in the source; need to verify our copy preserves the mode bit. Currently `writeFile` likely creates files with default perms (umask). **Real impl: read source mode, preserve.**
- **In-place vs out-of-place convert.** `fix-linux-games.sh` modifies the game dir in-place. Spike copies first, converts the copy. The real impl will operate in-place during install (already inside the f69 install dir, so safe).
- **ffmpeg codec replacement** (RPGM nwjs path) — not tested here; deferred to spike-04 if we add one for RPGM.
- **System lib bundling** (`bundle_syslibs` from fix-linux-games.sh) — separate concern; runs after the convert step. Not in this spike.

## Carry-forward for phase 5 real impl

When porting `convert/renpy.zig`:

1. **Reuse:** version detection (vc_version.py + __init__.py fallback), SDK URL pattern, lib-subdir copy logic, launcher template.
2. **Add:** symlink preservation in tree copy, streaming reads for large files, mode preservation, network fetch (`std.http.Client` + `.tar.gz`).
3. **Cache layout:** keep `~/.cache/f69/renpy-sdk/` (move from `~/.cache/renpy-sdk/` since that one is shared with `fix-linux-games.sh`). Or honor both for compatibility.
4. **Wrong-version tolerance:** if exact SDK version isn't on the renpy.org server (deprecated old release), try the closest-newer same-major version. Document this fallback rule.
5. **Convert step idempotency:** check for an existing `<game>.sh` launcher and `lib/py3-linux-x86_64`; skip if both present unless `--force`. Same logic as `fix-linux-games.sh`'s `has_linux_support`.

## Zig 0.16 API discoveries (from this spike)

- `Io.Dir.iterate()` — no io param (unlike `walk(gpa)` which is paired with `walker.next(io)`).
- `Io.Dir.cwd().access(io, sub_path, .{ .execute = true })` for exists-check.
- `Io.File.setPermissions(io, .executable_file)` replaces `chmod`. `Permissions` is a target-specific enum that includes `.executable_file` as a stable canonical mode.
- No `std.compress.bzip2` — only flate / lzma / xz / zstd. Skip Ren'Py's `.tar.bz2` URL path.
- `std.http.Client` is `.{ .allocator = gpa, .io = io }` — no `init()` function; struct-literal initialization only.

## Phase-0 status

All three risk spikes are **done**:

- spike-01 (bwrap) — green on NixOS; per-distro testing deferred
- spike-02 (flat-copy) — green end-to-end with rollback
- spike-03 (Ren'Py convert) — green end-to-end (modulo network fetch, which is deferred to phase 5)

Ready to start phase 1.
