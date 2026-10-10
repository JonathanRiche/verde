# Palette font engine (`src/font`)

A pure-Zig font stack with no FreeType, HarfBuzz, stb_truetype, fontconfig or C code. It
covers the sfnt parser, the rasterizer, "shaping-lite" (cmap, fallback, kerning, ligatures,
clusters), measurement, and fontconfig-free system discovery. The contract shared with the
GPU glyph cache is `api.zig`.

| file | contents |
|---|---|
| `api.zig` | Contract: `Face` vtable, `GlyphKey`, `Bitmap`, `ShapedGlyph`, `LineMetrics`, `Source`, `SystemQuery`. Extensions are listed at the top of the file. |
| `sfnt.zig` | Bounds-checked sfnt parser. Covers the table directory/TTC, head/hhea/maxp/hmtx/loca/glyf (simple and composite), cmap, OS/2, post and name. Outlines are emitted to a sink. |
| `otl.zig` | The legacy `kern` table (format 0) and GPOS pair kerning (type 2, formats 1 and 2, reached through extension type 9). GSUB single (type 1) and ligature (type 4) substitution, also through extension type 7. |
| `cff.zig` | CFF (`OTTO`) outlines with a Type 2 charstring interpreter. Covers subrs, flex, hintmask, and CID FDSelect. |
| `raster.zig` | Exact-area coverage rasterizer: signed-area accumulation and a SIMD prefix sum. |
| `sfnt_face.zig` | `SfntFace`, the built-in `api.Face`. It mmaps the file (MAP_PRIVATE, read-only) or borrows/owns the bytes. |
| `collection.zig` | `Collection`: faces, role chains, `shape`, `rasterize`, `lineMetrics`, the measurement helpers, the shaping cache and the `text_layout.FontMetrics` adapter. |
| `discovery.zig` | System font index (XDG dirs), on-disk cache, scored `SystemQuery` matching, and `fallbackForCodepoint`. |
| `tests.zig` | Unit tests (`zig build test-font`). |

Tools and examples:

- `zig build font_render` writes `out/font_render.png`. It contains our rendering, with the SDL_ttf reference image under each line when present.
- `zig build font_bench` runs the benchmarks.
- `zig build font_parity` compares against the SDL3_ttf dump.
- `zig build font_discover` shows the system index and fallback.
- `tools/font_reference` holds the dev-only SDL3_ttf dumper. It is the only place that links SDL.

## Design

**Parsing.** `sfnt.Font.init(bytes, face_index)` validates the directory and keeps each table as a
slice view into the font bytes. Nothing is copied, and the parser never allocates. Every read goes
through checked accessors (`u16At`, `sub`, ...), which return `error.InvalidFont`. Composite
recursion is limited to depth 8, CFF subroutine depth to 10, the charstring stack to 48, and glyph
size to 2048 px. A corrupted font therefore degrades to a missing glyph instead of a crash. The
fuzz tests truncate and corrupt NotoSans and C059 hundreds of times. They also feed random
garbage to `Font.init`.

**cmap.** Formats 0, 4, 6, 12 and 13 are parsed. Subtable preference is (3,10) > (0,4|6) > (3,1) > (0,3) >
(0,0-2) > (3,0) > (1,0). Symbol (3,0) fonts also answer U+F0xx for bytes 0x00-0xFF.

**Vertical metrics.** These match FreeType 2.14, and so what SDL_ttf reported:

- `face->ascender`, `descender` and `height` come from OS/2 typo metrics when `fsSelection.USE_TYPO_METRICS` is set.
- Otherwise they come from hhea.
- If both hhea values are 0, the typo values are used, then the win values.

In `MetricsMode.sdl_ttf_compat` (the default), `Collection.lineMetrics` reproduces SDL_ttf exactly.
All values use 26.6 math at `round(size*64)`:

- `ascent = FT_CEIL(asc)`
- `descent = FT_CEIL(-desc)`
- `lineHeight() = FT_CEIL(asc+desc+gap)` (SDL `lineskip`)

`line_gap` absorbs the remainder. SDL's separate `height`, `ceil(asc+desc)`, is not exposed. Use
`.exact` to get unrounded values.

**Advances.** These match FreeType with hinting:

- `AdvanceMode.round_glyph` (the default) gives each glyph `FT_PIX_ROUND(FT_MulFix(units, scale))` in 26.6.
- Fonts with `head.flags` bit 3 are scaled at the integer ppem, which is what FreeType's hinted metrics do.
- Kerning is then added in 26.6 fractions, which is HarfBuzz behaviour.
- `.fractional` gives unrounded advances, for zoomed or scaled UIs.

**Kerning.** GPOS `kern` lookups come first. They are collected from the DFLT, latn or first script's
default LangSys. Inside a lookup the first matching subtable wins, and value1.XAdvance +
value2.XPlacement are summed. If the font has no GPOS kern feature, the legacy `kern` table is used.

