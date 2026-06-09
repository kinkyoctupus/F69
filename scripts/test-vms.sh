#!/usr/bin/env bash
# f69 cross-VM GUI test runner. See docs/vm-test-plan.md.
# Boots each VM (autologin), delivers each build, launches f69, asserts render from the log,
# drives a functional sign-in click-through with dotool, and asserts it from f69's network log.
# Drops screenshots + report.md into results/<UTC-date>/.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="$HOME/VMs"
[ -r "$VMDIR/vms.env" ] || { echo "missing $VMDIR/vms.env"; exit 1; }
# shellcheck disable=SC1091
source "$VMDIR/vms.env"          # VM_PASS, VM_LIST (name:host:port:user:proto:conf)
PW="$VM_PASS"
# optional real f95/rpdl creds (host-local, gitignored). If present, the click-through does a
# real login and asserts success; if absent, it types a marker and asserts the "user not found".
[ -r "$VMDIR/f69-creds.env" ] && source "$VMDIR/f69-creds.env"

declare -A CONF USER GLIBC
for e in "${VM_LIST[@]}"; do IFS=: read -r n _ _ u _ c <<<"$e"; CONF[$n]=$c; USER[$n]=$u; done
GLIBC=([cachyos]=2.43 [pikaos]=2.42 [bazzite]=2.41 [nobara]=2.42)
LINUX_VMS=(cachyos pikaos bazzite nobara)
SLIM_FLOOR="2.42"
RENDER_MARK="Graphics pipeline created successfully"
WINDOW_MARK="window logical Size"

# ---- cli ----
VMS_ARG="all" BUILDS_ARG="all" DEPTH="functional" KEEP=0 BAZZITE_NATIVE=0
RESULTS_DIR=""
while [ $# -gt 0 ]; do case "$1" in
  --vm) VMS_ARG="$2"; shift 2;;
  --build) BUILDS_ARG="$2"; shift 2;;
  --depth) DEPTH="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  --bazzite-native) BAZZITE_NATIVE=1; shift;;
  --results-dir) RESULTS_DIR="$2"; shift 2;;
  -h|--help) sed -n '2,8p' "$0"; echo; grep -E '^\s+--' "$0" | sed 's/).*//'; exit 0;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

