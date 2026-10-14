# Changelog

All notable changes to CMP. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org).

## [0.5.0] - 2026-10-14

### Added

- **The video player for a distribution's package:** `es/Video.sh` starts it the way EmulationStation starts a media player core (`start_cmp_video.sh <file>` in ROCKNIX), with the files next to it, in place of ROCKNIX's own input service. The install script's video player in mpv's folder works as before.

### Changed

- **Video (experimental):** the touch remote's top row has only the clock, the battery and the buttons; the episode gets its own lines below it, the show and the number small, the episode's name big, so the name is no longer cut short.

### Fixed

- **The touch screen stayed dark now and then when a video or the music opened:** something else can turn the second screen off just after the hub turned it on (a helper that powers it off while only the player's window is open, before the remote's window comes). The hub looks again a moment later and turns it back on.

## [0.4.0] - 2026-10-14

### Added

- **Two screens, two jobs.** On a dual-screen device the main screen's player is now a showcase: the cover or the lyrics, big, with the song, the album and the artist beside them. The touch screen is the remote: the controls, a progress bar to drag, and the queue, where a tap plays a song and a finger scrolls the list. On the main screen ↑↓ pick a song in that queue (the touch screen lights up to show the pick), A plays it, ←→ seek. One-screen devices keep the player as it was.
- **X switches between the lyrics and the cover** in Now playing, on any device. The hint shows next to the song when it has lyrics.
- **The clock and the battery on the touch remote**, in its top row.
- **Volume and brightness on the touch remote.** The speaker and the sun at the top open a slider in place of the queue: the volume, and the brightness of each screen, apart or together with Sync. They set ROCKNIX's own volume and brightness, so the hardware keys and EmulationStation agree with them.
- **Waking the touch screen:** a tap wakes it, or a double tap (Settings: Wake the touch screen with), which also turns it off again, so a hand resting on the dark screen does not light it. In the music player any button wakes it too (Y aside, which turns the screens off). Touch screen turns off after: 5, 10 or 20 s.
- **Video player (experimental):** the same remote, and new buttons. L2 R2 jump between the chapters (the opening, the parts, the ending; a minute in a file without chapters), the left stick seeks 30 s and 5 minutes, L3 sets the speed, R3 shows or hides the subtitles.

### Changed

- **Keep touch screen on is off by default** in the music player, as in the video player: the touch screen turns off after a few seconds and a tap brings it back, which saves the battery.
- **Packaged installs:** the launcher finds the player's files next to itself (a distribution can ship them in `/usr/share/cmp` and link the launcher anywhere), and "Open player" on the second screen starts the EmulationStation entry the player was opened from, whatever it is called.
- The touch remote's microphone now switches the main screen between the lyrics and the cover. The lyrics page on the touch screen stays for the background player.

### Fixed

- **Pads made of several devices:** the hub reads every pad device it finds, not only the first, and picks up one that comes up later. Without InputPlumber the RG DS Plus has its buttons and its sticks on two devices, and the buttons did nothing.
- **L2 R2 did nothing with InputPlumber** (ROCKNIX next): its virtual pad sends the triggers only as analog axes, which the hub now reads.
- **The touch screen stayed dark** after something else turned it off (an EmulationStation reload): the hub asks sway whether it is on rather than trusting its own note.
- A touch that reached the main screen opened mpv's own controls there for a moment, and a double tap switched it out of fullscreen: the main screen's player now ignores the mouse.

## [0.3.0] - 2026-10-12

### Added

- **Options on Y:** every page has an options panel: play an album or song next, add it to the queue, shuffle an album, search, and turn the screen off. In the player's queue: play next, move up or down, remove, clear the queue.
- **Search** the library from the pad: a keyboard at the left, albums and songs that match at the right, updated with every letter. Case, accents and Turkish letters do not matter ("kotu" finds "Kötü").
- **Lyrics:** from an `.lrc` file next to the track (same name) or from its tags. Timed lyrics follow the song in place of the cover, the line being sung in the middle; plain ones move along with it. The microphone next to Repeat turns them on and off (lit while they show, dim when the song has none).
- **Internet radio:** the first album of the library ("album 0", before your albums; the player still opens on the album you left). The stations come from `radio.m3u` in the music folder, made with six long-lived stations the first time and editable over the network share. The player shows the station, the song it announces and LIVE.
- **Audiobooks:** a Speed setting (0.75× to 2×, the pitch stays), tracks of 20 minutes or more start where they were left, and bookmarks (Y > Add bookmark, Y > Bookmarks).
- **ReplayGain** (Settings: Off, Track, Album): tracks at one loudness from their tags, R128 in Opus included.
- **Equalizer:** 10 bands with presets (Bass boost, Treble boost, Vocal, Rock, Pop, Jazz, Classical, Dance) and a curve of your own, edited live with the pad (Settings > Edit equalizer) without the music skipping.
- **Audio details** under the progress bar: format, sample rate, channels and bitrate.
- **Crossfade** (Settings: 2 to 10 seconds): the end of a track and the start of the next play together, one fading out as the other fades in, with no gap and nothing heard twice. Seeking into the fade or skipping plays the next track from its start.
- **A long title scrolls** in the player, once when the track starts, then rests with its "…" (scrolling redraws the whole screen in software, so it is kept short for the battery).
- **Headphones out, music paused:** pulling the headphones out pauses the player (also the background player on dual-screen devices) instead of carrying on from the speaker.
- **Jump by letter** in a long library: ↑↓ in Cover Flow, ←→ in the album list. The letter shows big for a moment. Holding a direction also speeds up after a second.
- **Track names from the tags** on the album page, in the queue and in the touch library. Until an album's tags are read (once, in the background, then kept) the file names show.
- **Dual screen:** the touch screen gets the microphone too, and shows the lyrics on its own page; a station shows LIVE there; the background player's library starts with the radio.

