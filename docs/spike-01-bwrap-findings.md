# spike-01-bwrap — findings

PoC code: `spikes/spike-01-bwrap.zig`. Run via `zig build spike-bwrap -- <install> <sandbox-home>`.

Goal: validate the bwrap arg list across NixOS / Debian / Arch / Fedora before sinking phase-6 effort into `sandbox/linux_bwrap.zig`.

## NixOS — ✅ tested 2026-05-08

**Setup:** Babysitter v0.2.2b Linux Ren'Py game. Sandbox HOME at `/tmp/f69-spike-home`.

**Result:** child runs cleanly inside sandbox.

```
[spike] distro: nixos
[spike] bwrap: /nix/store/dk9qhjgg469lv6mriys7v4c59igarmvx-bubblewrap-0.11.1/bin/bwrap
[spike] unpriv userns: OK
[spike] display: wayland=wayland-1 x11=null runtime=/run/user/1000
[child] HOME=/tmp/f69-spike-home PWD=/game
[child] /game contents: Babysitter.py Babysitter.sh README.html game icon.png
[child] writable HOME?: yes
[child] network?: no/blocked
[spike] child exited: 0
```

**Working:**
- `--ro-bind /usr` + `/nix` + `/run/{current-system,wrappers,opengl-driver,opengl-driver-32}` is enough for NixOS userland.
- `--unshare-{user,pid,ipc,uts,cgroup-try}` + `--die-with-parent` work without sysctl tweaking.
- `$HOME` redirection lands the sandbox at the per-game dir as intended.
- `/dev/dri` bind for GPU works.
- Wayland socket bind via `$XDG_RUNTIME_DIR/wayland-1` works.
- PipeWire / PulseAudio / DBus session bus binds work.

**Open / not tested yet:**
- DNS resolution inside sandbox returned "no/blocked" even though `--unshare-net` isn't set. Root cause: didn't bind `/etc/nsswitch.conf` or the NSS plugin .so files (NixOS keeps these under `/run/current-system/sw/lib/libnss_*`). For a real game launch this won't matter (game uses `getaddrinfo` which works because we DID bind `/etc/resolv.conf`), but if a game does host name lookups via `getent`-shaped APIs we may need the binds.
- GUI launch — only ran a bash diagnostic; haven't actually started Babysitter's `Babysitter.sh` inside the sandbox yet.
- 32-bit games — the only 32-bit graphics path is `/run/opengl-driver-32`; bound via `--ro-bind-try`.

**Action:** before phase 6 production code:
- Add `--ro-bind-try /etc/nsswitch.conf` and `/run/current-system/sw/lib` to the arg list.
- Test with an actual GUI launch (next iteration of this spike).

## Debian 12 — ⏳ untested

**Expected gotchas:**
- `kernel.unprivileged_userns_clone=0` by default. Surface `sysctl` instruction.
- `/lib`, `/lib64`, `/bin`, `/sbin` populated → no `/nix` binds needed.
- Pulse uses `$XDG_RUNTIME_DIR/pulse/native`; PipeWire optional.
- Don't have `/run/opengl-driver` paths.

## Arch — ⏳ untested

**Expected gotchas:**
- `kernel.unprivileged_userns_clone=1` by default → spike should "just work."
- Path layout same as Debian.
- Most users have PipeWire.

## Ubuntu 24.04 — ⏳ untested

**Expected gotchas:**
- AppArmor profile blocks unprivileged userns even with sysctl set. May require unconfined profile or `apparmor-profiles-extra`.

## Fedora — ⏳ untested

**Expected gotchas:**
- SELinux. May need `setsebool -P unconfined_login on` or per-process domain.
- Path layout same as Debian/Arch.

---

## Phase-6 implementation notes (carry-forward)

The arg list in this spike is the seed for `src/sandbox/linux_bwrap.zig`. Reuse:

1. Distro detection from `/etc/os-release` — fine as-is.
2. Userns smoke test (`unshare -Ur true`) — fine as-is.
3. The three layered ro-bind sets (common + nixos-specific + non-nixos `/lib*`) — keep this branching.
4. Display-server socket binds — keep, but factor into separate function.
5. Add NSS-related binds for hostname lookups (`/etc/nsswitch.conf`, NixOS NSS lib path).
6. Add `--ro-bind-try /usr/share/fonts` + `~/.local/share/fonts` for fontconfig (otherwise games fall back to bitmap fonts).
7. Add `--ro-bind-try /etc/fonts` for fontconfig config.
8. Decide network policy: default network ON for now; recipe's `sandbox.network = false` adds `--unshare-net`.
9. **Steal more of the arg list from `steam-runtime-launcher-service`** — full-feature reference covers GPU vendor-specific binds (NVIDIA driver binds, AMD Vulkan ICD paths) we haven't touched yet.

## Next spike

`spike-02-flat-copy` — flat-copy a mod over a base game with a file tracker. Lower-stakes than this one since it's just file IO; mostly validating that the overlay/tracker design works on real Ren'Py mod archive shapes.
