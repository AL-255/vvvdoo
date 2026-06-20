// voodoo_hw.cpp — BOARD (KV260) backend for the QEMU Voodoo device.
//
// Drop-in VoodooRendererOps implementation (same boundary as cosim/voodoo_rtl.cpp,
// see voodoo_render.h) that drives the REAL hardware in the KV260 PL over AXI MMIO
// instead of a Verilated model. Selected at runtime by VOODOO_BACKEND=hw, which
// voodoo.c resolves to voodoo_hw_create(). See fpga/kv260/README.md.
//
// The op->BAR-offset arithmetic is reproduced VERBATIM from voodoo_rtl.cpp so the
// command stream the PL sees is identical to the co-sim. Differences vs the cosim
// backend: bar_write/bar_read are AXI MMIO stores/loads into the mmap'd PL aperture
// (no Verilator), drain() polls the fast S_AXI_STAT busy bit (never the draining BAR
// read), and the framebuffer is read back from its DDR window.
//
// Build: `make cosim-lib-hw` -> libvoodoohw.a (no Verilator, no RTL). QEMU links it.
// Env: VOODOO_HW_DEV (/dev/mem default), VOODOO_HW_BASE (0x80000000),
//      VOODOO_HW_STAT_BASE (0x80010000), VOODOO_HW_FB_BASE (DDR fb phys),
//      VOODOO_HW_FB_WORDS (fb readback window size in 16-bit words).
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

extern "C" {
#include "voodoo_render.h"
}

#ifndef FB_AW
#define FB_AW 21                              // matches voodoo_pkg FB_AW
#endif
#define REG_swapbufferCMD 0x4a

// 16 MB device aperture (regs@0 / LFB@0x400000 / tex@0x800000) and the AXI4-Lite
// STAT sideband register offsets (see axi_voodoo_slave.sv / README §2).
static const uint64_t BAR_SIZE  = 0x1000000;  // 16 MiB
static const uint64_t STAT_SIZE = 0x10000;    // 64 KiB
enum { STAT_BUSY=0x00, STAT_FRONTBUF=0x04, STAT_FRONT_BASE=0x08,
       STAT_ROWPIXELS=0x0c, STAT_WIDTH=0x10, STAT_HEIGHT=0x14, STAT_INIT_EN=0x18 };

struct HwPriv {
    int               fd     = -1;
    volatile uint32_t *bar   = nullptr;       // 16MB S_AXI_BAR window
    volatile uint32_t *stat  = nullptr;       // S_AXI_STAT sideband
    volatile uint16_t *fbwin = nullptr;       // framebuffer readback window
    uint32_t          fb_words = (4u << 20) / 2u;
    bool              dirty  = false;
};
static inline HwPriv *PRIV(VoodooRenderer *vr) { return (HwPriv *)vr->priv; }

// arm64 ordering to Device/non-cacheable memory needs a real barrier, not just a
// compiler barrier — a posted store must reach the PL before the next dependent op.
static inline void hw_barrier() {
#if defined(__aarch64__)
    asm volatile("dmb sy" ::: "memory");
#else
    asm volatile("" ::: "memory");
#endif
}

// ---- AXI MMIO primitives ---------------------------------------------------
static inline void bar_write(HwPriv *p, uint32_t off, uint32_t data) {
    p->bar[off >> 2] = data; hw_barrier();
}
static inline uint32_t bar_read(HwPriv *p, uint32_t off) {  // NON-status: drains device
    uint32_t v = p->bar[off >> 2]; hw_barrier(); return v;
}
static inline uint32_t stat_read(HwPriv *p, uint32_t off) { return p->stat[off >> 2]; }
static inline void drain(HwPriv *p) { while (stat_read(p, STAT_BUSY) & 1u) { /* spin */ } }

static uint64_t env_u64(const char *k, uint64_t dflt) {
    const char *s = getenv(k); return s ? strtoull(s, nullptr, 0) : dflt;
}

// ---- VoodooRendererOps -----------------------------------------------------
static int hw_init(VoodooRenderer *vr) {
    HwPriv *p = new HwPriv();
    const char *dev = getenv("VOODOO_HW_DEV"); if (!dev) dev = "/dev/mem";
    uint64_t base    = env_u64("VOODOO_HW_BASE",      0x80000000ull);
    uint64_t statb   = env_u64("VOODOO_HW_STAT_BASE", 0x80010000ull);
    uint64_t fbbase  = env_u64("VOODOO_HW_FB_BASE",   0x70000000ull);
    p->fb_words      = (uint32_t)env_u64("VOODOO_HW_FB_WORDS", (4u << 20) / 2u);

    p->fd = open(dev, O_RDWR | O_SYNC);
    if (p->fd < 0) { fprintf(stderr, "voodoo-hw: open(%s) failed\n", dev); delete p; return -1; }
    p->bar  = (volatile uint32_t *)mmap(nullptr, BAR_SIZE,  PROT_READ|PROT_WRITE, MAP_SHARED, p->fd, base);
    p->stat = (volatile uint32_t *)mmap(nullptr, STAT_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, p->fd, statb);
    p->fbwin= (volatile uint16_t *)mmap(nullptr, (size_t)p->fb_words * 2, PROT_READ, MAP_SHARED, p->fd, fbbase);
    if (p->bar == MAP_FAILED || p->stat == MAP_FAILED || p->fbwin == MAP_FAILED) {
        fprintf(stderr, "voodoo-hw: mmap failed\n"); delete p; return -1;
    }
    // NOTE: for /dev/uio*, instead read /sys/class/uio/uioN/maps/map*/{addr,size}
    // and mmap each map index (map0=BAR, map1=STAT, map2=fb) at offset N*pagesize.
    vr->priv = p;
    vr->width = 640; vr->height = 480; vr->rowpixels = 640;
    return 0;
}

