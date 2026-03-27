#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$HOME/.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p \
  "$PREFIX/bin" \
  "$PREFIX/share/applications" \
  "$PREFIX/share/pixmaps"

install -m 755 "$SCRIPT_DIR/bin/verde" "$PREFIX/bin/verde"
install -m 755 "$SCRIPT_DIR/bin/libfff_c.so" "$PREFIX/bin/libfff_c.so"
install -m 644 "$SCRIPT_DIR/share/applications/verde.desktop" "$PREFIX/share/applications/verde.desktop"
install -m 644 "$SCRIPT_DIR/share/pixmaps/verde.png" "$PREFIX/share/pixmaps/verde.png"

echo "Installed Verde into $PREFIX"
echo "Binary: $PREFIX/bin/verde"
echo "Desktop entry: $PREFIX/share/applications/verde.desktop"