DATE="$(date -u +%Y-%m-%dT%H-%MZ)"
[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$PROJECT_ROOT/results/$DATE"
mkdir -p "$RESULTS_DIR"

[ "$VMS_ARG" = all ] && VMS=("${LINUX_VMS[@]}" windows) || IFS=, read -ra VMS <<<"$VMS_ARG"
[ "$BUILDS_ARG" = all ] && BUILDS=(portable slim native windows) || IFS=, read -ra BUILDS <<<"$BUILDS_ARG"

# ---- helpers ----
log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }   # stderr: never pollute $(...) captures
G(){ nix shell nixpkgs#sshpass nixpkgs#openssh -c bash "$VMDIR/g.sh" "$@"; }
gssh(){ local vm=$1; shift; G ssh "$vm" "$@"; }
grun(){ G run "$1" "$2"; }                 # vm localscript
gpush(){ G push "$1" "$2" "$3"; }          # vm src dst

boot(){ ( cd "$VMDIR" && nohup quickemu --vm "${CONF[$1]}" >/tmp/boot-$1.log 2>&1 & ); }
killvm(){ ( cd "$VMDIR" && quickemu --vm "${CONF[$1]}" --kill >/dev/null 2>&1 ); }
wait_up(){ local i; for i in $(seq 1 48); do G up "$1" 2>/dev/null | grep -q UP && return 0; sleep 5; done; return 1; }
wait_session(){ local i; for i in $(seq 1 12); do gssh "$1" "ls /run/user/1000/wayland-0" >/dev/null 2>&1 && return 0; sleep 4; done; return 1; }
# windows VM readiness: a REAL RDP X.224 handshake (rdp-ready.sh), not a TCP-port check —
# QEMU slirp accepts the host-side connect even when the guest RDP service is down.
win_hp(){ local e n h p; for e in "${VM_LIST[@]}"; do IFS=: read -r n h p _ _ _ <<<"$e"; [ "$n" = windows ] && { echo "$h $p"; return; }; done; }
wait_rdp(){ local hp; hp="$(win_hp)"; bash "$VMDIR/rdp-ready.sh" ${hp:-localhost 3389} "${1:-240}" >/dev/null 2>&1; }

# screenshot the guest desktop -> local png
shot(){ local vm=$1 out=$2
  gssh "$vm" "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0; spectacle -b -f -n -o ~/_shot.png" >/dev/null 2>&1
  gssh "$vm" "base64 ~/_shot.png" 2>/dev/null | base64 -d > "$out" 2>/dev/null
  [ -s "$out" ]
}

# find teal Sign-in button center -> echo "W H bx by" (empty if not found)
detect_button(){ local png=$1
  cat > /tmp/_btn.py <<'PY'
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert("RGB"); W,H=im.size; px=im.load()
teal=lambda r,g,b: r<110 and g>150 and b>140
band=[y for y in range(H) if sum(teal(*px[x,y]) for x in range(W))>150]
if not band: sys.exit(1)
y0,y1=min(band),max(band)
xs=[x for y in band for x in range(W) if teal(*px[x,y])]
print(W,H,(min(xs)+max(xs))//2,(y0+y1)//2)
PY
  # filter to the numeric "W H BX BY" line — the nix-shell --run env prints noise (e.g. "Next: zig build run") first
  nix-shell -p 'python3.withPackages(ps: [ps.pillow])' --run "python3 /tmp/_btn.py '$png'" 2>/dev/null \
    | grep -E '^[0-9]+ [0-9]+ [0-9]+ [0-9]+$' | tail -1
}

# ---- verdict table ----
declare -a ROWS
record(){ ROWS+=("$1|$2|$3|$4|$5"); log "  → $1/$2: $3 — $4"; }

# ---- host build steps ----
TAR_PORTABLE="/tmp/f69-portable.tar"; TAR_SLIM="/tmp/f69-slim.tar"
BUILT_PORTABLE=0 BUILT_SLIM=0 BUILT_WIN=0 WIN_EXE=""
build_portable(){ [ $BUILT_PORTABLE = 1 ] && return 0
  log "host: zig build portable"; ( cd "$PROJECT_ROOT" && zig build portable ) || return 1
  tar cf "$TAR_PORTABLE" -C "$PROJECT_ROOT/zig-out/bin" f69 lib run.sh aria2c && BUILT_PORTABLE=1; }
build_slim(){ [ $BUILT_SLIM = 1 ] && return 0
  log "host: zig build portable-slim"; ( cd "$PROJECT_ROOT" && zig build portable-slim ) || return 1
  tar cf "$TAR_SLIM" -C "$PROJECT_ROOT/zig-out/portable-slim" f69 run.sh DEPS.md && BUILT_SLIM=1; }
build_windows(){ [ $BUILT_WIN = 1 ] && return 0
  # Use the verified path: build-windows.sh stands up the mingw C-lib prefix
  # (nix/windows-deps.nix) THEN cross-compiles. Bare `zig build -Dtarget` skips
  # the prefix and fails on the avif/acl/archive mingw deps.
  log "host: scripts/build-windows.sh (mingw prefix + x86_64-windows-gnu)"
  ( cd "$PROJECT_ROOT" && bash scripts/build-windows.sh ReleaseSafe ) >/tmp/winbuild.log 2>&1 || return 1
  WIN_EXE="$(find "$PROJECT_ROOT/zig-out" -name 'f69.exe' | head -1)"; [ -n "$WIN_EXE" ] && BUILT_WIN=1; }

# deliver+launch a Linux build on the guest; sets START to the remote f69 start command,
# BUNDLE to a label. echoes nothing; returns 1 on delivery failure.
deliver(){ local vm=$1 build=$2
  case "$build" in
    portable) build_portable || return 1
      gpush "$vm" "$TAR_PORTABLE" /tmp/f69-portable.tar >/dev/null 2>&1
      gssh "$vm" "rm -rf ~/f69test && mkdir ~/f69test && tar xf /tmp/f69-portable.tar -C ~/f69test" >/dev/null 2>&1
      RUNCMD='cd ~/f69test && exec ./run.sh';;
    slim) build_slim || return 1
      gpush "$vm" "$TAR_SLIM" /tmp/f69-slim.tar >/dev/null 2>&1
      gssh "$vm" "rm -rf ~/f69slim && mkdir ~/f69slim && tar xf /tmp/f69-slim.tar -C ~/f69slim" >/dev/null 2>&1
      RUNCMD='cd ~/f69slim && exec ./run.sh';;
    native)  RUNCMD='exec f69';;   # native install path
  esac; return 0; }

