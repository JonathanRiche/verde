#!/usr/bin/env python3
"""Regenerate wallpapers and previews for the Verde Omarchy themes.

Reads each theme's colors.toml (top-level Omarchy keys plus the [verde] UI
roles) and renders, per theme folder:

  backgrounds/1-verde-ribbons.png   3840x2160 flowing ribbons over a soft glow
  backgrounds/2-verde-contours.png  3840x2160 topographic contour lines
  preview.png                       1800x1012 mock desktop (terminal, editor, Verde)

Images are built as SVG and rasterised with rsvg-convert, so the output is
deterministic for a given colors.toml. Usage, from the repository root:

  python3 examples/omarchy/generate-images.py [theme-slug ...]

Requires Python 3.11+ (tomllib) and rsvg-convert (librsvg). Optionally runs
oxipng or optipng when installed to shrink the PNGs.
"""

from __future__ import annotations

import math
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
THEMES = ("verde-dark", "verde-light", "verde-legacy")
WALL_W, WALL_H = 3840, 2160
PREVIEW_W, PREVIEW_H = 1800, 1012
MONO = "CaskaydiaMono Nerd Font, CaskaydiaMono NF, JetBrains Mono, DejaVu Sans Mono, monospace"
SANS = "Inter, Noto Sans, DejaVu Sans, sans-serif"


# ── colour helpers ──────────────────────────────────────────────────────────


def rgb(hex_color: str) -> tuple[int, int, int]:
    value = hex_color.lstrip("#")
    return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)


