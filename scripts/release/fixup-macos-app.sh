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
DESIRED_SDL3_FRAMEWORK_REF="@rpath/SDL3.framework/Versions/A/SDL3"

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

if ! command -v perl >/dev/null 2>&1; then
  echo "perl is required" >&2
  exit 1
fi

if [[ ! -f "$FFF_LIB" ]]; then
  echo "missing bundled libfff_c.dylib at $FFF_LIB" >&2
  exit 1
fi

OTOOL_TMP="$(mktemp /tmp/verde-macos-otool.XXXXXX)"
trap 'rm -f "$OTOOL_TMP"' EXIT

run_install_name_tool() {
  "$INSTALL_NAME_TOOL" "$@"
}

neutralize_swift_modhash_segment() {
  local binary="$1"

  if ! "$OTOOL" -l "$binary" >"$OTOOL_TMP" 2>/dev/null; then
    return 0
  fi

  if ! grep -q '__swift_modhash' "$OTOOL_TMP"; then
    return 0
  fi

  # Swift emits a tiny __LLVM,__swift_modhash section in object files. Apple's
  # install_name_tool/bitcode_strip can mistake that non-bitcode section for a
  # bitcode archive and refuse to edit the binary. Rename only the segment label
  # before dependency fixups; codesigning runs after this mutation.
  LC_ALL=C perl -0pi -e 's/__LLVM/__SWFT/g' "$binary"
}

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

    run_install_name_tool -change "$current_ref" "$desired_ref" "$candidate"
  done < <(find "$MACOS_DIR" -maxdepth 1 -type f -print0)
}

rewrite_sdl3_dylib_refs_to_framework() {
  if [[ ! -f "$SDL3_FRAMEWORK/Versions/A/SDL3" ]]; then
    return 0
  fi

  while IFS= read -r -d '' candidate; do
    if ! "$OTOOL" -L "$candidate" >"$OTOOL_TMP" 2>/dev/null; then
      continue
    fi

    while IFS= read -r current_ref; do
      [[ -n "$current_ref" && "$current_ref" != "$DESIRED_SDL3_FRAMEWORK_REF" ]] || continue
      run_install_name_tool -change "$current_ref" "$DESIRED_SDL3_FRAMEWORK_REF" "$candidate"
    done < <(awk '$1 ~ /(^|\/)libSDL3\.[^[:space:]]*dylib$/ { print $1 }' "$OTOOL_TMP")
  done < <(find "$MACOS_DIR" -type f -print0)
}

bundle_external_dylib_dependencies() {
  local changed=1

  while [[ "$changed" -eq 1 ]]; do
    changed=0

    while IFS= read -r -d '' candidate; do
      if ! "$OTOOL" -L "$candidate" >"$OTOOL_TMP" 2>/dev/null; then
        continue
      fi

      while IFS= read -r current_ref; do
        [[ -n "$current_ref" ]] || continue
        case "$current_ref" in
          "$MACOS_DIR"/*)
            ;;
          /opt/homebrew/*|/usr/local/*)
            local bundled_name bundled_path desired_ref
            bundled_name="$(basename "$current_ref")"
            bundled_path="$MACOS_DIR/$bundled_name"
            desired_ref="@executable_path/$bundled_name"

            if [[ "$bundled_name" =~ ^libSDL3\..*dylib$ && -f "$SDL3_FRAMEWORK/Versions/A/SDL3" ]]; then
              desired_ref="$DESIRED_SDL3_FRAMEWORK_REF"
            else
              if [[ ! -f "$bundled_path" ]]; then
                if [[ ! -f "$current_ref" ]]; then
                  echo "unable to bundle dependency from $current_ref" >&2
                  exit 1
                fi

                install -m 755 "$current_ref" "$bundled_path"
                run_install_name_tool -id "$desired_ref" "$bundled_path"
                changed=1
              else
                run_install_name_tool -id "$desired_ref" "$bundled_path"
              fi
            fi

            run_install_name_tool -change "$current_ref" "$desired_ref" "$candidate"
            ;;
        esac
      done < <(awk 'NR > 1 { print $1 }' "$OTOOL_TMP")
    done < <(find "$MACOS_DIR" -type f -print0)
  done
}

ensure_bundled_dependency() {
  local pattern="$1"
  local bundled_path="$2"
  local desired_ref="$3"

  if [[ ! -f "$bundled_path" ]]; then
    echo "missing bundled library at $bundled_path" >&2
    exit 1
  fi

  run_install_name_tool -id "$desired_ref" "$bundled_path"
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
    if [[ "$binary" == "$MACOS_DIR/verde" ]]; then
      continue
    fi

    "$CODESIGN" --force --sign - "$binary" >/dev/null
  done < <(
    find "$MACOS_DIR" -type f -print0 |
      while IFS= read -r -d '' candidate; do
        if file "$candidate" | grep -Eq 'Mach-O|dynamically linked shared library'; then
          printf '%s\0' "$candidate"
        fi
      done
  )

  "$CODESIGN" --force --sign - "$MACOS_DIR/verde" >/dev/null

  "$CODESIGN" --force --sign - "$APP_DIR" >/dev/null
  if ! "$CODESIGN" --verify --strict --verbose=2 "$APP_DIR"; then
    echo "warning: ad-hoc app signature verification failed during packaging" >&2
  fi
}

neutralize_swift_modhash_segment "$MACOS_DIR/verde"
ensure_bundled_dependency 'libfff_c\.dylib' "$FFF_LIB" "$DESIRED_FFF_REF"
bundle_dependency_from_existing_ref "$TREE_SITTER_PATTERN"
bundle_dependency_from_existing_ref "$SDL3_TTF_PATTERN"
normalize_sdl3_framework
rewrite_sdl3_dylib_refs_to_framework
bundle_external_dylib_dependencies
sign_app_bundle