### Changed

- **Select + Start quits** (as in RetroArch), so a stray Start no longer ends the music; **Start alone plays and pauses** from any page. Select still opens the settings, when it is let go.
- **Y opens the options** instead of turning the screen off; Screen off is in the options, and the power button and the lid still turn the screen off directly.
- The touch settings leave out what only concerns the pad (album view, rescan, button guide), so the list fits.
- **The library opens at once.** It is kept between starts; folders changed since are noticed in the background and only then read again. Reading the library is also faster.

### Fixed

- On a dual-screen device, ROCKNIX's video input service could run beside the music player, so two hubs read the pad and two touch remotes opened, and the device seemed frozen.
- On a dual-screen device, a touch on the second screen just before starting the player made it open there, with both windows side by side.

## [0.2.0] - 2026-10-12

### Added

- **Screen off while music plays.** Y or the power button turns the screen off and locks the buttons; the power button or holding Y for a second turns it back on. On a clamshell handheld such as the Anbernic RG34XX SP, closing the lid does the same instead of putting the device to sleep, and opening it brings the screen back. When the music stops with the screen off (the sleep timer, the end of the queue), the handheld goes to sleep as before. Paused, the power button and the lid work as they always did.
- **Sleep timer** in Settings: 15, 30, 45, 60 or 90 minutes, or the end of the track. The music fades out over 10 seconds. While it runs, a moon and the minutes left show at the top.
- **Clock and battery** at the top right of every page. The level is ROCKNIX's batteryplus estimate, the same EmulationStation shows, with the fuel gauge as a fallback; green while charging, red when low.

### Changed

- A page's title and its detail (the artist, the track count) now sit together at the left, leaving the right for the status.
- Long settings lists get slimmer rows instead of running off the screen.

## [0.1.0] - 2026-10-12

The first release of CMP, the Console Music Player, for ROCKNIX.

### Added

- **Library:** any folder with music is an album, at any depth (`Artist - Album`, `Artist/Album`, `Artist/Album/CD1`); folders without a clear name are named from their tags; loose tracks make a "Singles" album. Tracks sort naturally (2 before 10).
- **Covers made on the device:** from `cover.jpg`, `folder.jpg`, `front.jpg` or the picture inside the first track, at the sizes each screen needs, kept in `/storage/.cache/cmp` and made again when the folder changes.
- **Browsing:** Cover Flow (the default) or a list, then the album page.
- **Player:** cover, title, artist, previous / play / next, shuffle, repeat, a progress bar you can seek on, and the queue around the current track, all reachable with the d-pad.
- **Any screen:** the layout follows the screen's shape and size, from 640x480 to 1024x768 and wider; text is measured to fit.
- **Buttons:** one meaning each (A choose, B back, X player, L1 R1 track, L2 R2 seek, Select settings, Start quit), taken from EmulationStation's mapping for the device, so A/B/X/Y match their labels. Key hints at the bottom always in the same order.
- **Sessions:** the queue, the track, the position and the shuffle order survive quitting; Shuffle off restores the album order, also after a restart.
- **Dual-screen devices:** a touch player on the second screen; L1 + R1 or "Play in background" moves the queue there to keep playing under a game, with a touch library to pick albums and tracks.
- **Settings and About:** one short settings list, a button guide, and an About page with a QR code to this repository.
- `install.sh --music` installs the music player alone, next to the stock one.

### Requirements

- ROCKNIX with its mpv 0.41 (no other dependencies). Tested on the Anbernic RG34XX SP (single screen, 720x480) and the Anbernic RG DS Plus (two screens, 1024x768).

[0.5.0]: https://github.com/cobanov/cmp/releases/tag/v0.5.0
[0.4.0]: https://github.com/cobanov/cmp/releases/tag/v0.4.0
[0.3.0]: https://github.com/cobanov/cmp/releases/tag/v0.3.0
[0.2.0]: https://github.com/cobanov/cmp/releases/tag/v0.2.0
[0.1.0]: https://github.com/cobanov/cmp/releases/tag/v0.1.0