def hex6(color: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{max(0, min(255, round(c))):02x}" for c in color)


def mix(a: str, b: str, t: float) -> str:
    ca, cb = rgb(a), rgb(b)
    return hex6(tuple(x + (y - x) * t for x, y in zip(ca, cb)))


def fill(color: str) -> str:
    """SVG fill/stroke attributes for #RRGGBB or #RRGGBBAA."""
    value = color.lstrip("#")
    if len(value) == 8:
        return f'fill="#{value[:6]}" fill-opacity="{int(value[6:], 16) / 255:.3f}"'
    return f'fill="#{value}"'


def is_light(theme: dict) -> bool:
    return theme.get("mode") == "light"


def esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── wallpapers ──────────────────────────────────────────────────────────────


def base_gradient(t: dict, w: int, h: int, gid: str) -> str:
    """Diagonal background wash plus two soft glows in the theme's accent."""
    light = is_light(t)
    top = t["lighter_background"] if light else t["darker_background"]
    bottom = t["dark_background"] if light else t["background"]
    glow = t["accent"]
    glow_alt = t["cyan"]
    glow_strength = 0.16 if light else 0.22
    return f"""
  <defs>
    <linearGradient id="{gid}-wash" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{top}"/>
      <stop offset="0.55" stop-color="{t['background']}"/>
      <stop offset="1" stop-color="{bottom}"/>
    </linearGradient>
    <radialGradient id="{gid}-glow" cx="0.78" cy="0.82" r="0.62">
      <stop offset="0" stop-color="{glow}" stop-opacity="{glow_strength}"/>
      <stop offset="0.55" stop-color="{glow}" stop-opacity="{glow_strength * 0.28:.3f}"/>
      <stop offset="1" stop-color="{glow}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="{gid}-glow2" cx="0.12" cy="0.1" r="0.5">
      <stop offset="0" stop-color="{glow_alt}" stop-opacity="{glow_strength * 0.35:.3f}"/>
      <stop offset="1" stop-color="{glow_alt}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{w}" height="{h}" fill="url(#{gid}-wash)"/>
  <rect width="{w}" height="{h}" fill="url(#{gid}-glow)"/>
  <rect width="{w}" height="{h}" fill="url(#{gid}-glow2)"/>"""


def ribbons(t: dict, w: int, h: int) -> str:
    """A fan of smooth cubic curves sweeping from lower left to upper right."""
    light = is_light(t)
    count = 56
    steps = 96
    paths = []
    for i in range(count):
        u = i / (count - 1)
        # Bell-shaped opacity so the band has a bright core and soft edges.
        weight = math.exp(-((u - 0.5) ** 2) / 0.07)
        opacity = (0.04 + 0.27 * weight) * (0.85 if light else 1.0)
        color = mix(t["accent"], t["green"] if light else t["bright_green"], u * 0.7)
        # Each line is a rising sine; shifting phase and amplitude across the
        # fan makes neighbouring lines drift apart and fold together like silk.
        phase = 0.9 + 1.1 * u
        amplitude = h * (0.10 + 0.06 * u)
        offset = h * (0.30 * (u - 0.5))
        points = []
        for s_ in range(steps + 1):
            x = -0.05 * w + 1.1 * w * s_ / steps
            p = x / w
            y = h * (0.80 - 0.52 * p) + offset * (0.7 + 0.5 * p) + amplitude * math.sin(2 * math.pi * 0.85 * p + phase)
            points.append(f"{x:.1f} {y:.1f}")
        d = "M " + " L ".join(points)
        stroke_w = 1.3 + 2.0 * weight
        paths.append(
            f'<path d="{d}" fill="none" stroke="{color}" stroke-opacity="{opacity:.3f}" '
            f'stroke-width="{stroke_w:.2f}" stroke-linejoin="round" stroke-linecap="round"/>'
        )
    return "\n  ".join(paths)


def contour_path(cx: float, cy: float, radius: float, level: int) -> str:
    """Closed, organically wobbling ring built from a few fixed harmonics."""
    steps = 180
    points = []
    for s in range(steps):
        a = 2 * math.pi * s / steps
        wobble = (
            0.075 * math.sin(3 * a + level * 0.21)
            + 0.045 * math.sin(5 * a - level * 0.17 + 1.3)
            + 0.025 * math.sin(8 * a + level * 0.33 + 0.4)
        )
        r = radius * (1 + wobble)
        points.append((cx + r * math.cos(a) * 1.35, cy + r * math.sin(a)))
    head = points[0]
    body = " ".join(f"L {x:.1f} {y:.1f}" for x, y in points[1:])
    return f"M {head[0]:.1f} {head[1]:.1f} {body} Z"


def contours(t: dict, w: int, h: int) -> str:
    light = is_light(t)
    rings = []
    cx, cy = w * 0.74, h * 0.62
    levels = 26
    for level in range(levels):
        radius = 90 + level * 62
        u = level / (levels - 1)
        opacity = (0.34 - 0.26 * u) * (1.25 if light else 1.0)
        color = t["accent"] if level % 5 == 0 else mix(t["muted"], t["accent"], 0.35)
        width = 3.2 if level % 5 == 0 else 1.8
        rings.append(
            f'<path d="{contour_path(cx, cy, radius, level)}" fill="none" stroke="{color}" '
            f'stroke-opacity="{opacity:.3f}" stroke-width="{width}"/>'
        )
    # A second, smaller summit toward the upper left keeps the field balanced.
    for level in range(9):
        radius = 60 + level * 55
        opacity = (0.20 - 0.018 * level) * (1.25 if light else 1.0)
        rings.append(
            f'<path d="{contour_path(w * 0.16, h * 0.2, radius, level + 40)}" fill="none" '
            f'stroke="{mix(t["muted"], t["accent"], 0.25)}" stroke-opacity="{opacity:.3f}" stroke-width="1.6"/>'
        )
    return "\n  ".join(rings)


def wallpaper_svg(t: dict, kind: str, w: int = WALL_W, h: int = WALL_H) -> str:
    body = ribbons(t, w, h) if kind == "ribbons" else contours(t, w, h)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
        f"{base_gradient(t, w, h, kind)}\n  {body}\n</svg>\n"
    )


# ── preview ─────────────────────────────────────────────────────────────────


def text(x: float, y: float, content: str, color: str, size: float = 13, family: str = MONO, weight: str = "normal", anchor: str = "start") -> str:
    return (
        f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
        f'text-anchor="{anchor}" fill="{color}" xml:space="preserve">{esc(content)}</text>'
    )


def spans(x: float, y: float, parts: list[tuple[str, str]], size: float = 13) -> str:
    """One monospace line made of coloured runs."""
    inner = "".join(f'<tspan fill="{color}">{esc(chunk)}</tspan>' for chunk, color in parts)
    return f'<text x="{x}" y="{y}" font-family="{MONO}" font-size="{size}" xml:space="preserve">{inner}</text>'


def window(x: float, y: float, w: float, h: float, bg: str, border: str) -> str:
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{bg}"/>'
        f'<rect x="{x + 1}" y="{y + 1}" width="{w - 2}" height="{h - 2}" fill="none" stroke="{border}" stroke-width="2"/>'
    )