# start f69 on the live session, return render verdict via f69.log
launch_and_assert(){ local vm=$1
  # IMPORTANT: launch via `systemd-run --user`, NOT `nohup … &` over ssh. A backgrounded f69
  # (and the aria2c it spawns) keeps the ssh channel's fds open, so the ssh call hangs forever
  # even with setsid/</dev/null. systemd-run starts a detached transient unit and returns at once.
  cat > /tmp/_launch.sh <<EOF
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
systemctl --user stop f69run 2>/dev/null; systemctl --user reset-failed f69run 2>/dev/null
pkill -f 'f69test/f69|f69slim/f69|/usr/bin/f69' 2>/dev/null
pkill -f steam 2>/dev/null; pkill steamwebhelper 2>/dev/null   # bazzite autostarts Steam, whose modal steals focus/overlays f69
sleep 1
systemd-run --user --unit=f69run --setenv=XDG_RUNTIME_DIR=/run/user/1000 --setenv=WAYLAND_DISPLAY=wayland-0 \\
  bash -c '$RUNCMD >~/f69.log 2>&1'
EOF
  grun "$vm" /tmp/_launch.sh >/dev/null 2>&1
  sleep 11   # host-side wait for f69 to init (the ssh call already returned)
  # pull the FULL log (render marks appear early and scroll past any tail window)
  gssh "$vm" "cat ~/f69.log" > "$RESULTS_DIR/$vm-${BUILD}-f69.log" 2>/dev/null
  local rmark wmark alive
  rmark="$(grep -cF "$RENDER_MARK" "$RESULTS_DIR/$vm-${BUILD}-f69.log" 2>/dev/null || echo 0)"
  wmark="$(grep -cF "$WINDOW_MARK" "$RESULTS_DIR/$vm-${BUILD}-f69.log" 2>/dev/null || echo 0)"
  # fish-safe (no parens/subshells — cachyos default shell is fish); match the ld-linux-wrapped portable proc too
  alive="$(gssh "$vm" "pgrep -f 'f69test/f69|f69slim/f69|/usr/bin/f69' >/dev/null && echo Y || echo N" 2>/dev/null)"
  [ "${rmark:-0}" -ge 1 ] && [ "${wmark:-0}" -ge 1 ] && [ "$alive" = Y ] && return 0
  return 1; }

# functional sign-in click-through; asserts marker username in f69.log
clickthrough(){ local vm=$1 build=$2 base=$3
  local geo; geo="$(detect_button "$base")"
  [ -n "$geo" ] || { echo "no-button"; return 1; }
  read -r W H BX BY <<<"$geo"
  # derive field rows from the button (window 800px tall, natural scale 1)
  local uy=$((BY-152)) py=$((BY-56))
  local user pass assertstr
  if [ -n "${F95_USER:-}" ]; then user="$F95_USER"; pass="$F95_PASS"; assertstr="F95 login OK"
  else user="vmtest-$vm-$build"; pass="demo_pass"; assertstr="$user"; fi
  log "$vm/$build: click-through — login as $user, assert '$assertstr'"
  local DT; DT="$(gssh "$vm" "command -v dotool || echo /usr/local/bin/dotool" 2>/dev/null)"
  cat > /tmp/_click.sh <<EOF
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
echo "$PW" | sudo -S -v 2>/dev/null
{ sleep 0.6
  printf 'mouseto %s %s\nclick left\n' $(awk "BEGIN{print $BX/$W}") $(awk "BEGIN{print $uy/$H}")
  sleep 0.3
  printf 'click left\ntype $user\n'   # 1st click focuses the window (KWin may absorb it), 2nd focuses the username field
  sleep 0.3
  printf 'mouseto %s %s\nclick left\ntype $pass\n' $(awk "BEGIN{print $BX/$W}") $(awk "BEGIN{print $py/$H}")
  sleep 0.3
  printf 'mouseto %s %s\nclick left\n' $(awk "BEGIN{print $BX/$W}") $(awk "BEGIN{print $BY/$H}")
} | sudo "$DT" 2>/dev/null
sleep 5
EOF
  grun "$vm" /tmp/_click.sh >/dev/null 2>&1
  shot "$vm" "$RESULTS_DIR/$vm-$build-signin.png"
  # nav: click Downloads toolbar (derived, best-effort, not asserted)
  local ty=$((BY-442))
  cat > /tmp/_nav.sh <<EOF
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
echo "$PW" | sudo -S -v 2>/dev/null
{ sleep 0.4; printf 'mouseto %s %s\nclick left\n' $(awk "BEGIN{print 980/$W}") $(awk "BEGIN{print $ty/$H}"); } | sudo "$DT" 2>/dev/null
sleep 1
EOF
  grun "$vm" /tmp/_nav.sh >/dev/null 2>&1
  shot "$vm" "$RESULTS_DIR/$vm-$build-nav.png"
  # refresh the full log (the login round-trip appends after the render copy) and assert
  gssh "$vm" "cat ~/f69.log" > "$RESULTS_DIR/$vm-${build}-f69.log" 2>/dev/null
  grep -qF "$assertstr" "$RESULTS_DIR/$vm-${build}-f69.log" && echo ok && return 0
  echo "assert-miss:$assertstr"; return 1; }

