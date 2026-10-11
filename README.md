<div align="center">

<h1>CMP</h1>

**Console Music Player: a music player for retro handhelds that you actually want to use.**<br>
Cover Flow, your albums and covers, resume where you stopped, and music that keeps playing under a game.

**[Download](https://github.com/cobanov/cmp/releases/latest)** · [Install](#try-it) · [Controls](#controls) · [Changes](CHANGELOG.md) · [Issues](https://github.com/cobanov/cmp/issues)

</div>

CMP replaces the music players that ship with handheld firmwares, which were never made for a small screen and a pad. It runs on [ROCKNIX](https://rocknix.org) today and is built on the mpv that ROCKNIX already includes, with Lua scripts and one small Python helper. There is nothing to compile. It fits any screen size, from 640x480 to the 1024x768 screens of the Anbernic RG DS Plus, and uses the second screen of dual-screen devices.

<div align="center">
  <img src="docs/cmp-cover-flow.png" width="45%" alt="Cover Flow">
  <img src="docs/cmp-now-playing.png" width="45%" alt="Now playing">
  <br><sub>Cover Flow and the player on an Anbernic RG SP (720x480).</sub>
  <br><br>
  <img src="docs/cmp-album.png" width="45%" alt="An album">
  <img src="docs/cmp-settings.png" width="45%" alt="Settings">
  <br><sub>An album and the settings: big type, made for a pad.</sub>
  <br><br>
  <img src="docs/cmp-touch-library.png" width="45%" alt="The library on the touch screen">
  <img src="docs/music-background.png" width="45%" alt="Music on the second screen under a game">
  <br><sub>On a dual-screen device the music keeps playing on the second screen during a game, with its own touch library.</sub>
</div>

## Made for the device in your hands

- **Your library as it is.** Any folder with music is an album, at any depth: `Artist - Album`, `Artist/Album`, `Artist/Album/CD1`. Folders without a clear name are named from their tags, loose tracks become "Singles". Track names come from the tags. The library is kept between starts, so even a big one opens at once.
- **Covers without a computer.** Pictures come from `cover.jpg`, `folder.jpg` or the picture inside the track, are made on the device the first time and kept in a cache.
- **Search and a real queue.** Type with the pad to find any album or song. Play it next, add it to the queue, move or remove songs in the queue.
- **Cover Flow, a list, and a real player.** Browse with Cover Flow or a list, open an album, and the player shows the cover, the controls, the progress and what comes next.
- **One meaning per button.** A chooses, B goes back, X jumps to the player, L1 R1 change the track, L2 R2 seek. The hints at the bottom always show the buttons in the same order.
- **Picks up where you left it.** The queue, the track and the position are saved when you quit.
- **In your pocket, lid shut.** While music plays, closing the lid, the power button or Screen off in the options turns the screen off and locks the buttons instead of putting the handheld to sleep. Open the lid, press power or hold Y to come back. When the music stops with the screen off, the handheld sleeps as usual. Pulling the headphones out pauses the music.
- **Sleep timer, clock and battery.** Stop the music after 15 to 90 minutes or at the end of the track, with a gentle fade. The clock and the battery (the same estimate EmulationStation shows) sit at the top of every page.
- **Music under your games.** On dual-screen devices, L1 + R1 (or "Play in background") moves the queue to the second screen, where it keeps playing with touch controls while you play on the main one.

## Controls

| Button | What it does |
|---|---|
| A | Choose: open the album, play a track, press the focused control |
| B | Back |
| X | Now playing |
| Y | Options: play next, add to queue, search, screen off (hold Y to unlock a locked screen) |
| ↑ ↓ | Move; in Cover Flow, jump by letter; in the player, between the controls, the progress bar and the queue |
| ← → | Browse (hold to go faster); in the album list, jump by letter; in the player, walk the controls or seek |
| L1 R1 | Previous / next track |
| L1 + R1 | Play in the background (two screens) |
| L2 R2 | Back / forward 10 s |
| Select | Settings |
| Start | Quit, the queue is saved |
| Power, lid | While music plays: screen off and on |

## Try it

1. Put your music under `/storage/roms/music`, in any folder layout.
2. Download `cmp-<version>.tar.gz` from the [latest release](https://github.com/cobanov/cmp/releases/latest) and unpack it.
3. From a computer on the same network: `./install.sh --music root@<handheld-ip>` (SSH can be turned on in ROCKNIX's network settings; the root password is `rocknix` unless you changed it).
4. In EmulationStation, open the Music Player system and start "Music".

The install goes to `/storage/.config/cmp` and leaves the stock music player in place; delete the folder and `Music.sh` to go back.

## Want to tinker?

Lua scripts for mpv 0.41 with LuaJIT (`mpv/scripts/handheld`) and a Python 3 standard-library hub (`hub/media-hub.py`) that reads the pad, runs the second-screen windows and talks to sway. Covers and Cover Flow are drawn in LuaJIT FFI buffers; text is measured and drawn with libass. `tools/preview.sh` renders screens offscreen on a device. Releases follow [semantic versioning](https://semver.org); every change is listed in [CHANGELOG.md](CHANGELOG.md) and `tools/release.sh` cuts a release.

This repository also holds an experimental video player for dual-screen devices (`./install.sh root@<handheld-ip>`), which will get its own polish later.

---

GPL-2.0-or-later, like ROCKNIX. Not affiliated with the ROCKNIX project.