def terminal_pane(t: dict, x: float, y: float, w: float, h: float) -> str:
    fg, dim, accent = t["foreground"], t["dark_foreground"], t["accent"]
    out = [window(x, y, w, h, t["background"], accent)]
    lh = 21
    cx, cy = x + 22, y + 34

    def line(parts: list[tuple[str, str]]) -> None:
        nonlocal cy
        out.append(spans(cx, cy, parts))
        cy += lh

    prompt = [("~/code/verde ", t["blue"]), ("on ", dim), (" master ", t["magenta"]), ("❯ ", accent)]
    line(prompt + [("eza -l --git", fg)])
    rows = [
        ("drwxr-xr-x", "-", "assets/", t["blue"], "  "),
        ("drwxr-xr-x", "-", "examples/", t["blue"], "  "),
        ("drwxr-xr-x", "-", "packages/", t["blue"], "-M"),
        ("drwxr-xr-x", "-", "scripts/", t["blue"], "  "),
        (".rw-r--r--", "4.1k", "AGENTS.md", fg, "  "),
        (".rw-r--r--", "2.2k", "build.zig", t["yellow"], "-M"),
        (".rw-r--r--", "1.1k", "mise.toml", fg, "  "),
        (".rw-r--r--", "9.8k", "README.md", t["orange"], "N "),
    ]
    for perms, size, name, color, git in rows:
        git_color = t["green"] if git.startswith("N") else (t["yellow"] if "M" in git else dim)
        line([(perms, t["green"] if perms.startswith("d") else dim), (f" {size:>5} ", t["yellow"]), (" rtg ", dim), ("22 Sep 14:32 ", t["cyan"]), (f"{git} ", git_color), (name, color)])
    cy += 8
    line(prompt + [("git log --oneline -6", fg)])
    commits = [
        ("d864cda", "HEAD -> master", "Add Verde Dark, Light and Legacy themes"),
        ("a41f0e2", "", "Follow the OS appearance for the Auto theme"),
        ("7be913c", "", "Teach the Omarchy parser Quattro keys"),
        ("5c02d7a", "origin/master", "Settings: theme dropdown lists built-ins"),
        ("19ea4f8", "", "Wallpapers for the Omarchy theme folders"),
        ("0f3d2b1", "", "Keep old theme packages importing"),
    ]
    for sha, ref, msg in commits:
        parts = [(sha + " ", t["yellow"])]
        if ref:
            parts += [("(", dim), (ref, t["cyan"] if "origin" in ref else t["green"]), (") ", dim)]
        parts.append((msg, fg))
        line(parts)
    cy += 8
    line(prompt + [("zig build test --summary new", fg)])
    line([("Build Summary: ", fg), ("7/7 steps succeeded", t["green"]), ("; ", dim), ("412/412 tests passed", t["green"])])
    line([("warning: ", t["yellow"]), ("theme preview generated from colors.toml", fg)])
    line([("error: ", t["red"]), ("none", fg)])
    cy += 8
    line(prompt + [("verde-colors", fg)])
    # Palette swatches: normal row then bright row, like a fetch tool.
    names = ["red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown"]
    bright = ["bright_red", "bright_yellow", "orange", "bright_green", "bright_cyan", "bright_blue", "bright_magenta", "brown"]
    sw = (w - 44) / len(names)
    for row, keys in enumerate((names, bright)):
        for i, key in enumerate(keys):
            color = t[key] if row == 0 or key not in ("orange", "brown") else mix(t[key], t["bright_foreground"], 0.2)
            out.append(f'<rect x="{cx + i * sw:.1f}" y="{cy - 12 + row * 40}" width="{sw - 6:.1f}" height="32" {fill(color)}/>')
    cy += 90
    line(prompt + [("█", fg)])
    return "\n".join(out)


