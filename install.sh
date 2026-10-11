#!/bin/sh
# Copy the media player files to a ROCKNIX handheld:
#   ./install.sh root@<device>           video and music players
#   ./install.sh --music root@<device>   the music player only; the video player stays ROCKNIX's
set -eu
if [ "${1:-}" = "--music" ]; then
  host=${2:?usage: install.sh --music root@<device>}
  cd "$(dirname "$0")"
  base=/storage/.config/cmp
  ssh "$host" "mkdir -p $base/scripts /storage/.config/mpv /storage/.config/gmu/playlists /storage/roms/music /storage/.config/autostart
    rm -rf $base/scripts/handheld"
  scp -O -q hub/media-hub.py system/second-screen-idle "$host":$base/
  scp -O -q -r mpv/scripts/handheld "$host":$base/scripts/
  scp -O -q es/Music.sh "$host":/storage/.config/gmu/playlists/Music.sh
  # dual-screen devices: keep the background player lit across sway reloads
  sed "s#/storage/.config/mpv/second-screen-idle#$base/second-screen-idle#" system/handheld-sway-fix |
    ssh "$host" "cat > /storage/.config/autostart/handheld-sway-fix"
  ssh "$host" "chmod +x $base/media-hub.py $base/second-screen-idle /storage/.config/gmu/playlists/Music.sh \
    /storage/.config/autostart/handheld-sway-fix; /storage/.config/autostart/handheld-sway-fix"
  echo "music player installed on $host (GMU's launcher left in place)"
  exit 0
fi
host=${1:?usage: install.sh root@<device>}
cd "$(dirname "$0")"
ssh "$host" 'mkdir -p /storage/.config/mpv/scripts /storage/.config/system.d/mpv.service.d'
scp -O -q hub/media-hub.py "$host":/storage/.config/mpv/media-hub.py
scp -O -q mpv/mpv.conf mpv/input.conf "$host":/storage/.config/mpv/
scp -O -q system.d/mpv.service.d/override.conf "$host":/storage/.config/system.d/mpv.service.d/override.conf
ssh "$host" 'rm -rf /storage/.config/mpv/scripts/handheld /storage/.config/mpv/scripts/handheld-menu.lua'
scp -O -q -r mpv/scripts/handheld "$host":/storage/.config/mpv/scripts/
# Second screen: keep a player shown there lit across EmulationStation's sway reloads
scp -O -q system/second-screen-idle "$host":/storage/.config/mpv/second-screen-idle
scp -O -q system/handheld-sway-fix "$host":/storage/.config/autostart/handheld-sway-fix
ssh "$host" 'chmod +x /storage/.config/mpv/second-screen-idle /storage/.config/autostart/handheld-sway-fix
  /storage/.config/autostart/handheld-sway-fix'

# Music: our player replaces GMU in the "Music Player" system
ssh "$host" 'mkdir -p /storage/.config/gmu/playlists /storage/roms/music
  g="/storage/.config/gmu/playlists/Start Music Player.sh"
  [ -f "$g" ] && mv "$g" /storage/.config/gmu/gmu-launcher.sh.disabled || true'
scp -O -q es/Music.sh "$host":/storage/.config/gmu/playlists/Music.sh
# EmulationStation plays /storage/roms/music as menu music, and the library lives
# there now; turn that off (ES rewrites its settings, so only while it is stopped)
ssh "$host" 'c=/storage/.config/emulationstation/es_settings.cfg
  if [ -f "$c" ] && ! grep -q "name=\"audio.bgmusic\" value=\"false\"" "$c"; then
    systemctl stop essway
    sed -i "/name=\"audio.bgmusic\"/d; s|</config>|\t<bool name=\"audio.bgmusic\" value=\"false\" />\n</config>|" "$c"
    systemctl start essway
  fi'
ssh "$host" 'chmod +x /storage/.config/mpv/media-hub.py /storage/.config/gmu/playlists/Music.sh
  rm -f /storage/.config/mpv/handheld-input.py; systemctl daemon-reload'

echo "installed on $host"
