#!/bin/bash
# Music player for EmulationStation's "Music Player" system: mpv with the
# handheld scripts (role music), the pad and touch remote from media-hub.py,
# which runs in its own unit so the video player's mpv.service is left alone.

. /etc/profile
set_kill set "mpv"

# a package keeps the files next to this script (/usr/share/cmp), a
# music-only install in its own folder, a full one in mpv's
BASE="$(dirname "$(readlink -f "$0")")"
[ -f "${BASE}/media-hub.py" ] || BASE=/storage/.config/cmp
[ -f "${BASE}/media-hub.py" ] || BASE=/storage/.config/mpv
HUB="${BASE}/media-hub.py"
SOCK=/tmp/mpv-music
# a music-only install names its scripts and input.conf; --load-scripts=no
# keeps a full install's copy in mpv's own folder from loading twice
EXTRA=""
[ "${BASE}" = /storage/.config/mpv ] ||
  EXTRA="--load-scripts=no --script=${BASE}/scripts/handheld --input-conf=${BASE}/input.conf"

# ROCKNIX's video input service must not run beside the music player (its
# hub would read the pad and open a second touch remote too)
systemctl stop mpv 2>/dev/null

# one player at a time; this also lets a background player save its queue first
# (the note tells it a player follows, so it leaves the second screen on)
touch /run/handheld-follows
systemctl stop handheld-bottom 2>/dev/null
rm -f /run/handheld-follows
systemctl stop handheld-music 2>/dev/null
systemctl reset-failed handheld-music 2>/dev/null
systemd-run --quiet --collect --unit=handheld-music "${HUB}" player "${SOCK}"

# the window opens on the screen with the focus: on a dual-screen device that
# must be the main one (ROCKNIX lists it first), even after a touch below
MAIN_SCREEN="${SDL_VIDEO_DISPLAY_PRIORITY%%,*}"
[ -n "${MAIN_SCREEN}" ] && swaymsg "focus output ${MAIN_SCREEN}" >/dev/null 2>&1

# vo=wlshm: everything on screen is drawn by the scripts, in software, which
# works on every ROCKNIX device (the RK3566's Vulkan output shows no picture)
/usr/bin/mpv --fullscreen --idle=yes --force-window=yes --title="Music" --no-osc --vo=wlshm --cursor-autohide=always \
  --audio-display=no --save-position-on-quit=no --resume-playback=no \
  --input-ipc-server="${SOCK}" ${EXTRA} \
  --script-opts=handheld-role=music,handheld-hub="${HUB}" --script-opts-append=handheld-launcher="$0"
systemctl stop handheld-music
# the screen comes back even if the hub could not switch it on again itself
if [ -f /run/cmp-screen-off ]; then
  for b in $(cat /run/cmp-screen-off); do echo 0 > "/sys/class/backlight/${b}/bl_power"; done
  rm -f /run/cmp-screen-off
fi
exit 0
