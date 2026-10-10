#!/usr/bin/env bash
# Refreshes packages/palette from a palette-native commit.
#
#   scripts/dev/vendor-palette-native.sh <palette-native repo> [<commit>]
#
# Copies the committed tree (never the working tree) of:
#   palette-native/src/**                 -> packages/palette/src/
#   palette-native/tools/wayland-scanner.zig -> packages/palette/tools/
#   protocols/*.xml, protocols/README.md  -> packages/palette/protocols/
# and records the commit in packages/palette/VENDORED_FROM. Verde-owned files
# (build.zig, build.zig.zon, AGENTS.md, README.md) are left alone.
set -euo pipefail

repo="${1:?usage: $0 <palette-native repo> [<commit>]}"
commit="${2:-master}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dest="$root/packages/palette"

sha="$(git -C "$repo" rev-parse --verify "$commit^{commit}")"
subject="$(git -C "$repo" log -1 --format=%s "$sha")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$repo" archive "$sha" palette-native/src palette-native/tools/wayland-scanner.zig protocols | tar -x -C "$tmp"

rm -rf "$dest/src" "$dest/tools" "$dest/protocols"
mkdir -p "$dest/tools" "$dest/protocols"
cp -R "$tmp/palette-native/src" "$dest/src"
cp "$tmp/palette-native/tools/wayland-scanner.zig" "$dest/tools/"
cp "$tmp/protocols/"*.xml "$tmp/protocols/README.md" "$dest/protocols/"
# Docs that describe the experiment's own build steps stay upstream; the
# per-area READMEs under src/ are kept because they document the API.

cat >"$dest/VENDORED_FROM" <<EOF
repo: palette-decouple-research (palette-native)
commit: $sha
subject: $subject
paths: palette-native/src, palette-native/tools/wayland-scanner.zig, protocols/*.xml, protocols/README.md
refresh: scripts/dev/vendor-palette-native.sh <palette-native repo> <commit>
EOF
echo "vendored palette-native $sha into $dest"