def monitor_pane(t: dict, x: float, y: float, w: float, h: float) -> str:
    """A btop-style CPU graph and memory bars in the palette colours."""
    fg, dim = t["foreground"], t["dark_foreground"]
    out = [window(x, y, w, h, t["background"], t["muted"])]
    out.append(text(x + 18, y + 26, "cpu", t["accent"], 12.5, weight="bold"))
    out.append(text(x + w - 18, y + 26, "up 3d 04:12  load 0.42 0.51 0.48", dim, 12, anchor="end"))
    gx, gy, gw, gh = x + 18, y + 40, w * 0.62, h - 62
    columns = 64
    bw = gw / columns
    for i in range(columns):
        level = 0.18 + 0.32 * (0.5 + 0.5 * math.sin(i * 0.37)) + 0.22 * (0.5 + 0.5 * math.sin(i * 1.13 + 0.8))
        bh = gh * min(level, 0.95)
        color = t["green"] if level < 0.5 else (t["yellow"] if level < 0.7 else t["red"])
        out.append(f'<rect x="{gx + i * bw:.1f}" y="{gy + gh - bh:.1f}" width="{bw - 2:.1f}" height="{bh:.1f}" fill="{color}" fill-opacity="0.85"/>')
    mx = gx + gw + 24
    mw = x + w - 18 - mx
    my = y + 50
    for label, value, color in (("mem", 0.46, t["cyan"]), ("swap", 0.08, t["magenta"]), ("disk", 0.63, t["blue"]), ("net", 0.27, t["accent"])):
        out.append(text(mx, my, label, fg, 12))
        out.append(f'<rect x="{mx + 44}" y="{my - 10}" width="{mw - 44:.1f}" height="10" fill="{t["lighter_background"]}"/>')
        out.append(f'<rect x="{mx + 44}" y="{my - 10}" width="{(mw - 44) * value:.1f}" height="10" fill="{color}"/>')
        my += 30
    return "\n".join(out)


def editor_pane(t: dict, x: float, y: float, w: float, h: float) -> str:
    fg, dim = t["foreground"], t["dark_foreground"]
    out = [window(x, y, w, h, t["background"], t["muted"])]
    # Tab line.
    out.append(f'<rect x="{x + 2}" y="{y + 2}" width="{w - 4}" height="26" fill="{t["dark_background"]}"/>')
    out.append(f'<rect x="{x + 2}" y="{y + 2}" width="150" height="26" fill="{t["background"]}"/>')
    out.append(text(x + 16, y + 20, "theme.zig", fg, 12))
    out.append(text(x + 170, y + 20, "config.zig", dim, 12))
    kw, fn_, ty, st, cm, num = t["magenta"], t["blue"], t["yellow"], t["green"], dim, t["orange"]
    code = [
        [("pub const ", kw), ("ThemeSource", ty), (" = ", fg), ("enum", kw), (" {", fg)],
        [("    auto", fg), (",", dim)],
        [("    verde_dark", fg), (",", dim)],
        [("    verde_light", fg), (",", dim)],
        [("    verde_legacy", fg), (",", dim)],
        [("    omarchy", fg), (",", dim)],
        [("};", fg)],
        [("", fg)],
        [("/// Auto follows the OS light/dark appearance.", cm)],
        [("pub fn ", kw), ("autoColors", fn_), ("(appearance: ", fg), ("Appearance", ty), (") ", fg), ("ThemeColors", ty), (" {", fg)],
        [("    return switch ", kw), ("(appearance) {", fg)],
        [("        .dark => ", fg), ("verde_dark_colors", fn_), (",", dim)],
        [("        .light => ", fg), ("verde_light_colors", fn_), (",", dim)],
        [("    };", fg)],
        [("}", fg)],
        [("", fg)],
        [("const ", kw), ("accent_dim", fg), (" = ", fg), ("hexColor", fn_), ("(", fg), ('"#4FD18B29"', st), (");", fg)],
        [("const ", kw), ("quota", fg), (" = ", fg), ("10_000", num), (";", fg)],
    ]
    ly = y + 52
    for number, parts in enumerate(code, start=1):
        if ly > y + h - 40:
            break
        if number == 11:
            out.append(f'<rect x="{x + 2}" y="{ly - 15}" width="{w - 4}" height="20" fill="{t["selection"]}" fill-opacity="0.55"/>')
        out.append(text(x + 40, ly, str(number), t["muted"] if number != 11 else t["accent"], 12, anchor="end"))
        out.append(spans(x + 56, ly, parts, 12.5))
        ly += 20
    # Status line.
    sy = y + h - 28
    out.append(f'<rect x="{x + 2}" y="{sy}" width="{w - 4}" height="26" fill="{t["lighter_background"]}"/>')
    out.append(f'<rect x="{x + 2}" y="{sy}" width="78" height="26" fill="{t["accent"]}"/>')
    out.append(text(x + 41, sy + 18, "NORMAL", t["background"], 12, weight="bold", anchor="middle"))
    out.append(text(x + 94, sy + 18, " master  ui/theme.zig", fg, 12))
    out.append(text(x + w - 16, sy + 18, "zig  11:12  42%", dim, 12, anchor="end"))
    return "\n".join(out)


