#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <source-png> <output-ico>" >&2
  exit 1
fi

SOURCE_PNG="$1"
OUTPUT_ICO="$2"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick 7 is required to create the Windows icon" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ICO")"

# Windows expects a square, multi-resolution icon. The Verde mark is taller
# than it is wide, so center it on a transparent canvas with enough breathing
# room to remain legible in the taskbar and Start search at small sizes.
magick "$SOURCE_PNG" \
  -background none \
  -gravity center \
  -extent 416x416 \
  -define icon:auto-resize=256,128,64,48,32,24,20,16 \
  "$OUTPUT_ICO"
