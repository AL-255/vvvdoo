#!/usr/bin/env python3
# plot_device.py — render a device-view floorplan of the routed KV260 PL IP,
# colored by RTL hierarchy, from Vivado's placement dump. Pure stdlib (zlib) —
# no matplotlib/PIL. Each placed SLICE cell is drawn at its exact (SLICE_X,
# SLICE_Y) site; color = the top-level module it belongs to.
#
#   python3 fpga/kv260/plot_device.py \
#       fpga/reports/kv260_placement.txt fpga/kv260/device_view.png
import sys, re, zlib, struct

# top-level module -> (label, RGB). Order also drives the on-image legend.
PALETTE = [
    ("raster",         "raster (edge/coverage)",   (220, 50, 47)),
    ("tmu",            "tmu (+ SRT divider)",       (40, 160, 70)),
    ("pixel_pipe",     "pixel_pipe",                (40, 100, 220)),
    ("fbddr",          "fb_ddr_adapter (AXI->DDR)", (240, 140, 20)),
    ("cmd_dispatch",   "cmd_dispatch",              (30, 170, 170)),
    ("lfb_unit",       "lfb_unit",                  (200, 170, 20)),
    ("fastfill",       "fastfill",                  (220, 60, 170)),
    ("regfile",        "voodoo_regfile",            (140, 90, 50)),
    ("host_if",        "host_if (cmd FIFO)",        (130, 150, 40)),
    ("fb_arb",         "fb_arb (tag FIFO)",         (40, 200, 220)),
    ("tex_dl",         "tex_dl",                    (110, 120, 140)),
    ("slave",          "axi_voodoo_slave",          (150, 60, 200)),
    ("other",          "other / glue",              (150, 150, 150)),
]
COLOR = {k: c for k, _, c in PALETTE}
BG = (252, 252, 252)
GRID = (228, 228, 228)

def bucket(path):
    # OOC top = voodoo_pl_top; leaf paths look like 'u_core/u_raster/...' or 'u_slave/...'
    if path.startswith("u_slave"):
        return "slave"
    m = re.match(r"u_core/u_([a-z0-9_]+?)(?:/|\[|$)", path)
    if not m:
        return "other"
    name = m.group(1)
    if name.startswith("fbddr"):  return "fbddr"
    if name.startswith("tmu"):    return "tmu"
    for k in ("raster","pixel_pipe","cmd_dispatch","lfb_unit","fastfill",
              "regfile","host_if","fb_arb","tex_dl"):
        if name == k or name.startswith(k):
            return k
    return "other"

def write_png(path, w, h, px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)                      # filter type 0 (None) per scanline
        raw += px[y*w*3:(y+1)*w*3]
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ+data) & 0xffffffff))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "fpga/reports/kv260_placement.txt"
    out = sys.argv[2] if len(sys.argv) > 2 else "fpga/kv260/device_view.png"
    sl = re.compile(r"^SLICE_X(\d+)Y(\d+)")
    cells, counts = [], {}
    for line in open(src):
        if "\t" not in line: continue
        loc, name = line.rstrip("\n").split("\t", 1)
        m = sl.match(loc)
        if not m: continue                 # SLICE logic only (exact device grid)
        x, y = int(m.group(1)), int(m.group(2))
        b = bucket(name)
        cells.append((x, y, b))
        counts[b] = counts.get(b, 0) + 1
    if not cells:
        print("no SLICE cells found", file=sys.stderr); sys.exit(1)

    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    xr, yr = x1 - x0 + 1, y1 - y0 + 1
    scale = max(3, min(1000 // xr, 1500 // yr))   # px per SLICE site, aspect-true
    mL, mT, mR, mB = 20, 20, 360, 24             # margins (legend on the right)
    plotw, ploth = xr*scale, yr*scale
    W, H = plotw + mL + mR, ploth + mT + mB
    px = bytearray()
    for _ in range(W*H): px += bytes(BG)

    def put(ix, iy, rgb):
        if 0 <= ix < W and 0 <= iy < H:
            o = (iy*W + ix)*3; px[o:o+3] = bytes(rgb)
    def rect(ix, iy, w, h, rgb):
        for dy in range(h):
            for dx in range(w):
                put(ix+dx, iy+dy, rgb)

    # faint plot-area background so empty fabric reads as "device"
    rect(mL, mT, plotw, ploth, (244, 244, 246))
    # cells (Y flipped: SLICE Y0 at the bottom, like the Vivado device view)
    msz = 1 if scale <= 3 else scale-1
    for x, y, b in cells:
        ix = mL + (x - x0)*scale
        iy = mT + (y1 - y)*scale
        rect(ix, iy, msz, msz, COLOR.get(b, COLOR["other"]))

    # legend (color swatches + a thin bar per module, ordered, only those present)
    ly = mT + 8
    sw = 26
    for key, label, rgb in PALETTE:
        if key not in counts: continue
        lx = mL + plotw + 24
        rect(lx, ly, sw, sw, rgb)
        rect(lx, ly, sw, 1, (0,0,0)); rect(lx, ly+sw-1, sw, 1, (0,0,0))
        rect(lx, ly, 1, sw, (0,0,0)); rect(lx+sw-1, ly, 1, sw, (0,0,0))
        ly += sw + 14

    write_png(out, W, H, px)
    tot = len(cells)
    print(f"wrote {out}  ({W}x{H}px, {tot} SLICE cells, scale {scale}px/site)")
    print("legend (top->bottom) and SLICE-cell counts:")
    for key, label, rgb in PALETTE:
        if key in counts:
            print(f"  rgb{rgb}  {label:28s} {counts[key]:6d}")

if __name__ == "__main__":
    main()
