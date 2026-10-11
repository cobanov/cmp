# Changelog

All notable changes to CMP. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org).

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

[0.1.0]: https://github.com/cobanov/cmp/releases/tag/v0.1.0
