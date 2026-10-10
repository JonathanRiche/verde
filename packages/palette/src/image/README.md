# palette-native image: PNG codec

This is a pure-Zig PNG decoder and encoder. It has no dependencies and does not use `std.compress.flate.Decompress`. The std inflater asserts on corrupt input (`tossBitsShort`), so `inflate.zig` is our own inflater.

To wire it into the library root, add `pub const image = @import("image/root.zig");`.

## API

```zig
const image = @import("image/root.zig");

// Decode any PNG to RGBA8.
const img = try image.loadFromMemory(gpa, bytes);            // default DecodeOptions
const img2 = try image.png.decode(gpa, bytes, .{ .max_width = 8192 });
const img3 = try image.load(gpa, io, "icon.png", .{});
defer img.deinit(gpa);   // img.pixels: []u8, img.width, img.height, img.channels == 4, img.pitch()

// Read only the header (no allocation).
const hdr = try image.decodeInfo(bytes); // width, height, bit_depth, color_type, interlace

// Encode RGBA8.
const png_bytes = try image.encodeRgba(gpa, pixels, w, h, .{});      // caller frees
try image.saveRgba(gpa, io, "out.png", pixels, w, h, .{ .compression = .fastest });
// Lower level: any color type/depth, palette, tRNS, Adam7.
const raw = try image.png.encodeRaw(gpa, .{ .width = w, .height = h, .color_type = .indexed,
    .bit_depth = 4, .data = packed_rows, .palette = pal, .transparency = trns }, .{ .interlace = true });
```

`LoadedImage` keeps the shape of the old `palette.image_loader.LoadedImage`: pixels, width, height, channels and pitch. `load` and `loadFromMemory` mirror the old entry points. The differences are that they now take an allocator and return Zig errors instead of using stb.

### Decoding

- Supports every color type and depth: gray 1/2/4/8/16, RGB 8/16, palette 1/2/4/8, gray+alpha 8/16 and RGBA 8/16.
- `tRNS` is supported for gray, RGB and palette images. Adam7 interlacing and all five filters are supported.
- 16-bit samples are reduced to 8 bits by `>> 8`, matching stb_image's 8-bit output.
- `DecodeOptions`:
  - `max_width` and `max_height` default to 16384. `max_pixels` defaults to 2^26.
  - `verify_checksums` defaults to false. When true, it also checks the IDAT CRCs and the zlib Adler-32.
  - CRCs of all non-IDAT chunks are always checked.
- Strictness rules:
  - Signature, IHDR fields, chunk order and lengths are validated.
  - Unknown critical chunks are rejected.
  - Bad PLTE or tRNS sizes, palette indices out of range, and truncated or overlong image data all return errors, as does any bad deflate stream (wrong Huffman tables, distances too far back, and so on).
  - No input can panic, assert or read out of bounds. This holds in ReleaseFast too, because all bounds checks are explicit.
- Fast path:
  - A single IDAT is inflated zero-copy straight into the filtered-row buffer.
  - Rows are unfiltered in place, with SIMD Avg/Paeth for 3 and 4 bytes per pixel.
  - Then one conversion pass to RGBA8.

### Encoding

`EncodeOptions` fields:

- `filter`: `none`, `sub`, `up`, `average`, `paeth`, or `adaptive` (the default; per-row minimum sum of absolute differences).
- `compression`: `store`, `fastest`, `default` or `best`. Everything except `store` uses std `flate.Compress`.
- `interlace`.
- `idat_chunk_size`: defaults to 256 KiB.

## Tests

Run `zig build test-image` from `palette-native/`. It covers:

- Round trips over 15 color-type/depth formats × several sizes (including 1xN and odd widths), with and without tRNS, with and without Adam7, × 6 filter modes × the compression levels. That is more than 1000 encode→decode cases, each checked against an independent reference converter.
- A large RGBA image, and an external fixture produced by Python's zlib.
- IHDR, limit, chunk-order and CRC rejection.
- `verify_checksums` catching a flipped bit in a stored block.
- Truncation of every prefix, plus thousands of random corruptions, which must never crash.
- A `std.testing.fuzz` entry. A normal test run executes it once with an empty input; to fuzz for real, use zig build's `--fuzz` mode. I have not exercised that mode here; the mutation fuzzing was done through the bench's `--fuzz` flag instead.

## Benchmark against stb_image

Run `zig build bench-png -Doptimize=ReleaseFast -- --iters 5 FILE...`. You can also build `zig build png-bench-exe` and run `zig-out/bin/png-bench`.

The bench decodes every file with this codec and with `stbi_load_from_memory(…, 4)` (`palette/vendor/stb_image_impl.c`, built with -O2). It requires byte-identical RGBA output and prints MB/s of output pixels. `--fuzz N` runs mutation fuzzing on the real files.

Results on an i7-11370H, ReleaseFast, with default options. The corpus is 70 files: ImageMagick variants of every format (interlaced, stored, tRNS) and 30 system PNGs, from icons up to 7680x4320 wallpapers.

| | ours | stb_image |
|---|---|---|
| aggregate decode throughput | 959.9 MB/s | 799.2 MB/s (ours is 1.20x) |
| output identical to stb | 70 / 70 files | |
| weakest case: stored (uncompressed) g8 | 2806 MB/s | 4776 MB/s |
| weakest case: 7680x4191 RGB8 wallpaper | 197 MB/s | 223 MB/s |

- With `verify_checksums = true`, decoding is about 25% slower: 689 MB/s against stb's 814 MB/s, measured before the SIMD unfilter.
- Mutation fuzzing on real files (`--fuzz 300`, ReleaseSafe) produced no crashes.
- Encoding a 1600x1000 RGBA screenshot with default options (adaptive filter, default zlib level) takes about 76 ms. A 1280x800 one takes about 50 ms.