**Ligatures.** GSUB `liga`/`clig`/`rlig` (types 1 and 4, plus extension type 7) are applied per
same-face run. They are opt-in per role through `RoleConfig.ligatures`. They are on for ui/prose
roles and off for mono roles by default, which also keeps fixed-cell layout. `calt` is never
applied.

**Shaping** is `Collection.shape(role, size, utf8)`:

- UTF-8 is decoded strictly. Invalid, overlong, surrogate and truncated sequences each become one U+FFFD.
- Each codepoint is resolved through the role's chain. Results go in a per-role codepoint cache of up to 8192 entries, which is reset when full.
- Kerning applies between neighbours from the same face.
- Clusters are byte offsets of the first codepoint.
- Tab counts as 4× the space advance, and `\r` is treated as a space.
- Control characters and default ignorables (ZWJ/ZWNJ, VS1-16, BOM, ...) become `api.invisible_glyph` with zero advance.
- Roles without a chain use the `ui` chain.
- Optionally (`Options.system_fallback`), codepoints missing from the whole chain are looked up in the system index, and the resulting face is added lazily.

**Shaping cache.** `shapeCached` uses two generations, keyed by (role, size_26_6, wyhash(text), len)
and verified against the stored text. When the current generation exceeds half of
`shape_cache_bytes` (default 1 MiB), the generations rotate. Texts larger than 16 KiB bypass the
cache. The returned slice is valid until the next shaping call on the collection.

**Measurement.** All three helpers below use the cache.

- `measureText` returns the pen position after the last glyph.
- `measureTextOffset(text, off)` returns the pen x at the start of the cluster containing `off`. Offsets inside a ligature or a multibyte sequence snap to the cluster start.
- `glyphAdvances` writes one advance per byte, like the old renderer. Continuation bytes and ligature components get 0.

`fontMetrics(role, size)` returns a `text_layout.FontMetrics`. Its `advance` callback evaluates a 2-4
codepoint window, so results match `shape`, including ligatures and kerning. The context pointer
stays valid for the collection's lifetime.

**Rasterizer.** It works as follows:

1. Outlines are converted to pixel space. Y is flipped, and x is shifted by `subpixel_x/4` px before bounds are taken.
2. Quadratic and cubic curves are flattened adaptively. With tolerance 0.08 px, n = ⌈√(d/4tol)⌉ for quads and ⌈√(0.75·d/tol)⌉ for cubics.
3. Each line segment accumulates exact signed area and cover into an f32 buffer, font-rs style.
4. Each row runs an `@Vector(8, f32)` prefix sum. Coverage is `min(1, |acc|)`, which gives non-zero winding for well-formed fonts.
5. An optional gamma/contrast LUT is applied (`Options.coverage_gamma` and `coverage_contrast`; identity by default).

Retained `Workspace` buffers mean steady-state rasterization allocates only the output bitmap,
which comes from the caller's scratch allocator. Shaping allocates only to grow retained buffers.

**Discovery.** It scans these directories recursively, up to depth 10, deduplicating directories and following symlinks:

- `$XDG_DATA_HOME/fonts` and `~/.local/share/fonts`
- `~/.fonts`
- `$XDG_DATA_DIRS/*/fonts`
- `/usr/share/fonts` and `/usr/local/share/fonts`

For each `.ttf`, `.otf`, `.ttc` or `.otc` file (every face of a collection), it reads only the
directory plus the `name`, `OS/2`, `post` and `head` tables, using positional reads.

The cache lives at `$XDG_CACHE_HOME/palette/fonts-v1.bin`. It stores every scanned directory's
mtime and is invalidated when any of them changes. It is written to a temporary file and then
renamed.

`match` scores entries as follows:

- Family: typographic name (id 16) 1000, legacy name (id 1) 950, prefix 600, generic alias list 800-700.
- Weight penalty: CSS-like asymmetric distance.
- Italic mismatch: −120.
- Monospace wanted but missing: −200.
- Bitmap-only faces: −400.

The generic aliases are sans-serif/system-ui, serif, monospace and emoji. Unknown families fall
back to the generic sans or mono list.

`fallbackForCodepoint` probes one representative face per family, in tiers:

1. Primary UI faces (Noto Sans, DejaVu, Liberation, Adwaita, Cantarell, Noto Sans CJK SC).
2. Other `Noto Sans <Script>` faces.
3. Other proportional faces.
4. Monospace faces.
5. Symbol, math, emoji and icon faces.

Each probe reads only the cmap and maxp tables. Cmaps are cached under an 8 MiB LRU budget, and
results are cached per codepoint, both positive and negative.

