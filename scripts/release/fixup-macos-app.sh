#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <Verde.app>" >&2
  exit 1
fi

APP_DIR="$1"
MACOS_DIR="$APP_DIR/Contents/MacOS"
FFF_LIB="$MACOS_DIR/libfff_c.dylib"
DESIRED_FFF_REF="@executable_path/libfff_c.dylib"
TREE_SITTER_PATTERN='libtree-sitter[^[:space:]]*\.dylib'
SDL3_TTF_PATTERN='libSDL3_ttf[^[:space:]]*\.dylib'
SDL3_FRAMEWORK="$MACOS_DIR/SDL3.framework"

find_cmd() {
  local primary="$1"
  local fallback="$2"

  if command -v "$primary" >/dev/null 2>&1; then
    command -v "$primary"
    return 0
  fi

  if command -v "$fallback" >/dev/null 2>&1; then
    command -v "$fallback"
    return 0
  fi

  return 1
}

INSTALL_NAME_TOOL="$(find_cmd install_name_tool llvm-install-name-tool || true)"
OTOOL="$(find_cmd otool llvm-otool || true)"
CODESIGN="$(find_cmd codesign codesign || true)"

if [[ -z "$INSTALL_NAME_TOOL" ]]; then
  echo "install_name_tool or llvm-install-name-tool is required" >&2
  exit 1
fi

if [[ -z "$OTOOL" ]]; then
  echo "otool or llvm-otool is required" >&2
  exit 1
fi

if [[ -z "$CODESIGN" ]]; then
  echo "codesign is required" >&2
  exit 1
fi

if [[ ! -f "$FFF_LIB" ]]; then
  echo "missing bundled libfff_c.dylib at $FFF_LIB" >&2
  exit 1
fi

OTOOL_TMP="$(mktemp /tmp/verde-macos-otool.XXXXXX)"
trap 'rm -f "$OTOOL_TMP"' EXIT

extract_dependency_ref() {
  local candidate="$1"
  local pattern="$2"

  if ! "$OTOOL" -L "$candidate" >"$OTOOL_TMP" 2>/dev/null; then
    return 1
  fi

  awk -v pattern="$pattern" '$1 ~ pattern { print $1; exit }' "$OTOOL_TMP"
}

rewrite_dependency_refs() {
  local pattern="$1"
  local desired_ref="$2"

  while IFS= read -r -d '' candidate; do
    current_ref="$(extract_dependency_ref "$candidate" "$pattern" || true)"
    if [[ -z "$current_ref" || "$current_ref" == "$desired_ref" ]]; then
      continue
    fi

    "$INSTALL_NAME_TOOL" -change "$current_ref" "$desired_ref" "$candidate"
  done < <(find "$MACOS_DIR" -maxdepth 1 -type f -print0)
}

ensure_bundled_dependency() {
  local pattern="$1"
  local bundled_path="$2"
  local desired_ref="$3"

  if [[ ! -f "$bundled_path" ]]; then
    echo "missing bundled library at $bundled_path" >&2
    exit 1
  fi

  "$INSTALL_NAME_TOOL" -id "$desired_ref" "$bundled_path"
  rewrite_dependency_refs "$pattern" "$desired_ref"
}

bundle_dependency_from_existing_ref() {
  local pattern="$1"
  local source_ref=""

  while IFS= read -r -d '' candidate; do
    source_ref="$(extract_dependency_ref "$candidate" "$pattern" || true)"
    if [[ -n "$source_ref" ]]; then
      break
    fi
  done < <(find "$MACOS_DIR" -maxdepth 1 -type f -print0)

  if [[ -z "$source_ref" ]]; then
    return 0
  fi

  local bundled_name
  bundled_name="$(basename "$source_ref")"
  local bundled_path="$MACOS_DIR/$bundled_name"
  local desired_ref="@executable_path/$bundled_name"

  if [[ ! -f "$bundled_path" ]]; then
    if [[ "$source_ref" != /* || ! -f "$source_ref" ]]; then
      echo "unable to bundle dependency from $source_ref" >&2
      exit 1
    fi

    install -m 755 "$source_ref" "$bundled_path"
  fi

  ensure_bundled_dependency "$pattern" "$bundled_path" "$desired_ref"
}

normalize_sdl3_framework() {
  if [[ ! -d "$SDL3_FRAMEWORK/Versions/A" ]]; then
    return 0
  fi

  rm -rf \
    "$SDL3_FRAMEWORK/Versions/Current" \
    "$SDL3_FRAMEWORK/SDL3" \
    "$SDL3_FRAMEWORK/Headers" \
    "$SDL3_FRAMEWORK/Resources"

  ln -s A "$SDL3_FRAMEWORK/Versions/Current"
  ln -s Versions/Current/SDL3 "$SDL3_FRAMEWORK/SDL3"
  ln -s Versions/Current/Headers "$SDL3_FRAMEWORK/Headers"
  ln -s Versions/Current/Resources "$SDL3_FRAMEWORK/Resources"
}

sign_app_bundle() {
  while IFS= read -r -d '' binary; do
    "$CODESIGN" --force --sign - "$binary" >/dev/null
  done < <(find "$MACOS_DIR" -type f \( -perm -111 -o -name '*.dylib' \) -print0)

  "$CODESIGN" --force --sign - "$APP_DIR" >/dev/null
  "$CODESIGN" --verify --strict --verbose=2 "$APP_DIR" >/dev/null
}

ensure_bundled_dependency 'libfff_c\.dylib' "$FFF_LIB" "$DESIRED_FFF_REF"
bundle_dependency_from_existing_ref "$TREE_SITTER_PATTERN"
bundle_dependency_from_existing_ref "$SDL3_TTF_PATTERN"
normalize_sdl3_framework
sign_app_bundle
