#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${1:-/Users/jhonellebriche/Applications/Verde.app}"

cd "$REPO_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS WKWebView check must run on macOS" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd rg
need_cmd codesign
need_cmd nm
need_cmd otool

required_exports=(
  verde_macos_webview_create
  verde_macos_webview_destroy
  verde_macos_webview_show
  verde_macos_webview_hide
  verde_macos_webview_set_bounds
  verde_macos_webview_navigate
  verde_macos_webview_eval
  verde_macos_webview_post_json
  verde_macos_webview_go_back
  verde_macos_webview_go_forward
  verde_macos_webview_reload
  verde_macos_webview_focus
  verde_macos_webview_blur
  verde_macos_webview_has_focus
  verde_macos_app_configure_foreground
  verde_macos_webview_appkit_diagnostics
  verde_macos_webview_pop_event
  verde_macos_webview_free_string
)

for symbol in "${required_exports[@]}"; do
  if ! rg -q "@_cdecl\\(\"$symbol\"\\)" packages/desktop/src/browser/platform/macos_wkwebview.swift; then
    echo "Swift WKWebView shim is missing exported symbol: $symbol" >&2
    exit 1
  fi
  if ! rg -q "extern fn $symbol" packages/desktop/src/browser/platform/macos_wkwebview.zig; then
    echo "Zig WKWebView wrapper is missing extern for symbol: $symbol" >&2
    exit 1
  fi
done

if ! rg -q "addMacOSSwiftWebView\\(b, exe\\)" packages/desktop/build.zig; then
  echo "macOS app build is not wired to addMacOSSwiftWebView" >&2
  exit 1
fi

if ! rg -q "addMacOSSwiftWebView\\(b, exe_tests\\)" packages/desktop/build.zig; then
  echo "macOS native-webview tests are not wired to addMacOSSwiftWebView" >&2
  exit 1
fi

if rg -q "macos_wkwebview\\.m" packages/desktop/build.zig; then
  echo "Objective-C macos_wkwebview.m is still active in packages/desktop/build.zig" >&2
  exit 1
fi

if [[ -e packages/desktop/src/browser/platform/macos_wkwebview.m ]]; then
  echo "stale Objective-C macos_wkwebview.m still exists; Swift must be the only macOS WKWebView shim" >&2
  exit 1
fi

if ! rg -q 'if \(macosNativeBrowserShouldOwnKeyboard\(state\)\)' packages/desktop/src/main.zig; then
  echo "main.zig no longer checks native WKWebView keyboard ownership before routing SDL text input" >&2
  exit 1
fi

if ! rg -q 'sdl\.stopTextInput\(window\)' packages/desktop/src/main.zig; then
  echo "main.zig no longer stops SDL text input for native WKWebView focus" >&2
  exit 1
fi

if ! rg -q 'macosBrowserClickWillFocusNativeSurface\(state, event\.button\.x, event\.button\.y\)' packages/desktop/src/main.zig; then
  echo "main.zig no longer pre-stops SDL text input before a macOS WKWebView click focus handoff" >&2
  exit 1
fi

if ! rg -q 'state\.palette_composer\.focused or state\.composer_focused' packages/desktop/src/main.zig; then
  echo "main.zig must not let native WKWebView own keyboard while the Palette composer is focused" >&2
  exit 1
fi

if ! awk '
  /state\.routePaletteComposerKeyDown\(&event\.key\)/ { seen_composer_key = 1 }
  /const native_browser_focused = state\.isNativeBrowserSurfaceFocused\(\);/ {
    if (!seen_composer_key) {
      exit 1
    }
    found = 1
    exit 0
  }
  END {
    if (!found) {
      exit 1
    }
  }
' packages/desktop/src/main.zig; then
  echo "main.zig must route Palette composer keydown before native WKWebView focus short-circuit" >&2
  exit 1
fi

if ! awk '
  /\.text_input =>/ { in_text = 1 }
  in_text && /state\.routePaletteComposerTextInput\(text_input\)/ { seen_composer_text = 1 }
  in_text && /const native_browser_focused = state\.isNativeBrowserSurfaceFocused\(\);/ {
    if (!seen_composer_text) {
      exit 1
    }
    found = 1
    exit 0
  }
  in_text && /^        },/ { in_text = 0 }
  END {
    if (!found) {
      exit 1
    }
  }
' packages/desktop/src/main.zig; then
  echo "main.zig must route Palette composer text input before native WKWebView focus short-circuit" >&2
  exit 1
fi

if ! awk '
  /macosBrowserClickWillFocusNativeSurface\(state, event\.button\.x, event\.button\.y\)/ { seen_pre_stop = 1 }
  /state\.handleBrowserMouse\(browserMouseButtonEvent\(&event\.button\)\)/ {
    if (!seen_pre_stop) {
      exit 1
    }
    found = 1
  }
  END {
    if (!found) {
      exit 1
    }
  }