def verde_pane(t: dict, x: float, y: float, w: float, h: float) -> str:
    """A small mock of the Verde desktop app painted with the [verde] roles."""
    v = t["verde"]
    out = [window(x, y, w, h, v["background"], t["muted"])]
    side_w = 230
    out.append(f'<rect x="{x + 2}" y="{y + 2}" width="{side_w}" height="{h - 4}" fill="{v["panel"]}"/>')
    out.append(f'<rect x="{x + 2 + side_w}" y="{y + 2}" width="1" height="{h - 4}" fill="{v["border_muted"]}"/>')
    out.append(text(x + 22, y + 34, "verde", v["accent"], 17, SANS, "bold"))
    out.append(text(x + 22, y + 66, "WORKSPACES", v["text_subtle"], 10.5, SANS, "bold"))
    items = [("verde", True, "3"), ("verde-cloud", False, ""), ("website", False, "1"), ("dotfiles", False, "")]
    iy = y + 80
    for name, active, badge in items:
        if active:
            out.append(f'<rect x="{x + 12}" y="{iy}" width="{side_w - 20}" height="30" rx="6" {fill(v["accent_dim"])}/>')
            out.append(f'<rect x="{x + 12}" y="{iy + 6}" width="3" height="18" rx="1.5" fill="{v["accent"]}"/>')
        out.append(text(x + 26, iy + 20, name, v["text"] if active else v["text_muted"], 13, SANS))
        if badge:
            out.append(f'<circle cx="{x + side_w - 26}" cy="{iy + 15}" r="9" fill="{v["panel_muted"]}"/>')
            out.append(text(x + side_w - 26, iy + 19, badge, v["text_muted"], 10.5, SANS, anchor="middle"))
        iy += 36
    out.append(text(x + 22, iy + 20, "CHATS", v["text_subtle"], 10.5, SANS, "bold"))
    for label, dot in (("Ship three Verde themes", v["accent"]), ("Omarchy Quattro parser", v["warning"]), ("Auto follows the OS", v["text_subtle"])):
        iy += 32
        out.append(f'<circle cx="{x + 28}" cy="{iy + 15}" r="4" fill="{dot}"/>')
        out.append(text(x + 42, iy + 19, label, v["text_muted"], 12.5, SANS))

    mx = x + side_w + 24
    mw = w - side_w - 48
    # User bubble.
    by = y + 26
    out.append(f'<rect x="{mx + mw - 360}" y="{by}" width="360" height="58" rx="12" fill="{v["panel_alt"]}"/>')
    out.append(text(mx + mw - 344, by + 24, "Add a light theme and make Auto", v["text"], 13, SANS))
    out.append(text(mx + mw - 344, by + 44, "follow the system appearance.", v["text"], 13, SANS))
    # Assistant reply.
    ay = by + 92
    out.append(text(mx, ay, "Done. Auto now tracks the OS setting live:", v["text"], 13, SANS))
    out.append(text(mx, ay + 22, "Verde Dark at night, Verde Light by day.", v["text_muted"], 13, SANS))
    # Diff card.
    dy = ay + 40
    out.append(f'<rect x="{mx}" y="{dy}" width="{mw}" height="112" rx="8" fill="{v["panel"]}" stroke="{v["border_muted"]}"/>')
    out.append(text(mx + 14, dy + 22, "ui/theme.zig", v["text_subtle"], 11.5))
    out.append(text(mx + mw - 14, dy + 22, "+2 −1", v["text_subtle"], 11.5, anchor="end"))
    rows = [("-", "    .default => {},", v["diff_remove"]), ("+", "    .auto => autoColors(system_appearance),", v["diff_add"]), ("+", "    .verde_light => verde_light_colors,", v["diff_add"])]
    ry = dy + 34
    for sign, code, color in rows:
        out.append(f'<rect x="{mx + 1}" y="{ry}" width="{mw - 2}" height="22" fill="{color}" fill-opacity="0.12"/>')
        out.append(spans(mx + 14, ry + 16, [(sign + " ", color), (code, v["text"])], 12))
        ry += 24
    # Approval chip in the warning colour.
    wy = dy + 128
    out.append(f'<rect x="{mx}" y="{wy}" width="{mw}" height="40" rx="8" fill="{v["warning"]}" fill-opacity="0.10" stroke="{v["warning"]}" stroke-opacity="0.45"/>')
    out.append(text(mx + 14, wy + 25, "Approve: run zig build test?", v["warning"], 12.5, SANS, "bold"))
    out.append(f'<rect x="{mx + mw - 96}" y="{wy + 8}" width="84" height="24" rx="6" fill="{v["accent"]}"/>')
    accent_fg = v["background"] if not is_light(t) else "#FFFFFF"
    out.append(text(mx + mw - 54, wy + 25, "Approve", accent_fg, 12, SANS, "bold", "middle"))
    # Composer.
    cy = y + h - 70
    out.append(f'<rect x="{mx}" y="{cy}" width="{mw}" height="50" rx="10" fill="{v["panel"]}" stroke="{v["border"]}" stroke-width="1.5"/>')
    out.append(text(mx + 16, cy + 30, "Ask Verde anything…", v["text_subtle"], 13, SANS))
    out.append(f'<rect x="{mx + mw - 88}" y="{cy + 13}" width="1.5" height="24" fill="{v["accent"]}"/>')
    out.append(text(mx + mw - 16, cy + 30, "claude", v["text_subtle"], 11.5, SANS, anchor="end"))
    return "\n".join(out)