# ---- per-cell orchestration ----
run_linux_cell(){ local vm=$1 build=$2; BUILD=$build
  # eligibility
  if [ "$build" = slim ]; then
    awk "BEGIN{exit !(${GLIBC[$vm]} < $SLIM_FLOOR)}" && { record "$vm" slim SKIP "glibc ${GLIBC[$vm]} < $SLIM_FLOOR floor" ""; return; }
  fi
  if [ "$build" = native ]; then
    case "$vm" in
      cachyos) ;;  # AUR handled below
      bazzite) [ $BAZZITE_NATIVE = 1 ] || { record "$vm" native SKIP "rpm-ostree layering (use --bazzite-native)" ""; return; };;
      pikaos)  record "$vm" native XFAIL "CI .deb targets bookworm; PikaOS=sid sonames differ (base-lock) — rebuild with F69_DEB_BASE=debian:sid" ""; return;;
      nobara)  record "$vm" native XFAIL "CI .rpm targets fedora:latest; Fedora 43 older glibc (base-lock) — rebuild with F69_RPM_BASE=fedora:43" ""; return;;
    esac
  fi
  log "$vm/$build: deliver"
  if ! deliver "$vm" "$build"; then record "$vm" "$build" FAIL "host build/delivery failed" ""; return; fi
  log "$vm/$build: launch + render assert"
  if ! launch_and_assert "$vm"; then
    local why; why="$(gssh "$vm" "grep -oE 'BackendError|No supported SDL_GPU|Bus error|GLIBC_[0-9.]+ not found' ~/f69.log | head -1" 2>/dev/null)"
    record "$vm" "$build" FAIL "render: ${why:-no pipeline/window in log}" "$vm-$build-f69.log";
    gssh "$vm" "systemctl --user stop f69run 2>/dev/null; pkill -f 'f69test/f69|f69slim/f69|/usr/bin/f69'" >/dev/null 2>&1; return
  fi
  shot "$vm" "$RESULTS_DIR/$vm-$build-render.png"
  if [ "$DEPTH" = smoke ]; then
    record "$vm" "$build" PASS "render OK (smoke)" "$vm-$build-render.png"
  else
    local r; r="$(clickthrough "$vm" "$build" "$RESULTS_DIR/$vm-$build-render.png")"
    if [ "$r" = ok ]; then
      record "$vm" "$build" PASS "render + sign-in click-through" "$vm-$build-render.png,$vm-$build-signin.png,$vm-$build-nav.png"
    else
      record "$vm" "$build" FAIL "render OK but click-through failed ($r)" "$vm-$build-render.png,$vm-$build-signin.png"
    fi
  fi
  gssh "$vm" "systemctl --user stop f69run 2>/dev/null; pkill -f 'f69test/f69|f69slim/f69|/usr/bin/f69'" >/dev/null 2>&1; }

# cachyos AUR native: build .pkg on host (podman), push, pacman -U, launch native
run_native_cachyos(){ BUILD=native
  if ! command -v podman >/dev/null && ! command -v docker >/dev/null; then
    record cachyos native SKIP "no podman/docker on host for -Dcontainer-build" ""; return; fi
  log "host: zig build aur -Dcontainer-build=true"
  ( cd "$PROJECT_ROOT" && zig build aur -Dcontainer-build=true ) >/tmp/aur.log 2>&1 || { record cachyos native XFAIL "host aur container build failed (see /tmp/aur.log)" ""; return; }
  local pkg; pkg="$(find "$PROJECT_ROOT/zig-out/aur" -name '*.pkg.tar.zst' | head -1)"
  [ -n "$pkg" ] || { record cachyos native XFAIL "no .pkg.tar.zst produced" ""; return; }
  gpush cachyos "$pkg" /tmp/f69.pkg.tar.zst >/dev/null 2>&1
  gssh cachyos "echo $PW | sudo -S pacman -U --noconfirm /tmp/f69.pkg.tar.zst" >/dev/null 2>&1
  RUNCMD='exec f69'
  if launch_and_assert cachyos; then
    shot cachyos "$RESULTS_DIR/cachyos-native-render.png"
    local r; r="$([ "$DEPTH" = smoke ] && echo skip || clickthrough cachyos native "$RESULTS_DIR/cachyos-native-render.png")"
    if [ "$DEPTH" = smoke ] || [ "$r" = ok ]; then record cachyos native PASS "AUR pkg installs + ${DEPTH}" "cachyos-native-render.png"
    else record cachyos native FAIL "render OK, click-through failed ($r)" "cachyos-native-render.png"; fi
  else record cachyos native FAIL "native render failed" "cachyos-native-f69.log"; fi
  gssh cachyos "systemctl --user stop f69run 2>/dev/null; pkill -f '/usr/bin/f69'" >/dev/null 2>&1; }

