#!/usr/bin/env python3
# plot_device.py — device-view floorplan of the routed KV260 PL IP, colored by
# RTL hierarchy, from Vivado's placement dump. Each placed SLICE cell is drawn
# at its exact (SLICE_X, SLICE_Y) site; color = the top-level module it belongs
# to. Text is rendered with Liberation Sans (the open, metric-compatible Arial
# substitute — Arial itself is not shipped on Linux) via Pillow.
#
#   python3 fpga/kv260/plot_device.py \
#       fpga/reports/kv260_placement.txt fpga/kv260/device_view.png
import sys, re
from PIL import Image, ImageDraw, ImageFont

# Arial-equivalent (metric-compatible) faces, with fallbacks.
def _font(size, bold=False):
    names = (["/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"] if bold
             else ["/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"])
    names += ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    for n in names:
        try: return ImageFont.truetype(n, size)
        except OSError: pass
    return ImageFont.load_default()

# top-level module -> (legend label, RGB). Order drives the legend.
PALETTE = [
    ("raster",       "raster — edge + 3× SRT div", (220, 50, 47)),
    ("tmu",          "tmu — texture + 2× SRT div", (40, 160, 70)),
    ("regfile",      "voodoo_regfile + fog table",           (140, 90, 50)),
    ("host_if",      "host_if (64-deep cmd FIFO)",           (150, 150, 30)),
    ("cmd_dispatch", "cmd_dispatch",                          (30, 170, 170)),
    ("pixel_pipe",   "pixel_pipe",                            (40, 100, 220)),
    ("slave",        "axi_voodoo_slave (AXI host)",          (150, 60, 200)),
    ("fbddr",        "fb_ddr_adapter (AXI→DDR4)",        (240, 140, 20)),
    ("lfb_unit",     "lfb_unit",                              (200, 170, 20)),
    ("fastfill",     "fastfill",                              (220, 60, 170)),
    ("tex_dl",       "tex_dl",                                (90, 110, 150)),
    ("fb_arb",       "fb_arb (tag FIFO)",                     (40, 200, 220)),
    ("other",        "other / glue",                          (150, 150, 150)),
]
COLOR = {k: c for k, _, c in PALETTE}
INK = (40, 40, 40)

def bucket(path):
    if path.startswith("u_slave"):
        return "slave"
    m = re.match(r"u_core/u_([a-z0-9_]+?)(?:/|\[|$)", path)
    if not m:
        return "other"
    name = m.group(1)
    if name.startswith("fbddr"): return "fbddr"
    if name.startswith("tmu"):   return "tmu"
    for k in ("raster","pixel_pipe","cmd_dispatch","lfb_unit","fastfill",
              "regfile","host_if","fb_arb","tex_dl"):
        if name == k or name.startswith(k):
            return k
    return "other"

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "fpga/reports/kv260_placement.txt"
    out = sys.argv[2] if len(sys.argv) > 2 else "fpga/kv260/device_view.png"
    slre = re.compile(r"^SLICE_X(\d+)Y(\d+)")
    cells, counts = [], {}
    for line in open(src):
        if "\t" not in line: continue
        loc, name = line.rstrip("\n").split("\t", 1)
        m = slre.match(loc)
        if not m: continue
        x, y, b = int(m.group(1)), int(m.group(2)), bucket(name)
        cells.append((x, y, b)); counts[b] = counts.get(b, 0) + 1
    if not cells:
        print("no SLICE cells found", file=sys.stderr); sys.exit(1)

    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    xr, yr = x1-x0+1, y1-y0+1
    scale = 2 * max(2, min(330 // xr, 560 // yr))  # 2x larger plot (font unchanged)

    f_title = _font(15, bold=True)
    f_leg   = _font(13)
    legend  = [p for p in PALETTE if p[0] in counts]
    labels  = [f"{lbl}  ({counts[k]:,})" for k, lbl, _ in legend]

    mL, mT, gap, pad = 14, 30, 22, 14
    plotw, ploth = xr*scale, yr*scale
    sw, lh = 15, 22                                # swatch size, legend line height
    tmp = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    legtextw = max(tmp.textlength(s, font=f_leg) for s in labels)
    legendw  = sw + 8 + int(legtextw)
    W = mL + plotw + gap + legendw + pad
    H = max(mT + ploth, mT + len(legend)*lh) + pad

    img = Image.new("RGB", (W, H), (252, 252, 252))
    d = ImageDraw.Draw(img)
    d.text((mL, 8), "KV260 PL floorplan — color = RTL hierarchy", font=f_title, fill=INK)

    # plot background, then cells (Y flipped: SLICE Y0 at the bottom)
    d.rectangle([mL, mT, mL+plotw-1, mT+ploth-1], fill=(243, 243, 246))
    msz = max(1, scale-1)
    for x, y, b in cells:
        px = mL + (x-x0)*scale
        py = mT + (y1-y)*scale
        d.rectangle([px, py, px+msz-1, py+msz-1], fill=COLOR[b])

    # legend: swatch + Liberation Sans label
    lx = mL + plotw + gap
    ly = mT
    for (k, _, rgb), text in zip(legend, labels):
        d.rectangle([lx, ly, lx+sw-1, ly+sw-1], fill=rgb, outline=INK)
        d.text((lx+sw+8, ly+1), text, font=f_leg, fill=INK)
        ly += lh

    img.save(out)
    print(f"wrote {out}  ({W}x{H}px, {len(cells)} SLICE cells, {scale}px/site)")
    for k, lbl, rgb in legend:
        print(f"  rgb{rgb}  {lbl:30s} {counts[k]:6d}")

if __name__ == "__main__":
    main()