def preview_svg(t: dict, slug: str) -> str:
    w, h = PREVIEW_W, PREVIEW_H
    scale = w / WALL_W
    bar_h = 26
    gap = 10
    fg, dim = t["foreground"], t["dark_foreground"]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">']
    parts.append(f'<g transform="scale({scale:.6f})">{base_gradient(t, WALL_W, WALL_H, "pv")}\n{ribbons(t, WALL_W, WALL_H)}</g>')
    # Top bar.
    parts.append(f'<rect width="{w}" height="{bar_h}" fill="{t["background"]}"/>')
    for i, label in enumerate(["1", "2", "3", "4", "5"]):
        color = t["accent"] if i == 0 else dim
        parts.append(text(18 + i * 22, 18, label, color, 13, weight="bold" if i == 0 else "normal"))
    parts.append(text(w / 2, 18, "Tuesday 14:32", fg, 13, anchor="middle"))
    parts.append(text(w - 16, 18, slug.replace("-", " ") + "  󰂯  󰖩  󰕾", dim, 12.5, anchor="end"))
    # Windows: terminal left, editor top right, Verde bottom right.
    left_w = 860
    top = bar_h + gap
    right_x = gap + left_w + gap
    right_w = w - right_x - gap
    avail = h - top - gap
    top_h = 420
    monitor_h = 250
    parts.append(terminal_pane(t, gap, top, left_w, avail - monitor_h - gap))
    parts.append(monitor_pane(t, gap, top + avail - monitor_h, left_w, monitor_h))
    parts.append(editor_pane(t, right_x, top, right_w, top_h))
    parts.append(verde_pane(t, right_x, top + top_h + gap, right_w, avail - top_h - gap))
    parts.append("</svg>\n")
    return "\n".join(parts)


# ── driver ──────────────────────────────────────────────────────────────────


def render(svg: str, out_path: Path, width: int, height: int) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as handle:
        handle.write(svg)
        svg_path = Path(handle.name)
    try:
        subprocess.run(
            ["rsvg-convert", "--width", str(width), "--height", str(height), "--format", "png", "--output", str(out_path), str(svg_path)],
            check=True,
        )
    finally:
        svg_path.unlink(missing_ok=True)
    optimise(out_path)


def optimise(path: Path) -> None:
    if shutil.which("oxipng"):
        subprocess.run(["oxipng", "--quiet", "-o", "3", "--strip", "safe", str(path)], check=False)
    elif shutil.which("optipng"):
        subprocess.run(["optipng", "-quiet", "-o2", str(path)], check=False)


def load_theme(slug: str) -> dict:
    with open(HERE / slug / "colors.toml", "rb") as handle:
        theme = tomllib.load(handle)
    missing = [key for key in ("accent", "background", "foreground", "muted", "verde") if key not in theme]
    if missing:
        raise SystemExit(f"{slug}/colors.toml is missing {', '.join(missing)}")
    return theme


def main(argv: list[str]) -> int:
    if not shutil.which("rsvg-convert"):
        print("rsvg-convert (librsvg) is required", file=sys.stderr)
        return 1
    slugs = argv or list(THEMES)
    for slug in slugs:
        theme = load_theme(slug)
        folder = HERE / slug
        render(wallpaper_svg(theme, "ribbons"), folder / "backgrounds" / "1-verde-ribbons.png", WALL_W, WALL_H)
        render(wallpaper_svg(theme, "contours"), folder / "backgrounds" / "2-verde-contours.png", WALL_W, WALL_H)
        render(preview_svg(theme, slug), folder / "preview.png", PREVIEW_W, PREVIEW_H)
        print(f"rendered {slug}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