run_windows_cell(){ BUILD=windows
  local xc=0; build_windows && xc=1
  # verify the Win VM is genuinely RDP-ready (boot it first if it isn't already up)
  local hp; hp="$(win_hp)"; local rdp
  if bash "$VMDIR/rdp-ready.sh" ${hp:-localhost 3389} 0 >/dev/null 2>&1; then rdp="ready (already up)"
  else log "=== windows: boot + wait for RDP (X.224 handshake) ==="; boot windows
       if wait_rdp 240; then rdp="ready"; else rdp="NOT ready (240s timeout)"; fi; fi
  if [ $xc = 1 ]; then
    record windows windows PASS "cross-compiled $(basename "$WIN_EXE") ($(du -h "$WIN_EXE"|cut -f1)); VM RDP $rdp; install/launch manual" "$(basename "$WIN_EXE")"
  else
    record windows windows FAIL "cross-compile failed (see /tmp/winbuild.log); VM RDP $rdp" ""
  fi
  log "NOTE: f69.exe install/launch on Windows is manual (RDP :${hp##* } user ${USER[windows]:-w10}); no in-guest agent for type/click yet."; }

# ---- report ----
write_report(){ local f="$RESULTS_DIR/report.md"
  { echo "# f69 VM test report — $DATE"; echo
    echo "depth=$DEPTH · vms=${VMS[*]} · builds=${BUILDS[*]}"; echo
    echo "| VM | build | verdict | reason |"; echo "|----|-------|---------|--------|"
    for r in "${ROWS[@]}"; do IFS='|' read -r vm b v reason _ <<<"$r"
      echo "| $vm | $b | $v | $reason |"; done
    echo; echo "## Cells"; echo
    for r in "${ROWS[@]}"; do IFS='|' read -r vm b v reason shots <<<"$r"
      echo "### $vm / $b — $v"; echo "$reason"; echo
      IFS=, read -ra ss <<<"$shots"; for s in "${ss[@]}"; do [ -n "$s" ] && echo "- [\`$s\`](./$s)"; done; echo
    done
  } > "$f"
  log "report: $f"; }

# ---- main ----
log "results → $RESULTS_DIR  (vms=${VMS[*]} builds=${BUILDS[*]} depth=$DEPTH)"
for vm in "${VMS[@]}"; do
  if [ "$vm" = windows ]; then
    [[ " ${BUILDS[*]} " == *" windows "* ]] && run_windows_cell
    continue
  fi
  # which builds apply to this linux vm this run?
  cell_builds=(); for b in "${BUILDS[@]}"; do [ "$b" = windows ] && continue; cell_builds+=("$b"); done
  [ ${#cell_builds[@]} -gt 0 ] || continue
  log "=== $vm: boot ==="
  boot "$vm"
  if ! wait_up "$vm"; then record "$vm" - FAIL "VM did not come up" ""; killvm "$vm"; continue; fi
  if ! wait_session "$vm"; then record "$vm" - FAIL "no wayland session (autologin?)" ""; killvm "$vm"; continue; fi
  for b in "${cell_builds[@]}"; do
    if [ "$b" = native ] && [ "$vm" = cachyos ]; then run_native_cachyos; else run_linux_cell "$vm" "$b"; fi
  done
  [ $KEEP = 1 ] || { log "=== $vm: power off ==="; killvm "$vm"; sleep 2; }
done
write_report
# exit non-zero if any non-expected failure
fails=0; for r in "${ROWS[@]}"; do IFS='|' read -r _ _ v _ _ <<<"$r"; [ "$v" = FAIL ] && fails=$((fails+1)); done
log "done. FAIL cells: $fails (XFAIL/SKIP are expected)"
exit $(( fails > 0 ? 1 : 0 ))
