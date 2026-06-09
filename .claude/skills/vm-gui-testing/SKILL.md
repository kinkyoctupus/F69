---
name: vm-gui-testing
description: Test the f69 GUI on the quickemu Linux VMs — boot, launch f69, screenshot, and drive it with simulated mouse/keyboard (clicks + typing). Use when verifying f69 renders or behaves correctly across distros, reproducing a UI bug on a real desktop, or automating a click-through of the app.
---

# f69 VM GUI testing + input automation

End-to-end recipe for running f69 on the local quickemu VMs, screenshotting the real
desktop, and simulating clicks/typing to drive the app. Figured out the hard way — follow
it instead of rediscovering.

## TL;DR pipeline

1. Boot a VM → it **auto-logs into KDE Plasma Wayland** (already configured, see Autologin).
2. Make sure the VM has a **Vulkan ICD** (f69 = SDL3 GPU = Vulkan, no GL fallback).
3. Get f69 onto it (portable bundle tar, or native pkg) and launch with the session env.
4. Screenshot with `spectacle -b -f -n -o ~/shot.png`, base64 it back to the host, `Read` it.
5. Simulate input with **dotool** (uinput; fractional mouse coords + `type`/`key`). Not ydotool, not wtype — see Input.

## VM inventory + connection

VMs live in `~/VMs/` (quickemu). Creds in `~/VMs/vms.env` (`VM_PASS`, plus
`name:host:port:user:proto:conf` list). **One VM at a time** (each allocs ~8–16G RAM).

| name | distro | user | DM | notes |
|------|--------|------|----|-------|
| cachyos | Arch | cachyos | plasma-login-manager | passwordless sudo; native f69 at `/usr/bin/f69`; dotool(AUR)+ydotool+wtype |
| pikaos | Debian/PikaOS 4 | pika | SDDM | sudo needs password (sudo-rs); dotool built+installed |
| bazzite | Fedora atomic | bazzite | SDDM | `/etc` writable overlay; glibc 2.41; dotool built in fedora:41 distrobox; ydotool in base |
| nobara | Fedora 43 KDE | nobara | plasma-login-manager | dotool built+installed; Vulkan ICD is `lvp_icd.x86_64.json` (Fedora arch-suffixes the name) |
| windows | Win10 | w10 | — | RDP :3389 (not covered here) |

**Connect via `~/VMs/g.sh`** (wrap so sshpass+ssh are on PATH):
```
nix shell nixpkgs#sshpass nixpkgs#openssh -c bash ~/VMs/g.sh up   <name>            # UP/DOWN probe
nix shell nixpkgs#sshpass nixpkgs#openssh -c bash ~/VMs/g.sh ssh  <name> "<cmd>"
nix shell nixpkgs#sshpass nixpkgs#openssh -c bash ~/VMs/g.sh push <name> <src> <dst>
nix shell nixpkgs#sshpass nixpkgs#openssh -c bash ~/VMs/g.sh run  <name> <localfile>  # base64s a bash script + runs it (fish-safe; guests vary)
```
Multi-line / quote-heavy commands: write a local `/tmp/x.sh` and use `g.sh run` (NOT `g.sh ssh "..."`).

**Windows VM readiness — use the real RDP handshake, not a port check.** QEMU slirp `hostfwd`
accepts the *host-side* TCP connect even when the guest service is down, so `/dev/tcp` or
`nc -z` on 3389/22224 lie (they also "succeed" when Windows is still at boot). **`~/VMs/rdp-ready.sh
<host> <port> [poll_seconds]`** does a proper X.224 Connection-Request/Confirm exchange and only
returns 0 when the guest RDP stack actually negotiates. The runner uses it as `wait_rdp`. RDP in
with `xfreerdp /v:localhost:3389 /u:w10 /p:<VM_PASS> /cert:ignore +clipboard /dynamic-resolution`.
(Win10 here has **no OpenSSH server** — the SSH:22224 handshake times out — so there's no in-guest
agent to type/click yet; input automation on Windows would need OpenSSH+PowerShell set up first,
or host-side injection into the RDP window. f69 also doesn't cross-compile to Windows yet: 9/11 C
deps have mingw-w64 builds but `acl` (POSIX) + `libavif` (no mingw) need conditional-out, and the
build currently links the *native* nix libs for the win target.)