**Memory.** Path fonts are `mmap`ed read-only with MAP_PRIVATE. Parsed tables are views into the
mapping, so a face costs about 300 B of heap. `Collection.memoryStats()` reports heap bytes (faces,
shape cache, scratch, codepoint caches) separately from mapped bytes.
`discovery.Index.memoryUsed()` reports the index heap, about 0.5 MiB for 2,400 faces.

## Using a custom `Face`

Any host type can join a role chain:

```zig
const MyFace = struct {
    fn glyphIndex(p: *anyopaque, cp: u21) font.GlyphId { ... }   // 0 = missing
    fn advance(p: *anyopaque, g: font.GlyphId) i32 { ... }       // font units
    fn kerning(p: *anyopaque, l: font.GlyphId, r: font.GlyphId) i32 { return 0; }
    fn unitsPerEm(p: *anyopaque) u16 { return 1000; }
    fn unitMetrics(p: *anyopaque) font.api.UnitMetrics { ... }
    fn rasterize(p: *anyopaque, g: font.GlyphId, px: f32, sub: u8, scratch: std.mem.Allocator) anyerror!font.Bitmap { ... }
    fn deinit(p: *anyopaque, gpa: std.mem.Allocator) void { ... } // called by Collection.destroy
    const vtable: font.api.Face.VTable = .{ .glyphIndex = glyphIndex, .advance = advance,
        .kerning = kerning, .unitsPerEm = unitsPerEm, .unitMetrics = unitMetrics,
        .rasterize = rasterize, .deinit = deinit };   // substitute/glyphBounds optional
};
const id = try coll.addFace(.{ .custom = .{ .ptr = my_face, .vtable = &MyFace.vtable } });
try coll.setRoleChain(.icon, &.{ id, noto_symbols });
```

The `Collection` takes ownership: `deinit` is called with the collection's allocator. Custom
faces always use the generic `rasterize` path.

## GPU atlas conventions

- **Pixel format.** `Bitmap.format == .coverage8`, `stride == width`, and pixels are row-major from top to bottom. Pixels are linear coverage, so blend them in linear space or apply your own gamma.
- **Placement.** For pen position `(px, baseline_y)` in device pixels, with y pointing down: `x = floor(px) + left` and `y = baseline_y - top`. `top` uses the FreeType `bitmap_top` convention: the distance up from the baseline. The shift `(px - floor(px))` is quantized to `subpixel_x = floor(frac * 4)`, which is part of `GlyphKey`.
- **Sub-pixel positions.** There are 4 buckets (`api.subpixel_steps`), at x + 0, .25, .5 and .75 px. The y position should be snapped to whole pixels.
- **Empty glyphs.** Space and other glyphs with no outline return an empty bitmap (`isEmpty()`). Skip them, but still advance the pen.
- **Invisible glyphs.** `ShapedGlyph.glyph == api.invisible_glyph` marks a zero-width, non-drawing cluster. `rasterize` returns an empty bitmap for it.
- **Size key.** `GlyphKey.size_26_6` is the pixel size in 1/64 px. The old renderer drew text at `font_size * 0.86` (`GPU_TEXT_FONT_SCALE`). If you need visual parity with it, apply that factor before passing sizes in. The engine itself does not scale.
- **Threading.** A `Collection` is single-threaded. To rasterize on a worker thread, give it its own `SfntFace` (a cheap view over the shared mapping) and its own `raster.Workspace`.

## Known gaps

- **No hinting.** SDL_ttf used FreeType's TrueType hinting at NORMAL, so its glyph shapes are crisper and slightly bolder. Ours are unhinted, exact-area anti-aliased glyphs. Advances and metrics still match SDL_ttf (see above). Two kinds of font still differ:
  - Fonts that FreeType auto-hints (no bytecode, e.g. NotoSansSymbols and NotoEmoji at some sizes) differ by ±1 px in about 25% of their ASCII advances.
  - Fonts whose ink is changed by `calt` (JetBrains Mono `//`, `->`) are affected, because we never apply `calt`.
- **Shaping limits.** There is no complex-script shaping: no Arabic joining, no Indic reordering, no mark positioning (GPOS 4/5/6), no contextual GSUB (5/6), and no bidi. Combining marks get their own advance, which is usually zero.
- **Colour glyphs and variable fonts.** There are no colour glyphs (COLR/CPAL, CBDT, sbix) and no `rgba8_premul` output. Bitmap-only emoji fonts are skipped in fallback. Variable fonts (fvar/gvar/CFF2) render their default instance only.
- **Fallback limits.** `fallbackForCodepoint` does not consider the locale, and the system index does not watch for changes at runtime (only at startup through the mtime cache). There is no WOFF/WOFF2.
- **Measurement differences.** `measureText` returns the pen-based width. The old renderer returned the ink right edge for strings that do not end in whitespace, which is within the last glyph's RSB, under 1 px at UI sizes. SDL's `TTF_SubString.rect.x` is `floor(pen) + bitmap_left`, an ink position. We return the pen position, which is what caret placement needs.
