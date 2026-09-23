# Verde Omarchy themes

Omarchy theme folders for Verde's built-in palettes:

| Folder | Theme |
| --- | --- |
| `verde-dark/` | Verde Dark (default dark palette) |
| `verde-light/` | Verde Light (default light palette) |
| `verde-legacy/` | Verde Legacy (the original Verde palette) |
| `verde/` | Older minimal example using legacy `colorN` keys |

Install one by copying its folder to `~/.config/omarchy/themes/<slug>/` and
running `omarchy theme set <slug>`.

Each `colors.toml` holds the Omarchy (Quattro) palette at the top level plus a
`[verde]` section with Verde's 15 desktop UI roles. Verde prefers those roles
when it reads an active Omarchy theme, so the desktop app matches exactly.

`backgrounds/*.png` and `preview.png` are generated from `colors.toml`. After
changing colours, regenerate them from the repository root:

```bash
python3 examples/omarchy/generate-images.py            # all themes
python3 examples/omarchy/generate-images.py verde-dark # one theme
```

The script needs Python 3.11+ and `rsvg-convert` (librsvg); it uses `oxipng`
or `optipng` to shrink the PNGs when either is installed.
