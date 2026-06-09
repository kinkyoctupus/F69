#!/usr/bin/env bash
# Tag-driven live GUI driver for f69 on a quickemu VM.
#
# f69 built with the F69_TAG_DUMP hook (ui.zig) writes every tagged widget's
# physical-pixel rect to a file each frame. This tool resolves a widget by TAG
# NAME to an exact screen coordinate and clicks it with dotool — no eyeballing a
# screenshot, no missed clicks on small toolbar targets.
#
# How the coordinate mapping works:
#   tag rects are in the dvui framebuffer's physical pixels. The framebuffer maps
#   to the on-screen window content by an affine transform (offset + scale) that
#   is constant for the session (the window doesn't move). We recover it ONCE by
#   matching two teal anchors — the active view-toggle (top-right) and the active
#   rail item (left) — to their dump rects, then apply it to any tag.
#
# Usage:
#   vmclick.sh <vm> launch                 # (re)launch f69 with the dump enabled
#   vmclick.sh <vm> calibrate              # solve+cache the framebuffer→screen map (run on the library screen)
#   vmclick.sh <vm> click <tag>            # click the widget with that tag
#   vmclick.sh <vm> shot <out.png>         # pull a fullscreen screenshot
#   vmclick.sh <vm> dump                   # print the current tag dump
set -uo pipefail
VMDIR="$HOME/VMs"; source "$VMDIR/vms.env"
VM="${1:?vm}"; CMD="${2:?cmd}"
DUMP_REMOTE='~/f69-tags.txt'
CALIB="/tmp/f69-calib-$VM"
G(){ nix shell nixpkgs#sshpass nixpkgs#openssh -c bash "$VMDIR/g.sh" "$@"; }
PY(){ nix-shell -p 'python3.withPackages(ps: [ps.pillow])' --run "python3 $*" 2>/dev/null; }

run_remote(){ local f="$1"; G run "$VM" "$f"; }

launch(){
  cat > /tmp/_vmlaunch.sh <<'EOF'
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
systemctl --user stop f69run 2>/dev/null; systemctl --user reset-failed f69run 2>/dev/null
pkill -9 -f 'f69test/f69' 2>/dev/null; sleep 2
systemd-run --user --unit=f69run --setenv=XDG_RUNTIME_DIR=/run/user/1000 --setenv=WAYLAND_DISPLAY=wayland-0 \
  --setenv=F69_TAG_DUMP=/home/USER/f69-tags.txt \
  bash -c 'cd ~/f69test && exec ./run.sh >~/f69.log 2>&1'
sleep 12; echo "render: $(grep -c "Graphics pipeline created successfully" ~/f69.log)"
EOF
  sed -i "s/USER/$(G ssh "$VM" 'whoami' | tr -d '\r')/" /tmp/_vmlaunch.sh
  run_remote /tmp/_vmlaunch.sh
}

shot(){ local out="${1:-/tmp/f69-$VM.png}"
  cat > /tmp/_vmshot.sh <<'EOF'
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
spectacle -b -f -n -o ~/_shot.png 2>/dev/null
EOF
  run_remote /tmp/_vmshot.sh >/dev/null 2>&1
  G ssh "$VM" "base64 ~/_shot.png" 2>/dev/null | base64 -d > "$out"
  [ -s "$out" ] && echo "$out"
}

get_dump(){ G ssh "$VM" "cat $DUMP_REMOTE" 2>/dev/null; }

calibrate(){
  local shotf="/tmp/_calib-$VM.png"; shot "$shotf" >/dev/null
  get_dump > "/tmp/_dump-$VM.txt"
  PY "- <<PY
from PIL import Image
im=Image.open('$shotf').convert('RGB'); W,H=im.size; px=im.load()
# framebuffer size from the __window dump line
fbW=fbH=0
for ln in open('/tmp/_dump-$VM.txt'):
    p=ln.rstrip('\n').split('\t')
    if len(p)>=5 and p[0]=='__window': fbW=float(p[3]); fbH=float(p[4])
import sys
if fbW==0:
    print('CALIB-FAIL no __window line in dump'); sys.exit(1)
# Detect the f69 window: a large DARK rectangle on the bright wallpaper, that is
# NOT full-width (excludes the full-width KDE panels top/bottom). For each row in
# the middle band, find the longest dark run; keep rows whose run is 35-97% of W.
def dark(r,g,b): return r<55 and g<55 and b<60
rows=[]
for y in range(int(H*0.03), int(H*0.95)):
    x=int(W*0.0); best=(0,0,0); cur=None
    for x in range(0,W,2):
        if dark(*px[x,y]):
            if cur is None: cur=x
        else:
            if cur is not None:
                if x-cur>best[0]: best=(x-cur,cur,x)
                cur=None
    if cur is not None and W-cur>best[0]: best=(W-cur,cur,W)
    rl=best[0]/W
    if 0.35<rl<0.97: rows.append((y,best[1],best[2]))
if len(rows)<20:
    print('CALIB-FAIL window not found (%d dark rows)'%len(rows)); sys.exit(1)
L=min(r[1] for r in rows); R=max(r[2] for r in rows); B=max(r[0] for r in rows)
s=(R-L)/fbW                       # screen px per framebuffer px
T=B - s*fbH                       # content top (from bottom edge → skips titlebar)
print('CALIB %g %g %g %g %d %d'%(L, s, T, s, W, H))   # off_x scale_x off_y scale_y W H
PY" > "$CALIB.raw"
  if grep -q CALIB-FAIL "$CALIB.raw" 2>/dev/null; then
    echo "calibrate FAILED: $(grep CALIB-FAIL "$CALIB.raw")"; return 1; fi
  # extract just the numeric result (strip the nix-shell dev-shell banner)
  grep -E '^CALIB ' "$CALIB.raw" | tail -1 | sed 's/^CALIB //' > "$CALIB"
  [ -s "$CALIB" ] || { echo "calibrate FAILED (no result line)"; cat "$CALIB.raw"; return 1; }
  echo "calibrated $VM: $(cat "$CALIB")  (off_x scale_x off_y scale_y W H)"
}

click(){ local tag="${1:?tag}"
  [ -s "$CALIB" ] || { echo "not calibrated — run: $0 $VM calibrate"; return 1; }
  read -r OFFX SX OFFY SY W H < "$CALIB"
  get_dump > "/tmp/_dump-$VM.txt"
  local line; line="$(grep -P "^$tag\t" "/tmp/_dump-$VM.txt" | head -1)"
  [ -n "$line" ] || { echo "tag '$tag' not in current dump (screen mismatch?). present:"; cut -f1 "/tmp/_dump-$VM.txt" | sort | tr '\n' ' '; echo; return 1; }
  read -r _ X Y WW HH VIS <<<"$(echo "$line" | tr '\t' ' ')"
  local fx fy
  fx="$(awk "BEGIN{print ($OFFX + $SX*($X+$WW/2))/$W}")"
  fy="$(awk "BEGIN{print ($OFFY + $SY*($Y+$HH/2))/$H}")"
  echo "click '$tag' fb($X,$Y,$WW,$HH) -> frac($fx,$fy)"
  cat > /tmp/_vmclick.sh <<EOF
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
DT="\$(command -v dotool || echo /usr/local/bin/dotool)"
echo "\$VM_PW" | sudo -S -v 2>/dev/null
{ sleep 0.5; printf 'mouseto %s %s\nclick left\n' $fx $fy; } | sudo "\$DT" 2>/dev/null
sleep 1.2
EOF
  run_remote /tmp/_vmclick.sh >/dev/null 2>&1
}

case "$CMD" in
  launch) launch;;
  calibrate) calibrate;;
  click) click "${3:?tag}";;
  shot) shot "${3:-/tmp/f69-$VM.png}";;
  dump) get_dump;;
  *) echo "usage: $0 <vm> {launch|calibrate|click <tag>|shot <out>|dump}"; exit 2;;
esac