' packages/desktop/src/main.zig; then
  echo "main.zig must stop SDL text input before forwarding the click that focuses native WKWebView" >&2
  exit 1
fi

start_text_input_count="$(rg -c 'sdl\.startTextInput\(window\) catch \{\};' packages/desktop/src/main.zig || true)"
if [[ "$start_text_input_count" != "1" ]]; then
  echo "main.zig must start SDL text input exactly once, inside syncWindowTextInput; found $start_text_input_count" >&2
  exit 1
fi

if ! awk '
  /^fn syncWindowTextInput\(/ { in_sync = 1 }
  in_sync && /sdl\.startTextInput\(window\) catch \{\};/ { found = 1 }
  in_sync && /^}/ { in_sync = 0 }
  END {
    if (!found) {
      exit 1
    }
  }
' packages/desktop/src/main.zig; then
  echo "main.zig must enable SDL text input only from syncWindowTextInput for Verde-owned text fields" >&2
  exit 1
fi

for script in scripts/release/install-macos-local.sh scripts/release/package-macos-app.sh; do
  if ! rg -q 'BROWSER_BACKEND="\$\{VERDE_BROWSER_BACKEND:-native_webview\}"' "$script"; then
    echo "$script does not default macOS packaging to native_webview" >&2
    exit 1
  fi
  if ! rg -q 'if \[\[ "\$BROWSER_BACKEND" == "cef" \]\]; then' "$script"; then
    echo "$script does not guard CEF setup behind the explicit cef backend" >&2
    exit 1
  fi
  if ! rg -q 'verde_cef_ensure_sdk macos "\$ARCH"' "$script"; then
    echo "$script no longer makes CEF SDK setup explicit to the cef backend path" >&2
    exit 1
  fi
done

if [[ ! -d "$APP_DIR" ]]; then
  echo "installed app not found: $APP_DIR" >&2
  echo "run: mise run build" >&2
  exit 1
fi

APP_BIN="$APP_DIR/Contents/MacOS/verde"
SWIFT_SHIM="packages/desktop/src/browser/platform/macos_wkwebview.swift"

if [[ ! -x "$APP_BIN" ]]; then
  echo "installed app binary not found or not executable: $APP_BIN" >&2
  exit 1
fi

if [[ "$APP_BIN" -ot "$SWIFT_SHIM" ]]; then
  echo "installed app binary is older than $SWIFT_SHIM; run: mise run build" >&2
  exit 1
fi

installed_symbols="$(nm -gU "$APP_BIN")"
for symbol in "${required_exports[@]}"; do
  if ! printf '%s\n' "$installed_symbols" | rg -q "_${symbol}$"; then
    echo "installed app binary is missing exported symbol: $symbol" >&2
    exit 1
  fi
done

if find "$APP_DIR" \( \
  -name 'Chromium Embedded Framework.framework' -o \
  -name 'verde-browser-cef' -o \
  -name 'verde-browser-cef-process' -o \
  -name 'libcef*' -o \
  -name '*.pak' -o \
  -name 'locales' \
\) -print -quit | rg -q .; then
  echo "installed native macOS app unexpectedly contains CEF/Chromium payload" >&2
  find "$APP_DIR" \( \
    -name 'Chromium Embedded Framework.framework' -o \
    -name 'verde-browser-cef' -o \
    -name 'verde-browser-cef-process' -o \
    -name 'libcef*' -o \
    -name '*.pak' -o \
    -name 'locales' \
  \) -print >&2
  exit 1
fi

while IFS= read -r binary; do
  linked_libs="$(otool -L "$binary" 2>/dev/null || true)"
  if [[ -z "$linked_libs" ]]; then
    continue
  fi
  if printf '%s\n' "$linked_libs" | rg -qi 'libcef|Chromium Embedded Framework|verde-browser-cef'; then
    echo "installed native macOS app unexpectedly links CEF/Chromium from: $binary" >&2
    printf '%s\n' "$linked_libs" >&2
    exit 1
  fi
  if printf '%s\n' "$linked_libs" | rg -q '/opt/homebrew|/usr/local|/Users/.*/development/verde-simple-webview'; then
    echo "installed native macOS app has non-app-local dependency reference in: $binary" >&2
    printf '%s\n' "$linked_libs" >&2
    exit 1
  fi
done < <(find "$APP_DIR/Contents/MacOS" -type f -perm -111 -print)

codesign --verify --strict --verbose=2 "$APP_DIR" >/dev/null

echo "macOS WKWebView build/package checks passed"
