#!/bin/bash
# Video player for EmulationStation's Media Player, as its "cmp_video" core
# (runemu.sh starts start_cmp_video.sh with the file): mpv with the handheld
# scripts (role player), the pad and the touch remote from media-hub.py in
# place of ROCKNIX's mpv_sense.

. /etc/profile
set_kill set "mpv"

# the files sit next to this script (/usr/share/cmp in the package)
BASE="$(dirname "$(readlink -f "$0")")"
HUB="${BASE}/media-hub.py"
SOCK=/tmp/mpvsocket

# ROCKNIX's video input service must not run beside this one
systemctl stop mpv 2>/dev/null

# one player at a time; a background player saves its queue first (the note
# tells it a player follows, so it leaves the second screen on)
touch /run/handheld-follows
systemctl stop handheld-bottom 2>/dev/null
rm -f /run/handheld-follows
systemctl stop handheld-video 2>/dev/null
systemctl reset-failed handheld-video 2>/dev/null
systemd-run --quiet --collect --unit=handheld-video "${HUB}" player "${SOCK}"

# the window opens on the screen with the focus: on a dual-screen device that
# must be the main one (ROCKNIX lists it first), even after a touch below
MAIN_SCREEN="${SDL_VIDEO_DISPLAY_PRIORITY%%,*}"
[ -n "${MAIN_SCREEN}" ] && swaymsg "focus output ${MAIN_SCREEN}" >/dev/null 2>&1

# vo=wlshm: the menus and the remote are drawn by the scripts, in software,
# which works on every ROCKNIX device (the RK3566's Vulkan output shows no
# picture). Played files remember where they stopped, with their tracks.
# --load-scripts=no keeps the user's own mpv scripts out of the way.
/usr/bin/mpv --fullscreen --vo=wlshm --no-osc --cursor-autohide=always --sws-fast=yes --sws-scaler=fast-bilinear \
  --sub-ass-override=strip --save-position-on-quit=yes \
  --watch-later-dir=/storage/.config/mpv/watch_later --watch-later-options=start,sid,aid,sub-delay \
  --input-ipc-server="${SOCK}" --load-scripts=no --script="${BASE}/scripts/handheld" \
  --input-conf="${BASE}/input.conf" --script-opts=handheld-role=player,handheld-hub="${HUB}" "${1}"
systemctl stop handheld-video
exit 0
