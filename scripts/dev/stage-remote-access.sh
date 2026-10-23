#!/usr/bin/env bash
# Stage verde-server and the verde-web gateway beside the dev GUI in zig-out,
# in the same layout the release packages use, so Settings → Remote access
# works from a dev build:
#   zig-out/bin/verde-server, zig-out/bin/verde-web, zig-out/share/verde/web/
# Release packages already ship these (scripts/release/package-*.sh).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

zig build server --release=safe

(
  cd packages/web_app
  bun install --frozen-lockfile >/dev/null
  zig build --release=safe
  bun run build
)

install -d zig-out/bin zig-out/share/verde
install -m 755 packages/web_app/zig-out/bin/verde-web zig-out/bin/verde-web.new
mv -f zig-out/bin/verde-web.new zig-out/bin/verde-web

rm -rf zig-out/share/verde/web.new
cp -a packages/web_app/dist zig-out/share/verde/web.new
rm -rf zig-out/share/verde/web
mv zig-out/share/verde/web.new zig-out/share/verde/web

echo "Staged verde-server, verde-web and web assets in $repo_root/zig-out"
