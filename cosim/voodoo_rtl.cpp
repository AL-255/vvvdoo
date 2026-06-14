// voodoo_rtl.cpp — LIVE RTL co-simulation backend for the QEMU Voodoo device.
//
// Implements the VoodooRendererOps boundary (voodoo_render.h) on top of a
// Verilated Vvoodoo_top instance (the actual hardware model). The QEMU device
// (voodoo.c) routes every BAR access through these ops exactly as it does for
// the software backend (voodoo_soft.c); selecting this backend renders the
// guest's command stream through the gate-level pipeline instead of software.
//
// The Verilated host-port handshake (bar_write/bar_read/tick/reset/scanout
// from fb_ram via the scan_* ports) is the same protocol the standalone
// cosim/cosim_replay.cpp harness uses against a captured .vvt trace; here it
// is driven live from QEMU's thread.
//
// Backend factory (C linkage): VoodooRenderer *voodoo_rtl_create(void);

#include "verilated.h"
#include "Vvoodoo_top.h"
#include "Vvoodoo_top___024root.h"

extern "C" {
#include "voodoo_render.h"
}

#include <cstring>
#include <cstdint>

// ---- fb_ram / tex_ram geometry (matches the RTL: voodoo_pkg FB_AW=21) ----
static const uint32_t FB_WORDS  = (4u << 20) / 2u;   // 4 MiB of 16-bit words
static const uint32_t TEX_WORDS = (2u << 20) / 2u;   // 2 MiB of 16-bit words

// ---- per-renderer RTL state hung off vr->priv -----------------------------
struct RtlPriv {
    VerilatedContext ctx;
    Vvoodoo_top      top{&ctx};
    uint64_t         cyc = 0;
    bool             dirty = false;   // a swapbufferCMD since the last take_dirty

    void tick() {
        top.clk = 1; top.eval();
        top.clk = 0; top.eval();
        cyc++;
    }

    void reset() {
        auto *r = top.rootp;
        for (uint32_t i = 0; i < FB_WORDS; i++)
            r->voodoo_top__DOT__u_fb_ram__DOT__mem[i] = 0;
        for (uint32_t i = 0; i < TEX_WORDS; i++)
            r->voodoo_top__DOT__u_tex_ram__DOT__mem[i] = 0;
        top.clk = 0; top.rst_n = 0;
        top.host_wr_valid = 0; top.host_rd_valid = 0;
        top.host_wr_addr = 0; top.host_wr_data = 0; top.host_wr_be = 0;
        top.host_rd_addr = 0; top.init_enable = 0;
        top.eval();
        for (int i = 0; i < 8; i++) tick();
        top.rst_n = 1;
        for (int i = 0; i < 4; i++) tick();
    }

    // RAW BAR write — addr is a byte offset into the 16 MB BAR, exactly what
    // the RTL host_if decodes. data/mask are a 32-bit dword + byte mask.
    void bar_write(uint32_t addr, uint32_t data, uint32_t mask) {
        uint8_t be = 0;
        for (int b = 0; b < 4; b++)
            if ((mask >> (8 * b)) & 0xffu) be |= (uint8_t)(1u << b);
        top.host_wr_valid = 1;
        top.host_wr_addr = (addr >> 2) & 0x3fffffu;
        top.host_wr_data = data; top.host_wr_be = be;
        for (;;) { top.eval(); bool acc = top.host_wr_ready; tick(); if (acc) break; }
        top.host_wr_valid = 0;
    }

    uint32_t bar_read(uint32_t addr) {
        top.host_rd_valid = 1;
        top.host_rd_addr = (addr >> 2) & 0x3fffffu;
        for (;;) { top.eval(); bool acc = top.host_rd_ready; tick(); if (acc) break; }
        top.host_rd_valid = 0;
        for (;;) {
            if (top.host_rd_resp_valid) { uint32_t v = top.host_rd_data; tick(); return v; }
            tick();
        }
    }

    // settle the pipeline: let any in-flight engine finish before sampling
    // fb_ram / scan_* ports.
    void drain() {
        tick(); tick();
        while (top.busy) tick();
        for (int i = 0; i < 8; i++) tick();
    }

    uint16_t fb(uint32_t word) {
        return top.rootp->voodoo_top__DOT__u_fb_ram__DOT__mem[word & (FB_WORDS - 1)];
    }
};

#define PRIV(vr) ((RtlPriv *)(vr)->priv)

// ---- 565 -> 888 (matches cosim_replay from565 / voodoo_soft from565) -------
static inline void from565(uint16_t p, int *r, int *g, int *b) {
    int rr = (p >> 11) & 0x1f, gg = (p >> 5) & 0x3f, bb = p & 0x1f;
    *r = (rr << 3) | (rr >> 2);
    *g = (gg << 2) | (gg >> 4);
    *b = (bb << 3) | (bb >> 2);
}

// Refresh the device-visible display geometry from the RTL scan_* ports so
// voodoo.c's voodoo_refresh_surface (which reads vr->rowpixels) and get_dims
// stay in sync with what the hardware computed from the fbiInit/videoDimensions
// registers.
static void rtl_sync_dims(VoodooRenderer *vr) {
    RtlPriv *p = PRIV(vr);
    int w  = p->top.scan_width;
    int h  = p->top.scan_height;
    int rp = (int)p->top.scan_rowpixels;
    if (w > 0)  vr->width  = w;
    if (h > 0)  vr->height = h;
    if (rp > 0) vr->rowpixels = (uint32_t)rp;
}

