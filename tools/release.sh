#!/bin/sh
# Cut a release:  tools/release.sh 0.2.0
# Before running: the version is set in mpv/scripts/handheld/settings.lua
# (S.ABOUT.version, shown on the About page), CHANGELOG.md has a
# "## [0.2.0] - date" section, everything is committed on main, and gh is
# logged in. Tags v0.2.0, pushes, and publishes a GitHub release with the
# CHANGELOG section as notes and cmp-0.2.0.tar.gz (what install.sh needs).
set -eu
v=${1:?usage: tools/release.sh VERSION}
cd "$(dirname "$0")/.."
fail() { echo "release: $*" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || fail "commit your changes first"
[ "$(git branch --show-current)" = main ] || fail "release from main"
grep -q "^    version = \"$v\"," mpv/scripts/handheld/settings.lua || fail "set version = \"$v\" in settings.lua"
grep -q "^## \[$v\]" CHANGELOG.md || fail "CHANGELOG.md has no [$v] section"
! git rev-parse -q --verify "refs/tags/v$v" >/dev/null || fail "v$v exists already"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
git tag -a "v$v" -m "CMP $v"
git archive --format=tar.gz --prefix="cmp-$v/" -o "$out/cmp-$v.tar.gz" "v$v" \
  es hub mpv system system.d install.sh LICENSE README.md CHANGELOG.md
# the notes: this version's CHANGELOG section, up to the next one or the links
awk -v v="$v" 'index($0, "## [" v "]") == 1 { on = 1; next } on && (/^## \[/ || /^\[/) { exit } on' \
  CHANGELOG.md > "$out/notes.md"
git push -q origin main "v$v"
gh release create "v$v" "$out/cmp-$v.tar.gz" --title "CMP $v" --notes-file "$out/notes.md"
