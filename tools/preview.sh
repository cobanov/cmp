#!/bin/sh
# Render the touch screen without using the device's display:
#   tools/preview.sh root@<device> tools/state-music.lua controls|settings|intro [tap-x] > out.png
# Runs touch.lua with a stub mp module under luajit on the device, then draws
# the ASS with the device's libass (same fonts as mpv) plus the cover pictures.
set -eu
host=$1 state=$2 view=${3:-controls} tapx=${4:-850}
cd "$(dirname "$0")/.."
ssh "$host" 'rm -rf /tmp/uipv && mkdir -p /tmp/uipv/handheld'
scp -O -q mpv/scripts/handheld/*.lua "$host":/tmp/uipv/handheld/
scp -O -q tools/uipreview.lua tools/uipreview.py "$state" "$host":/tmp/uipv/
ssh "$host" "cd /tmp/uipv && sed -i 's|/tmp/hh-test/handheld|/tmp/uipv/handheld|' uipreview.lua &&
  luajit uipreview.lua /tmp/uipv/$(basename "$state") $view /tmp/uipv/out $tapx >/dev/null &&
  python3 uipreview.py /tmp/uipv/out 2>/dev/null && cat /tmp/uipv/out.png"
