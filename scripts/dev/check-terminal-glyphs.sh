#!/usr/bin/env bash
# check-terminal-glyphs.sh — print a curated set of Unicode symbols that TUIs
# and CLIs commonly emit, so we can spot any glyphs Verde's font-fallback
# chain still can't render.
#
# Usage:
#   In Verde's terminal pane, run:
#     bash scripts/dev/check-terminal-glyphs.sh
#   Any line where the glyph column shows a tofu box (□) is a missing glyph.
#   Send the U+XXXX list of tofus back so we can map them in.
#
# Render order matches the font fallback chain Verde uses:
#   mono → mono_symbols → icon → symbols → emoji → prose
#
# Requires bash 4.2+ (for printf '\uXXXX' / '\UXXXXXXXX').

set -u

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
glyph() {
    local hex=$1 name=$2 ch
    if [ ${#hex} -le 4 ]; then
        ch=$(printf "\u${hex}")
    else
        ch=$(printf "\U${hex}")
    fi
    printf '  U+%-8s %s  %s\n' "$hex" "$ch" "$name"
}

section "ASCII baseline (sanity — must always render)"
glyph 0041 "LATIN A"
glyph 007E "TILDE"

section "Arrows commonly used in CLIs"
glyph 2190 "LEFT"
glyph 2191 "UP"
glyph 2192 "RIGHT"
glyph 2193 "DOWN"
glyph 21B5 "RETURN/CRLF"
glyph 21D0 "DOUBLE LEFT"
glyph 21D2 "DOUBLE RIGHT"
glyph 27A1 "BLACK RIGHTWARDS"
glyph 279C "HEAVY ROUND-TIPPED RIGHT (Vite)"
glyph 27A4 "BLACK RIGHTWARDS"
glyph 2794 "HEAVY WIDE RIGHT"
glyph 25B6 "BLACK RIGHT-POINTING TRIANGLE"
glyph 25B8 "BLACK SMALL RIGHT-POINTING TRIANGLE"
glyph 25BA "BLACK RIGHT-POINTING POINTER"
glyph 2B95 "RIGHTWARDS BLACK ARROW"

section "Bullets / dots / circles (status indicators)"
glyph 2022 "BULLET •"
glyph 25E6 "WHITE BULLET ◦"
glyph 2027 "HYPHENATION POINT"
glyph 25CF "BLACK CIRCLE ●"
glyph 25CB "WHITE CIRCLE ○"
glyph 25C9 "FISHEYE ◉"
glyph 25CE "BULLSEYE ◎"
glyph 25CD "CIRCLE WITH VERTICAL FILL"
glyph 25D0 "LEFT HALF BLACK CIRCLE"
glyph 25D1 "RIGHT HALF BLACK CIRCLE"
glyph 25D2 "LOWER HALF BLACK CIRCLE"
glyph 25D3 "UPPER HALF BLACK CIRCLE"

section "Squares / blocks (status indicators)"
glyph 25A0 "BLACK SQUARE ■"
glyph 25A1 "WHITE SQUARE □"
glyph 25A3 "WHITE SQUARE CONTAINING BLACK"
glyph 25FC "BLACK MEDIUM SQUARE"
glyph 25FB "WHITE MEDIUM SQUARE"
glyph 2588 "FULL BLOCK █"
glyph 2591 "LIGHT SHADE ░"
glyph 2592 "MEDIUM SHADE ▒"
glyph 2593 "DARK SHADE ▓"

section "Spinner frames (Claude Code, Codex, Opencode)"
glyph 2731 "HEAVY ASTERISK ✱"
glyph 2732 "OPEN CENTRE ASTERISK ✲"
glyph 2733 "EIGHT-SPOKED ASTERISK ✳"
glyph 2734 "EIGHT POINTED BLACK STAR ✴"
glyph 2735 "EIGHT POINTED PINWHEEL STAR ✵"
glyph 2736 "SIX POINTED BLACK STAR ✶"
glyph 2737 "EIGHT POINTED RECTILINEAR ✷"
glyph 2738 "HEAVY EIGHT POINTED RECT ✸"
glyph 2739 "TWELVE POINTED BLACK STAR ✹"
glyph 273A "SIXTEEN POINTED ASTERISK ✺"
glyph 273B "TEARDROP-SPOKED ASTERISK ✻"
glyph 273C "OPEN CENTRE TEARDROP ASTERISK ✼"
glyph 273D "HEAVY TEARDROP-SPOKED ASTERISK ✽"
glyph 273E "SIX PETALLED BLACK ROSETTE ✾"
glyph 2722 "FOUR TEARDROP-SPOKED ASTERISK ✢"
glyph 2724 "HEAVY FOUR BALLOON ASTERISK ✤"
glyph 2726 "BLACK FOUR POINTED STAR ✦"
glyph 2727 "WHITE FOUR POINTED STAR ✧"

section "Check / cross / status (plain Dingbats)"
glyph 2713 "CHECK ✓"
glyph 2714 "HEAVY CHECK ✔"
glyph 2715 "MULTIPLICATION X ✕"
glyph 2716 "HEAVY MULTIPLICATION X ✖"
glyph 2717 "BALLOT X ✗"
glyph 2718 "HEAVY BALLOT X ✘"

section "Emoji-style Dingbats (Vite, build tools)"
glyph 2728 "SPARKLES ✨ (Vite)"
glyph 2705 "WHITE HEAVY CHECK ✅"
glyph 274C "CROSS MARK ❌"
glyph 274E "NEGATIVE SQUARED CROSS ❎"
glyph 2764 "HEAVY BLACK HEART ❤"
glyph 2795 "HEAVY PLUS SIGN ➕"
glyph 2796 "HEAVY MINUS SIGN ➖"
glyph 2797 "HEAVY DIVISION SIGN ➗"
glyph 2754 "WHITE QUESTION MARK ❔"
glyph 2755 "WHITE EXCLAMATION MARK ❕"

section "Numbered Dingbats"
glyph 2776 "DINGBAT NEGATIVE 1 ❶"
glyph 2777 "DINGBAT NEGATIVE 2 ❷"
glyph 2780 "DINGBAT CIRCLED SANS 1 ➀"
glyph 278A "DINGBAT NEGATIVE CIRCLED SANS 1 ➊"

section "Misc symbols (warn / info / weather)"
glyph 26A0 "WARNING ⚠"
glyph 26A1 "HIGH VOLTAGE / LIGHTNING ⚡"
glyph 2139 "INFORMATION SOURCE ℹ"
glyph 2699 "GEAR ⚙"
glyph 2691 "BLACK FLAG ⚑"
glyph 2693 "ANCHOR ⚓"
glyph 2603 "SNOWMAN ☃"
glyph 2600 "BLACK SUN WITH RAYS ☀"
glyph 2601 "CLOUD ☁"
glyph 26C5 "SUN BEHIND CLOUD ⛅"
glyph 2B50 "WHITE MEDIUM STAR ⭐"
glyph 2606 "WHITE STAR ☆"
glyph 2605 "BLACK STAR ★"

section "Box drawing"
glyph 2500 "LIGHT HORIZONTAL ─"
glyph 2502 "LIGHT VERTICAL │"
glyph 250C "LIGHT TOP-LEFT ┌"
glyph 2510 "LIGHT TOP-RIGHT ┐"
glyph 2514 "LIGHT BOTTOM-LEFT └"
glyph 2518 "LIGHT BOTTOM-RIGHT ┘"
glyph 251C "T RIGHT ├"
glyph 2524 "T LEFT ┤"
glyph 252C "T DOWN ┬"
glyph 2534 "T UP ┴"
glyph 253C "CROSS ┼"
glyph 2550 "DOUBLE HORIZONTAL ═"
glyph 2554 "DOUBLE TOP-LEFT ╔"
glyph 256D "ROUND TOP-LEFT ╭"
glyph 256F "ROUND BOTTOM-RIGHT ╯"
glyph 2570 "ROUND BOTTOM-LEFT ╰"

section "Misc Technical / connectors"
glyph 23BF "DENTISTRY VERT BOTTOM RIGHT ⎿ (Claude Code connector)"
glyph 23F4 "LEFT BLACK POINTING POINTER"
glyph 23F5 "RIGHT BLACK POINTING POINTER"
glyph 2318 "PLACE OF INTEREST ⌘"
glyph 2325 "OPTION KEY ⌥"
glyph 232B "ERASE TO THE LEFT ⌫"
glyph 21E7 "UPWARDS WHITE ARROW (shift) ⇧"

section "Powerline (Nerd Font private-use, geometry path)"
glyph E0A0 "BRANCH"
glyph E0A2 "LOCK"
glyph E0B0 "RIGHT SOLID separator"
glyph E0B1 "RIGHT THIN separator"
glyph E0B2 "LEFT SOLID separator"
glyph E0B3 "LEFT THIN separator"
glyph E0B4 "ROUND RIGHT"
glyph E0B6 "ROUND LEFT"

section "Nerd Font common (private-use)"
glyph F015 "HOME"
glyph F07B "FOLDER"
glyph F126 "BRANCH"
glyph F09B "GITHUB MARK"
glyph F0E7 "FLASH"
glyph F1B3 "DOCKER"

section "4-byte emoji (build tool outputs)"
glyph 1F300 "CYCLONE 🌀"
glyph 1F4E6 "PACKAGE 📦"
glyph 1F525 "FIRE 🔥"
glyph 1F680 "ROCKET 🚀"
glyph 1F389 "PARTY POPPER 🎉"
glyph 1F3AF "DIRECT HIT 🎯"
glyph 1F4A1 "ELECTRIC LIGHT BULB 💡"
glyph 1F9EA "TEST TUBE 🧪"
glyph 1F600 "GRINNING FACE 😀"

echo
echo "Any line where the glyph column shows a tofu box is a missing glyph."
echo "Send the U+XXXX list of tofus back and we'll wire them up."