// ====================================================================
//  VoodooRendererOps
// ====================================================================

static int rtl_init(VoodooRenderer *vr) {
    RtlPriv *p = new RtlPriv();
    if (!p) return -1;
    vr->priv = p;
    p->reset();
    rtl_sync_dims(vr);
    return 0;
}

static void rtl_fini(VoodooRenderer *vr) {
    delete PRIV(vr);
    vr->priv = NULL;
}

// voodoo.c has ALREADY applied register swizzle + alias before calling us; it
// passes the final (regnum, chipmask, data). Reconstruct a RAW BAR address the
// RTL decodes to the SAME regnum with no further swizzle/alias: address bits 18
// (swizzle) and 19 (alias) are both clear here, so the RTL decode is a
// pass-through regardless of fbiInit state.
static void rtl_reg_write(VoodooRenderer *vr, uint32_t regnum,
                          uint32_t chipmask, uint32_t data) {
    RtlPriv *p = PRIV(vr);
    regnum &= 0xff;
    uint32_t addr = (((chipmask & 0xf) << 8) | regnum) << 2;
    p->bar_write(addr, data, 0xffffffff);

    // shadow regs[] so voodoo.c's pre-decode (reads regs[fbiInit0]/[fbiInit3])
    // continues to see the values the guest programmed.
    vr->regs[regnum] = data;

    // a buffer swap is the frame boundary -> mark dirty for take_dirty()
    if (regnum == REG_swapbufferCMD) {
        p->dirty = true;
        if (getenv("VOODOO_RTL_DBG"))
            fprintf(stderr, "voodoo-rtl: frame swapped at cycle %llu\n",
                    (unsigned long long)p->cyc);
    }

    // keep display geometry in sync after register state changes
    rtl_sync_dims(vr);
}

static uint32_t rtl_reg_read(VoodooRenderer *vr, uint32_t regnum) {
    RtlPriv *p = PRIV(vr);
    regnum &= 0xff;
    return p->bar_read((regnum & 0xff) << 2);
}

static void rtl_lfb_write(VoodooRenderer *vr, uint32_t dwoff,
                          uint32_t data, uint32_t mem_mask) {
    PRIV(vr)->bar_write(0x400000u + (dwoff << 2), data, mem_mask);
}

static uint32_t rtl_lfb_read(VoodooRenderer *vr, uint32_t dwoff) {
    return PRIV(vr)->bar_read(0x400000u + (dwoff << 2));
}

static void rtl_tex_write(VoodooRenderer *vr, uint32_t dwoff,
                          uint32_t data, uint32_t mem_mask) {
    PRIV(vr)->bar_write(0x800000u + (dwoff << 2), data, mem_mask);
}

static void rtl_scanout(VoodooRenderer *vr, void *surface, int pitch,
                        int maxw, int maxh) {
    RtlPriv *p = PRIV(vr);
    p->drain();
    rtl_sync_dims(vr);

    uint32_t base = p->top.scan_front_base;
    int rp = (int)p->top.scan_rowpixels;
    int w  = p->top.scan_width;
    int h  = p->top.scan_height;
    if (w  <= 0) w  = (vr->width  > 0) ? vr->width  : 640;
    if (h  <= 0) h  = (vr->height > 0) ? vr->height : 480;
    if (rp <= 0) rp = w;

    // present up to the surface dimensions; the framebuffer is rp pixels wide.
    int ow = (rp < maxw) ? rp : maxw;
    int oh = (h  < maxh) ? h  : maxh;

    uint8_t *dst = (uint8_t *)surface;
    for (int y = 0; y < oh; y++) {
        uint32_t *row = (uint32_t *)(dst + (size_t)y * pitch);
        uint32_t srcrow = base + (uint32_t)y * (uint32_t)rp;
        for (int x = 0; x < ow; x++) {
            int r, g, b; from565(p->fb(srcrow + (uint32_t)x), &r, &g, &b);
            row[x] = 0xff000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
        }
    }
}

static void rtl_get_dims(VoodooRenderer *vr, int *w, int *h) {
    RtlPriv *p = PRIV(vr);
    p->drain();
    rtl_sync_dims(vr);
    int sw = p->top.scan_width, sh = p->top.scan_height;
    *w = sw > 0 ? sw : (vr->width  > 0 ? vr->width  : 640);
    *h = sh > 0 ? sh : (vr->height > 0 ? vr->height : 480);
}

static bool rtl_take_dirty(VoodooRenderer *vr) {
    RtlPriv *p = PRIV(vr);
    bool d = p->dirty;
    p->dirty = false;
    return d;
}

static const VoodooRendererOps rtl_ops = {
    rtl_init,
    rtl_fini,
    rtl_reg_write,
    rtl_reg_read,
    rtl_lfb_write,
    rtl_lfb_read,
    rtl_tex_write,
    rtl_scanout,
    rtl_get_dims,
    rtl_take_dirty,
};

extern "C" VoodooRenderer *voodoo_rtl_create(void) {
    VoodooRenderer *vr = (VoodooRenderer *)calloc(1, sizeof(VoodooRenderer));
    if (!vr) return NULL;
    vr->ops = &rtl_ops;
    return vr;
}