static void hw_fini(VoodooRenderer *vr) {
    HwPriv *p = PRIV(vr); if (!p) return;
    if (p->bar  && p->bar  != MAP_FAILED) munmap((void*)p->bar,  BAR_SIZE);
    if (p->stat && p->stat != MAP_FAILED) munmap((void*)p->stat, STAT_SIZE);
    if (p->fbwin&& p->fbwin!= MAP_FAILED) munmap((void*)p->fbwin,(size_t)p->fb_words*2);
    if (p->fd >= 0) close(p->fd);
    delete p; vr->priv = nullptr;
}

// voodoo.c has already applied register swizzle + alias; we rebuild the RAW BAR
// address the PL decodes (bits 18/19 inherently clear since dwoff<=0xfff).
static void hw_reg_write(VoodooRenderer *vr, uint32_t regnum, uint32_t chipmask, uint32_t data) {
    HwPriv *p = PRIV(vr);
    regnum &= 0xff;
    uint32_t off = (((chipmask & 0xf) << 8) | regnum) << 2;
    bar_write(p, off, data);
    vr->regs[regnum] = data;                  // shadow (voodoo.c predecodes fbInit*)
    if (regnum == REG_swapbufferCMD) p->dirty = true;
}
static uint32_t hw_reg_read(VoodooRenderer *vr, uint32_t regnum) {
    return bar_read(PRIV(vr), (regnum & 0xff) << 2);
}
static void hw_lfb_write(VoodooRenderer *vr, uint32_t dwoff, uint32_t data, uint32_t /*mm*/) {
    bar_write(PRIV(vr), 0x400000u + (dwoff << 2), data);
}
static uint32_t hw_lfb_read(VoodooRenderer *vr, uint32_t dwoff) {
    return bar_read(PRIV(vr), 0x400000u + (dwoff << 2));
}
static void hw_tex_write(VoodooRenderer *vr, uint32_t dwoff, uint32_t data, uint32_t /*mm*/) {
    bar_write(PRIV(vr), 0x800000u + (dwoff << 2), data);
}

static inline void from565(uint16_t px, int *r, int *g, int *b) {
    int rr = (px >> 11) & 0x1f, gg = (px >> 5) & 0x3f, bb = px & 0x1f;
    *r = (rr << 3) | (rr >> 2); *g = (gg << 2) | (gg >> 4); *b = (bb << 3) | (bb >> 2);
}

static void hw_scanout(VoodooRenderer *vr, void *surface, int pitch, int maxw, int maxh) {
    HwPriv *p = PRIV(vr);
    drain(p);                                  // fast STAT busy poll, never the BAR
    uint32_t base = stat_read(p, STAT_FRONT_BASE) & ((1u << FB_AW) - 1u);  // WORD offset
    int rp = (int)(stat_read(p, STAT_ROWPIXELS) & 0x7ff);
    int w  = (int)(stat_read(p, STAT_WIDTH)     & 0x3ff);
    int h  = (int)(stat_read(p, STAT_HEIGHT)    & 0x3ff);
    if (w  <= 0) w  = (vr->width  > 0) ? vr->width  : 640;
    if (h  <= 0) h  = (vr->height > 0) ? vr->height : 480;
    if (rp <= 0) rp = w;
    int ow = (rp < maxw) ? rp : maxw;
    int oh = (h  < maxh) ? h  : maxh;
    // TODO(perf): memcpy the visible rp*h-word window from fbwin into a local buffer
    // once per frame, then expand — 307k single MMIO reads/frame is far too slow.
    uint8_t *dst = (uint8_t *)surface;
    for (int y = 0; y < oh; y++) {
        uint32_t *row = (uint32_t *)(dst + (size_t)y * pitch);
        uint32_t srcrow = base + (uint32_t)y * (uint32_t)rp;
        for (int x = 0; x < ow; x++) {
            int r, g, b; from565(p->fbwin[srcrow + (uint32_t)x], &r, &g, &b);
            row[x] = 0xff000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
        }
    }
}

static void hw_get_dims(VoodooRenderer *vr, int *w, int *h) {
    HwPriv *p = PRIV(vr);
    int sw = (int)(stat_read(p, STAT_WIDTH) & 0x3ff), sh = (int)(stat_read(p, STAT_HEIGHT) & 0x3ff);
    *w = sw > 0 ? sw : (vr->width  > 0 ? vr->width  : 640);
    *h = sh > 0 ? sh : (vr->height > 0 ? vr->height : 480);
}
static bool hw_take_dirty(VoodooRenderer *vr) {
    HwPriv *p = PRIV(vr); bool d = p->dirty; p->dirty = false; return d;
}

static const VoodooRendererOps hw_ops = {
    hw_init, hw_fini, hw_reg_write, hw_reg_read,
    hw_lfb_write, hw_lfb_read, hw_tex_write,
    hw_scanout, hw_get_dims, hw_take_dirty,
};

extern "C" VoodooRenderer *voodoo_hw_create(void) {
    VoodooRenderer *vr = (VoodooRenderer *)calloc(1, sizeof(VoodooRenderer));
    if (!vr) return nullptr;
    vr->ops = &hw_ops;
    return vr;
}
