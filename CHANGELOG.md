# Changelog

All notable changes to CMP. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- **Headphones out, music paused:** pulling the headphones out pauses the player (also the background player on dual-screen devices) instead of carrying on from the speaker.
- **Jump by letter** in a long library: ↑↓ in Cover Flow, ←→ in the album list. The letter shows big for a moment. Holding a direction also speeds up after a second.
- **Track names from the tags** on the album page, in the queue and in the touch library. Until an album's tags are read (once, in the background, then kept) the file names show.

### Changed

- **The library opens at once.** It is kept between starts; folders changed since are noticed in the background and only then read again. Reading the library is also faster.

## [0.2.0] - 2026-10-12

### Added

- **Screen off while music plays.** Y or the power button turns the screen off and locks the buttons; the power button or holding Y for a second turns it back on. On a clamshell handheld such as the Anbernic RG SP, closing the lid does the same instead of putting the device to sleep, and opening it brings the screen back. When the music stops with the screen off (the sleep timer, the end of the queue), the handheld goes to sleep as before. Paused, the power button and the lid work as they always did.
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

- ROCKNIX with its mpv 0.41 (no other dependencies). Tested on the Anbernic RG SP (single screen, 720x480) and the Anbernic RG DS Plus (two screens, 1024x768).

[0.2.0]: https://github.com/cobanov/cmp/releases/tag/v0.2.0
[0.1.0]: https://github.com/cobanov/cmp/releases/tag/v0.1.0