**Boot / kill** (quickemu is on PATH; SPICE viewer opens on the host display):
```
cd ~/VMs && nohup quickemu --vm <conf> >/tmp/boot.log 2>&1 &      # conf = the *.conf name
cd ~/VMs && quickemu --vm <conf> --kill
# then poll: for i in (seq 30); g.sh up <name> | grep -q UP; and break; sleep 5; end
```

## Autologin (already set up; here's how/why)

A cold boot must reach a graphical session unattended. Already configured + verified on all
4 Linux VMs. The DM differs — write the matching file (see `~/.claude-personal/.../memory/vm-autologin.md`):
- **plasma-login-manager** (cachyos, nobara): `/etc/plasmalogin.conf`
- **SDDM** (pikaos, bazzite): `/etc/sddm.conf.d/zz-autologin.conf` (the `zz-` prefix beats the distro's `kde_settings.conf` which ships a blank `User=`)
- Body: `[Autologin]` + `User=<user>` + `Session=plasma.desktop` + `Relogin=false`; also `gpasswd -a <user> autologin`.
- sudo-rs trap: prime once `echo $PW | sudo -S -v`, then plain `sudo tee` (with `-S` cached, the password leaks into the file).

Decisive check after boot: `ls /run/user/1000/wayland-0` and a `Type=wayland` session on seat0.

## Vulkan is mandatory

f69 uses the SDL3 **GPU API → Vulkan, with NO OpenGL fallback**. No ICD ⇒
`Failed to create device: No supported SDL_GPU backend found! error: BackendError`.
- Real distro desktops already ship lavapipe (`/usr/share/vulkan/icd.d/lvp_icd.json`) — usually nothing to do.
- A bare VM with none: install software Vulkan. Arch: `sudo pacman -S vulkan-swrast vulkan-tools`. Verify `vulkaninfo | grep deviceName` → `llvmpipe`.

## bazzite quirk — disable Steam autostart

Bazzite auto-starts **Steam**, whose login modal grabs focus and overlays f69 in the center, so
input automation types into Steam instead of f69 (and `pkill steam` doesn't stick — it relaunches).
One-time fix: neutralize its autostart entry, then it stays gone across reboots:
```
mkdir -p ~/.config/autostart
printf '[Desktop Entry]\nType=Application\nName=steam\nHidden=true\nX-GNOME-Autostart-enabled=false\n' > ~/.config/autostart/steam.desktop
```
(Even with Steam gone, bazzite's exact f69 layout sits a few px off the others, so the offset-derived
username/password field clicks can miss the small input boxes — the Sign-in *button* still gets hit.
The render is verified on bazzite; the login click-through is the flaky part there.)

## Get f69 onto the VM + launch

**Portable bundle (distro-agnostic, carries its own glibc):**
```
# host: build once, tar without the big data/ dir
zig build portable          # -> zig-out/bin/{f69,lib,run.sh,aria2c,data}
tar cf /tmp/f69-portable.tar -C zig-out/bin f69 lib run.sh aria2c     # ~350M
g.sh push <name> /tmp/f69-portable.tar /tmp/f69-portable.tar
g.sh ssh  <name> "rm -rf ~/f69test && mkdir ~/f69test && tar xf /tmp/f69-portable.tar -C ~/f69test"
```
> If it SIGBUSes in `_dl_map_object_from_fd`/`memset` at startup, a bundled `.so` got
> truncated on the guest disk — **re-extract the tar** (it's a corrupt copy, not an f69 bug).

**Launch on the live Wayland session** — **use `systemd-run --user`, NOT `nohup … &` over SSH.**
A backgrounded f69 (and the aria2c it spawns) keeps the SSH channel's fds open, so the `ssh`
call **hangs forever** even with `setsid`/`</dev/null`. systemd-run starts a detached transient
unit and the SSH call returns immediately:
```
# via g.sh run (base64→bash; cachyos shell is fish, so don't send bash loops/`()` directly):
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
systemctl --user stop f69run 2>/dev/null; systemctl --user reset-failed f69run 2>/dev/null
systemd-run --user --unit=f69run --setenv=XDG_RUNTIME_DIR=/run/user/1000 --setenv=WAYLAND_DISPLAY=wayland-0 \
  bash -c 'cd ~/f69test && exec ./run.sh >~/f69.log 2>&1'      # portable; native: bash -c 'exec f69 >~/f69.log 2>&1'
# stop it later with: systemctl --user stop f69run
```
Success log lines: `SDL3GPUBackend: Graphics pipeline created successfully` + `dvui: window logical Size … 1280 800`.
**Liveness check:** the portable bundle runs as `ld-linux-x86-64 … /f69test/f69`, so its process
**comm is `ld-linux-x86-64`, not `f69`** — `pgrep -x f69` returns nothing (false "dead"); use
`pgrep -f 'f69test/f69|f69slim/f69|/usr/bin/f69'`. And grep render marks from the **whole** log,
not `tail -N` (f69 prints many lines after the marks).

## Screenshots

- **Use `spectacle -b -f -n -o ~/shot.png`** (`-b` background, **`-f` fullscreen** — without `-f` it grabs only the active window). KDE-native, captures Wayland windows.
- `grim` FAILS on KDE (no wlr-screencopy). QEMU monitor `screendump` FAILS ("no surface") because the virtio display is GL-accelerated.
- Pull it back + view:
```
g.sh ssh <name> "base64 ~/shot.png" > /tmp/shot.b64
base64 -d /tmp/shot.b64 > /tmp/shot.png      # then Read /tmp/shot.png
```
- spectacle can occasionally SIGABRT during an unstable/just-logged-in session — retry once it settles.

## Input automation (clicks + typing) — the important part

KDE Plasma Wayland constraints (learned empirically):
- **`wtype` does NOT work** — KWin refuses the `zwp_virtual_keyboard_v1` protocol on purpose ("Compositor does not support the virtual keyboard protocol"). KDE steers apps to the libei/RemoteDesktop portal, which needs an interactive permission grant — impractical headless.
- **`ydotool` injects (uinput) but its absolute mode is broken** — `mousemove -a -x -y` is accel-affected relative, not pixel-accurate. Only its *relative* moves are reliable (e.g. pin a corner with `mousemove -x -9999 -y -9999`). Its `type`/`key` work (uinput).
- **`dotool` is the right tool** — uinput (so KWin sees a real device, no protocol issue) AND `mouseto` takes **screen fractions 0–1** that KWin maps correctly regardless of resolution. Mouse + keyboard, one tool.

**Install dotool — all 4 VMs already have it** (`/usr/bin` or `/usr/local/bin/dotool`).
dotool isn't packaged on Debian/Fedora, so it's built from source there. **Build per-distro,
not once + copy** — it's cgo-linked to glibc+libxkbcommon, and a binary built on glibc 2.42
won't run on bazzite's 2.41 (the same glibc floor as the f69 bundle).
- **Arch (cachyos):** `paru -S --noconfirm dotool` (AUR).
- **Debian (pikaos) / Fedora (nobara):** deps are packaged — `apt install golang-go scdoc libxkbcommon-dev git` / `dnf install golang scdoc libxkbcommon-devel git`, then `git clone --depth 1 https://git.sr.ht/~geb/dotool && cd dotool && GOFLAGS=-mod=mod GOCACHE=/tmp/gc GOPATH=/tmp/gp go build -o dotool . && sudo install -m755 dotool /usr/local/bin/`.
- **Fedora atomic (bazzite):** base is immutable, so build in a glibc-matching container — `distrobox create -i registry.fedoraproject.org/fedora:41 -n dotbuild -Y`, then `distrobox enter dotbuild -- bash -lc 'sudo dnf install -y golang scdoc libxkbcommon-devel git && cd /tmp && git clone --depth 1 https://git.sr.ht/~geb/dotool && cd dotool && GOFLAGS=-mod=mod go build -o "$HOME/dotool" .'` (HOME is shared → binary lands on the host), then `sudo install -m755 ~/dotool /usr/local/bin/` (persists via /var/usrlocal). bazzite also ships `ydotool` in the base.

**uinput access:** dotool writes `/dev/uinput` → run via `sudo` (cachyos passwordless; others need the
VM password — `echo $PW | sudo -S -v` once to prime, then `sudo dotool`). Or `sudo gpasswd -a <user> input`
+ relogin to drop sudo. It reads newline-separated actions from stdin; give it a ~0.6s settle
delay so KWin registers the new virtual device:
```
{ sleep 0.6; printf 'mouseto 0.15 0.55\n'; sleep 0.2; printf 'click left\n'; sleep 0.2; printf 'type HELLO\n'; } | sudo dotool
# actions: mouseto X Y (fractions) | click left|right|middle | type STRING | key Return|Escape|Tab|...
```
Quick sanity check that injection reaches the compositor: `mouseto 0.005 0.995` + `click left`
opens the KDE app launcher (bottom-left).

### Finding click coordinates

dotool wants screen *fractions*. To hit a specific widget, find its pixel location in a
screenshot, then divide by screen size. The window is usually centered with wallpaper margins,
so don't assume it starts at (0,0).

Locate a uniquely-colored element (f69's teal accent `#1fa39a`) by row-density (a button is a
solid wide band, accents are thin) — host-side, on a screenshot you already pulled back:
```
nix-shell -p 'python3.withPackages(ps: [ps.pillow])' --run 'python3 - <<PY
from PIL import Image
im=Image.open("/tmp/shot.png").convert("RGB"); W,H=im.size; px=im.load()
teal=lambda r,g,b: r<110 and g>150 and b>140
band=[y for y in range(H) if sum(teal(*px[x,y]) for x in range(W))>150]   # solid teal rows
y0,y1=min(band),max(band)
xs=[x for y in band for x in range(W) if teal(*px[x,y])]
cx,cy=(min(xs)+max(xs))//2,(y0+y1)//2
print(f"center=({cx},{cy}) frac=({cx/W:.4f},{cy/H:.4f})")
PY'
```
For nearby fields, offset from a known anchor: the f69 sign-in card top→bottom is
status / username-label / **username-box** / password-label / **password-box** / **Sign-in button**,
the boxes ~ window-fraction 0.39 / 0.51 / 0.58 vertically, x ≈ same column as the button.

## Worked example — automate the F95Zone sign-in (verified)

```
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
{ sleep 0.6
  printf 'mouseto 0.150 0.446\nclick left\ntype HELLO_f69\n'      # username
  sleep 0.3
  printf 'mouseto 0.152 0.509\nclick left\ntype demo_pass\n'      # password
  sleep 0.3
  printf 'mouseto 0.152 0.551\nclick left\n'                      # Sign in button
} | sudo dotool
sleep 2.5; spectacle -b -f -n -o ~/shot.png
# f69.log then shows a REAL F95Zone POST with username "HELLO_f69" and the server's
# "The requested user 'HELLO_f69' could not be found." — full click→type→action pipeline.
```

## Cleanup

Kill the VM when done: `cd ~/VMs && quickemu --vm <conf> --kill`. dotool/ydotoold leave no
daemon to stop (dotool exits per-invocation). Native f69 / portable stay until `pkill -x f69`.
