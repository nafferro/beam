"""Builds the Beam app icon (light, dark and tinted) as SVG.

Concept: a headlamp lens throwing a wide beam, with three arcs inside the beam
for the reactive lighting (the lamp adapts to what it sees). No Petzl artwork.

Usage: python3 make_icon.py <out_dir>   then render each SVG to 1024x1024 PNG.
"""
import math
import sys
from pathlib import Path

S = 1024
LX, LY = 300, 600          # lens centre
R_OUT, R_IN = 150, 92      # lens ring / core radius
SPREAD = 30                # beam half-angle, degrees
TILT = -12                 # beam points slightly up


def beam_polygon():
    a1 = math.radians(TILT - SPREAD)
    a2 = math.radians(TILT + SPREAD)
    far = 1100
    # Start on the lens ring so the beam leaves from its edge.
    p1 = (LX + R_OUT * 0.8 * math.cos(a1), LY + R_OUT * 0.8 * math.sin(a1))
    p2 = (LX + far * math.cos(a1), LY + far * math.sin(a1))
    p3 = (LX + far * math.cos(a2), LY + far * math.sin(a2))
    p4 = (LX + R_OUT * 0.8 * math.cos(a2), LY + R_OUT * 0.8 * math.sin(a2))
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in (p1, p2, p3, p4))


def arcs():
    out = []
    for i, r in enumerate((300, 430, 560)):
        a1 = math.radians(TILT - SPREAD + 6)
        a2 = math.radians(TILT + SPREAD - 6)
        x1, y1 = LX + r * math.cos(a1), LY + r * math.sin(a1)
        x2, y2 = LX + r * math.cos(a2), LY + r * math.sin(a2)
        op = (0.95, 0.75, 0.55)[i]
        out.append(f'<path d="M{x1:.1f},{y1:.1f} A{r},{r} 0 0 1 {x2:.1f},{y2:.1f}" '
                   f'fill="none" stroke="var(--arc)" stroke-opacity="{op}" stroke-width="34" stroke-linecap="round"/>')
    return "\n  ".join(out)


def svg(bg_top, bg_bottom, ink, beam_op, core, arc, transparent_bg=False):
    bg = "" if transparent_bg else f'<rect width="{S}" height="{S}" fill="url(#bg)"/>'
    body = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{bg_top}"/><stop offset="1" stop-color="{bg_bottom}"/>
    </linearGradient>
    <linearGradient id="beam" gradientUnits="userSpaceOnUse" x1="{LX}" y1="{LY}" x2="{S}" y2="{LY - 230}">
      <stop offset="0" stop-color="{ink}" stop-opacity="{beam_op}"/>
      <stop offset="1" stop-color="{ink}" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="core">
      <stop offset="0" stop-color="{core[0]}"/><stop offset="1" stop-color="{core[1]}"/>
    </radialGradient>
  </defs>
  {bg}
  <polygon points="{beam_polygon()}" fill="url(#beam)"/>
  {arcs().replace('var(--arc)', arc)}
  <circle cx="{LX}" cy="{LY}" r="{R_OUT}" fill="{ink}"/>
  <circle cx="{LX}" cy="{LY}" r="{R_IN}" fill="url(#core)"/>
</svg>
"""
    return body


VARIANTS = {
    # Orange background, white lamp.
    "icon-light": svg("#FF5A2A", "#E8380C", "#FFFFFF", 0.55, ("#FFFFFF", "#FFD2C2"), "#FFFFFF"),
    # Dark background, orange lamp (matches the dark-mode accent #FF6138).
    "icon-dark": svg("#1C1C1E", "#0B0B0C", "#FF6138", 0.50, ("#FFE3D8", "#FF6138"), "#FF6138"),
    # Tinted: grayscale on black, iOS applies the user's tint.
    "icon-tinted": svg("#000000", "#000000", "#FFFFFF", 0.45, ("#FFFFFF", "#BDBDBD"), "#FFFFFF"),
}

if __name__ == "__main__":
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, body in VARIANTS.items():
        (out / f"{name}.svg").write_text(body)
        print(out / f"{name}.svg")
