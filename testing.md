# Verde UI Scroll Blur Test

Use this workflow when checking the native UI blur issue on Hyprland.

1. Build the desktop app:
   ```bash
   zig build --release=safe -Dcef-sdk-path=/home/rtg/.cache/verde/cef-sdk/cef_binary_146.0.9+g3ca6a87+chromium-146.0.7680.165_linux64_minimal
   ```

2. Open the app from this worktree:
   ```bash
   packages/desktop/zig-out/bin/verde
   ```

3. Find the Verde window and its exact compositor geometry:
   ```bash
   hyprctl clients -j | jq -r '.[] | select(.class=="com.verde.native") | {address,at,size,monitor,workspace,title}'
   ```

4. Focus the window using the reported address:
   ```bash
   hyprctl dispatch focuswindow address:<address>
   ```

5. Capture the window with `grim` using the reported `at` and `size` values:
   ```bash
   grim -g '<x>,<y> <w>x<h>' /tmp/verde-open.png
   ```

6. Put the pointer over the transcript area, then send PageUp key presses:
   ```bash
   ydotool mousemove -a -- <x> <y>
   ydotool click 0xC0
   for i in {1..3}; do ydotool key 104:1 104:0; sleep 0.08; done
   ```

7. Capture the same window again:
   ```bash
   grim -g '<x>,<y> <w>x<h>' /tmp/verde-pageup-3.png
   ```

8. For local inspection, enlarge the sidebar crop without smoothing:
   ```bash
   magick /tmp/verde-pageup-3.png -filter point -crop 330x760+0+80 -resize 300% /tmp/verde-pageup-3-sidebar-3x.png
   ```

Pass criteria: after several PageUp presses, sidebar text, thread title text, transcript text, and composer text remain pixel-crisp and do not become globally softened.

## Confirmed Fix Notes

The May 14, 2026 repro was not only a DPI/scaling issue. The scrolled render appended enough Palette text to reallocate the shared frame text `ArrayList`; existing render commands kept slices into the old allocation, so SDL_ttf later read stale bytes and rendered replacement glyphs / blurry-looking corrupted text.

The fixed path stores render-command text in a per-frame arena, reset at the start of each frame. Code-copy payload bytes still use `palette_frame_text` because those are addressed by offset/length instead of render-command slices.

Validated with:

```bash
grim -g '1287,38 1261x1030' /tmp/verde-arena-3pageup.png
grim -g '1287,38 1261x1030' /tmp/verde-arena-15pageup.png
magick /tmp/verde-arena-15pageup.png -filter point -crop 360x760+0+80 -resize 300% /tmp/verde-arena-15pageup-sidebar-3x.png
```

The 15-PageUp capture keeps the sidebar, transcript, and composer text readable and stable.
