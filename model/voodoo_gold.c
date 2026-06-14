/*
 * voodoo_gold.c — golden reference C model for vvvdoo (3Dfx Voodoo SST-1).
 *
 * Ported from vvvdoo-refs/06-qemu-voodoo/src/voodoo_soft.c (the proven,
 * GLQuake-tested reference) and restructured per
 * vvvdoo-refs/06-qemu-voodoo/docs/voodoo-mame-spec.md, with the intentional
 * deviations of docs/CONTRACTS.md §9 applied:
 *   - rasterizer: the integer edge-walk of docs/raster-algorithm.md (NORMATIVE)
 *   - LFB raw writes: exact MAME expand_lfb_data / internal_lfb_w semantics
 *   - fastfill dithers color1; no y-flip in fastfill
 *   - pseudo-clamp (rgbzw_clamp=0) per exact MAME clamped_z/argb/w semantics
 *   - full MAME combine_color / alpha_test / alpha_blend semantics
 *   - out-of-range guard per CONTRACTS §9.6
 *
 * Pure integer in all M1/M2 paths (triangle walk, iterators, depth, combine,
 * blend, dither, fastfill, LFB). The TMU texture-sampling path keeps doubles
 * for now; every such spot is marked with "M3: integerize".
 */
#include "voodoo_gold.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ================================================================== */
/*  small helpers                                                      */
/* ================================================================== */

static inline uint32_t VBIT(uint32_t v, int start, int width)
{
    return (v >> start) & ((width >= 32) ? 0xffffffffu : ((1u << width) - 1u));
}
static inline int32_t vsext(uint32_t v, int bits)   /* sign-extend low `bits` */
{
    uint32_t m = 1u << (bits - 1);
    return (int32_t)((v ^ m) - m);
}
static inline int iclamp(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}
/* well-defined arithmetic shifts (no implementation-defined signed >>) */
static inline int32_t asr32(int32_t v, int n)
{
    return (v < 0) ? (int32_t)~(~(uint32_t)v >> n) : (int32_t)((uint32_t)v >> n);
}
static inline int64_t asr64(int64_t v, int n)
{
    return (v < 0) ? (int64_t)~(~(uint64_t)v >> n) : (int64_t)((uint64_t)v >> n);
}
/* wrap-safe shift-left of possibly negative values */
static inline int64_t shl64(int64_t v, int n) { return (int64_t)((uint64_t)v << n); }
static inline uint32_t bswap32(uint32_t v)
{
    return (v >> 24) | ((v >> 8) & 0x0000ff00u) | ((v << 8) & 0x00ff0000u) | (v << 24);
}
static inline uint32_t rot16(uint32_t v) { return (v << 16) | (v >> 16); }
static inline uint32_t rotr32(uint32_t v, int n) { n &= 31; return (v >> n) | (v << ((32 - n) & 31)); }

/* IEEE-754 float bits -> fixed point, matching MAME float_to_int32
 * (mame_voodoo.cpp:138); shifts performed in unsigned to avoid UB. */
static int32_t float_to_int32(uint32_t data, int fixedbits)
{
    int exponent = (int)((data >> 23) & 0xff) - 127 - 23 + fixedbits;
    uint32_t result = (data & 0x7fffffu) | 0x800000u;
    if (exponent < 0) {
        result = (exponent > -32) ? (result >> -exponent) : 0;
    } else {
        result = (exponent < 32) ? (result << exponent) : 0x7fffffffu;
    }
    int32_t r = (int32_t)result;
    if (data & 0x80000000u) r = (int32_t)(0u - result);
    return r;
}
static int64_t float_to_int64(uint32_t data, int fixedbits)
{
    int exponent = (int)((data >> 23) & 0xff) - 127 - 23 + fixedbits;
    uint64_t result = (uint64_t)((data & 0x7fffffu) | 0x800000u);
    if (exponent < 0) {
        result = (exponent > -64) ? (result >> -exponent) : 0;
    } else {
        result = (exponent < 64) ? (result << exponent) : 0x7fffffffffffffffull;
    }
    int64_t r = (int64_t)result;
    if (data & 0x80000000u) r = (int64_t)(0ull - result);
    return r;
}

/* RGB565 <-> RGB888 (bit replication) */
static inline uint16_t to565(int r, int g, int b)
{
    return (uint16_t)(((iclamp(r, 0, 255) >> 3) << 11) |
                      ((iclamp(g, 0, 255) >> 2) << 5) |
                       (iclamp(b, 0, 255) >> 3));
}
static inline void from565(uint16_t p, int *r, int *g, int *b)
{
    int rr = (p >> 11) & 0x1f, gg = (p >> 5) & 0x3f, bb = p & 0x1f;
    *r = (rr << 3) | (rr >> 2);
    *g = (gg << 2) | (gg >> 4);
    *b = (bb << 3) | (bb >> 2);
}
/* expand an n-bit field to 8 bits by bit replication (MAME rgbexpand) */
static inline uint8_t expbits(uint32_t v, int n)
{
    switch (n) {
    case 1:  return (uint8_t)((v & 1) ? 0xff : 0x00);
    case 4:  v &= 0xf;  return (uint8_t)((v << 4) | v);
    case 5:  v &= 0x1f; return (uint8_t)((v << 3) | (v >> 2));
    case 6:  v &= 0x3f; return (uint8_t)((v << 2) | (v >> 4));
    default: return (uint8_t)(v & 0xff);
    }
}

/* an ARGB working color (each channel 0..255 nominally; ints during math) */
typedef struct { int a, r, g, b; } argb_t;

/* ================================================================== */
/*  register indices (word offsets) — from voodoo_render.h             */
/* ================================================================== */
enum {
    REG_status        = 0x00,
    REG_vertexAx      = 0x02, REG_vertexAy = 0x03,
    REG_vertexBx      = 0x04, REG_vertexBy = 0x05,
    REG_vertexCx      = 0x06, REG_vertexCy = 0x07,
    REG_startR        = 0x08, REG_startG = 0x09, REG_startB = 0x0a,
    REG_startZ        = 0x0b, REG_startA = 0x0c,
    REG_startS        = 0x0d, REG_startT = 0x0e, REG_startW = 0x0f,
    REG_dRdX          = 0x10, REG_dGdX = 0x11, REG_dBdX = 0x12,
    REG_dZdX          = 0x13, REG_dAdX = 0x14,
    REG_dSdX          = 0x15, REG_dTdX = 0x16, REG_dWdX = 0x17,
    REG_dRdY          = 0x18, REG_dGdY = 0x19, REG_dBdY = 0x1a,
    REG_dZdY          = 0x1b, REG_dAdY = 0x1c,
    REG_dSdY          = 0x1d, REG_dTdY = 0x1e, REG_dWdY = 0x1f,
    REG_triangleCMD   = 0x20,
    REG_fvertexAx     = 0x22,
    REG_fdWdY         = 0x3f,
    REG_ftriangleCMD  = 0x40,
    REG_fbzColorPath  = 0x41,
    REG_fogMode       = 0x42,
    REG_alphaMode     = 0x43,
    REG_fbzMode       = 0x44,
    REG_lfbMode       = 0x45,
    REG_clipLeftRight = 0x46,
    REG_clipLowYHighY = 0x47,
    REG_nopCMD        = 0x48,
    REG_fastfillCMD   = 0x49,
    REG_swapbufferCMD = 0x4a,
    REG_fogColor      = 0x4b,
    REG_zaColor       = 0x4c,
    REG_chromaKey     = 0x4d,
    REG_stipple       = 0x50,
    REG_fogTable      = 0x58,    /* 0x58..0x77: 32 dwords, 2 entries each */
    REG_color0        = 0x51,
    REG_color1        = 0x52,
    REG_fbiPixelsIn   = 0x53,
    REG_fbiPixelsOut  = 0x57,
    REG_fbiInit4      = 0x80,
    REG_backPorch     = 0x82,
    REG_videoDimensions = 0x83,
    REG_fbiInit0      = 0x84,
    REG_fbiInit1      = 0x85,
    REG_fbiInit2      = 0x86,
    REG_fbiInit3      = 0x87,
    REG_dacData       = 0x8b,
    REG_textureMode   = 0xc0,
    REG_tLOD          = 0xc1,
    REG_texBaseAddr   = 0xc3,
};

/* register alias map (fbiInit3 bit0, BAR dword-offset bit 19) — voodoo.c:73 */
static const uint8_t alias_map[0x40] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x10, 0x18, 0x09, 0x11, 0x19, 0x0a, 0x12,
    0x1a, 0x0b, 0x13, 0x1b, 0x0c, 0x14, 0x1c, 0x0d,
    0x15, 0x1d, 0x0e, 0x16, 0x1e, 0x0f, 0x17, 0x1f,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
    0x28, 0x30, 0x38, 0x29, 0x31, 0x39, 0x2a, 0x32,
    0x3a, 0x2b, 0x33, 0x3b, 0x2c, 0x34, 0x3c, 0x2d,
    0x35, 0x3d, 0x2e, 0x36, 0x3e, 0x2f, 0x37, 0x3f,
};

/* ================================================================== */
/*  register field accessors                                           */
/* ================================================================== */

/* fbzMode (0x44) */
#define FBZ_clip(v)        VBIT(v,0,1)
#define FBZ_chromakey(v)   VBIT(v,1,1)
#define FBZ_stipple(v)     VBIT(v,2,1)
#define FBZ_wbuffer(v)     VBIT(v,3,1)
#define FBZ_depthen(v)     VBIT(v,4,1)
#define FBZ_depthfn(v)     VBIT(v,5,3)
#define FBZ_dither(v)      VBIT(v,8,1)
#define FBZ_rgbmask(v)     VBIT(v,9,1)
#define FBZ_auxmask(v)     VBIT(v,10,1)
#define FBZ_dither2(v)     VBIT(v,11,1)
#define FBZ_stipplepat(v)  VBIT(v,12,1)
#define FBZ_alphamask(v)   VBIT(v,13,1)
#define FBZ_drawbuf(v)     VBIT(v,14,2)
#define FBZ_depthbias(v)   VBIT(v,16,1)
#define FBZ_yorigin(v)     VBIT(v,17,1)
#define FBZ_alphaplanes(v) VBIT(v,18,1)
#define FBZ_depthsrc(v)    VBIT(v,20,1)

/* fogMode (0x42) */
#define FOG_enable(v)      VBIT(v,0,1)
#define FOG_add(v)         VBIT(v,1,1)
#define FOG_mult(v)        VBIT(v,2,1)
#define FOG_zalpha(v)      VBIT(v,3,2)
#define FOG_constant(v)    VBIT(v,5,1)
#define FOG_dither(v)      VBIT(v,6,1)   /* V2 */
#define FOG_zones(v)       VBIT(v,7,1)   /* V2 */

/* alphaMode (0x43) */
#define AM_test(v)         VBIT(v,0,1)
#define AM_func(v)         VBIT(v,1,3)
#define AM_blend(v)        VBIT(v,4,1)
#define AM_srcrgb(v)       VBIT(v,8,4)
#define AM_dstrgb(v)       VBIT(v,12,4)
#define AM_srca(v)         VBIT(v,16,4)
#define AM_dsta(v)         VBIT(v,20,4)
#define AM_ref(v)          VBIT(v,24,8)

/* fbzColorPath (0x41) */
#define CP_rgbselect(v)    VBIT(v,0,2)
#define CP_aselect(v)      VBIT(v,2,2)
#define CP_localselect(v)  VBIT(v,4,1)
#define CP_cca_localsel(v) VBIT(v,5,2)
#define CP_localovr(v)     VBIT(v,7,1)
#define CP_zero_other(v)   VBIT(v,8,1)
#define CP_sub_clocal(v)   VBIT(v,9,1)
#define CP_mselect(v)      VBIT(v,10,3)
#define CP_reverse(v)      VBIT(v,13,1)
#define CP_add_aclocal(v)  VBIT(v,14,2)
#define CP_invert(v)       VBIT(v,16,1)
#define CP_cca_zero(v)     VBIT(v,17,1)
#define CP_cca_sub(v)      VBIT(v,18,1)
#define CP_cca_mselect(v)  VBIT(v,19,3)
#define CP_cca_reverse(v)  VBIT(v,22,1)
#define CP_cca_add(v)      VBIT(v,23,2)
#define CP_cca_invert(v)   VBIT(v,25,1)
#define CP_subpixel(v)     VBIT(v,26,1)
#define CP_texenable(v)    VBIT(v,27,1)
#define CP_rgbzwclamp(v)   VBIT(v,28,1)

/* textureMode (0xc0) */
#define TM_persp(v)        VBIT(v,0,1)
#define TM_minfilter(v)    VBIT(v,1,1)
#define TM_magfilter(v)    VBIT(v,2,1)
#define TM_clampnegw(v)    VBIT(v,3,1)
#define TM_clamps(v)       VBIT(v,6,1)
#define TM_clampt(v)       VBIT(v,7,1)
#define TM_format(v)       VBIT(v,8,4)
#define TM_tc_zero(v)      VBIT(v,12,1)
#define TM_tc_sub(v)       VBIT(v,13,1)
#define TM_tc_mselect(v)   VBIT(v,14,3)
#define TM_tc_reverse(v)   VBIT(v,17,1)
#define TM_tc_add(v)       VBIT(v,18,2)
#define TM_tc_invert(v)    VBIT(v,20,1)
#define TM_tca_zero(v)     VBIT(v,21,1)
#define TM_tca_sub(v)      VBIT(v,22,1)
#define TM_tca_mselect(v)  VBIT(v,23,3)
#define TM_tca_reverse(v)  VBIT(v,26,1)
#define TM_tca_add(v)      VBIT(v,27,2)
#define TM_tca_invert(v)   VBIT(v,29,1)

/* lfbMode (0x45) */
#define LFB_wformat(v)     VBIT(v,0,4)
#define LFB_wbufsel(v)     VBIT(v,4,2)
#define LFB_rbufsel(v)     VBIT(v,6,2)
#define LFB_pixpipe(v)     VBIT(v,8,1)
#define LFB_lanes(v)       VBIT(v,9,2)
#define LFB_wswap(v)       VBIT(v,11,1)
#define LFB_byteswz(v)     VBIT(v,12,1)
#define LFB_yorigin(v)     VBIT(v,13,1)
#define LFB_wsel(v)        VBIT(v,14,1)
#define LFB_wswap_r(v)     VBIT(v,15,1)
#define LFB_byteswz_r(v)   VBIT(v,16,1)

/* clip registers: min in [25:16], max in [9:0] */
static inline int clip_min(uint32_t v) { return (int)VBIT(v, 16, 10); }
static inline int clip_max(uint32_t v) { return (int)VBIT(v, 0, 10); }

/* Voodoo-1 texture base addressing: texBaseAddr is in 8-byte units. */
#define TEX_ADDR_MASK  0x7ffffu
#define TEX_ADDR_SHIFT 3

#define FB_WORDS  (VGOLD_FB_BYTES / 2)     /* 2^21 16-bit words */
#define FB_MASK   (VGOLD_FB_BYTES - 1)
#define TEX_MASK  (VGOLD_TEX_BYTES - 1)    /* 0x1fffff */

/* ================================================================== */
/*  device state                                                       */
/* ================================================================== */

struct vgold {
    uint32_t  regs[256];

    /* 64-bit shadows for the S/T/W iterators (voodoo_soft set_stw) */
    int64_t   fbi_startw, fbi_dwdx, fbi_dwdy;
    int64_t   t0_starts, t0_ds_dx, t0_ds_dy;
    int64_t   t0_startt, t0_dt_dx, t0_dt_dy;
    int64_t   t0_startw, t0_dw_dx, t0_dw_dy;

    uint16_t *fb;            /* 2M 16-bit words (4MB) */
    uint8_t  *texram;        /* 2MB */

    uint32_t  rgboffs[3];    /* byte offsets; ~0 = absent */
    uint32_t  auxoffs;       /* byte offset; ~0 = absent */
    int       frontbuf, backbuf;
    uint32_t  rowpixels;
    int       width, height;
    int       yorigin;       /* fbiInit3 [31:22] */

    uint32_t  init_enable;
    uint8_t   dac_reg[8];
    uint32_t  dac_read_result;

    /* TMU0 cached texture layout (tex_recompute) */
    uint32_t  lodoffset[9];
    int       wmask, hmask;
    int       tformat, bpt;
    int       lodmin, lodmax, lodbias, lodmask;
    uint16_t  pal565[256];

    /* M4: fog tables (MAME m_fogblend/m_fogdelta), 64 u8 entries each */
    uint8_t   fogblend[64];
    uint8_t   fogdelta[64];
};

static inline uint32_t R(const vgold_t *g, int idx) { return g->regs[idx]; }

static inline int yorigin_eff(const vgold_t *g)
{
    return g->yorigin ? g->yorigin : (g->height - 1);
}

/* CONTRACTS §9.6 out-of-range guard: post-flip row sy, word index check.
 * Computed without wrap in 64-bit. base = buffer byte offset (not ~0). */
static inline bool fb_word_ok(const vgold_t *g, uint32_t base, int sy, int64_t x)
{
    if (sy < 0 || sy > 1023)
        return false;
    int64_t idx = (int64_t)sy * (int64_t)g->rowpixels + x;
    uint64_t word = (uint64_t)((base & FB_MASK) >> 1) + (uint64_t)idx;
    return idx >= 0 && word < (1ull << 21);
}
static inline uint32_t fb_word_index(const vgold_t *g, uint32_t base, int sy, int x)
{
    return ((base & FB_MASK) >> 1) + (uint32_t)sy * g->rowpixels + (uint32_t)x;
}

/* color buffer byte offset for fbzMode draw_buffer / lfbMode write select;
 * MAME draw_buffer_indirect: 0=front, 1=back, others absent */
static uint32_t draw_buffer_offs(const vgold_t *g, int sel)
{
    switch (sel) {
    case 0:  return g->rgboffs[g->frontbuf];
    case 1:  return g->rgboffs[g->backbuf];
    default: return ~0u;
    }
}
/* MAME lfb_buffer_indirect: 0=front, 1=back, 2=aux, 3 absent */
static uint32_t lfb_buffer_offs(const vgold_t *g, int sel)
{
    switch (sel) {
    case 0:  return g->rgboffs[g->frontbuf];
    case 1:  return g->rgboffs[g->backbuf];
    case 2:  return g->auxoffs;
    default: return ~0u;
    }
}

/* recompute_video_memory (voodoo_soft.c port, incl. fbiInit1 bit24) */
static void recompute_video_memory(vgold_t *g)
{
    uint32_t i2 = R(g, REG_fbiInit2);
    uint32_t i1 = R(g, REG_fbiInit1);
    uint32_t buffer_pages = VBIT(i2, 11, 9);          /* video_buffer_offset */
    uint32_t config = VBIT(i2, 4, 1);                 /* enable_triple_buf */
    uint32_t xtiles = VBIT(i1, 4, 4) | (VBIT(i1, 24, 1) << 4);

    g->rgboffs[0] = 0;
    g->rgboffs[1] = buffer_pages * 0x1000;
    if (config) {
        g->rgboffs[2] = 2 * buffer_pages * 0x1000;
        g->auxoffs = ~0u;
    } else {
        g->rgboffs[2] = ~0u;
        g->auxoffs = 2 * buffer_pages * 0x1000;
    }
    if (xtiles)
        g->rowpixels = xtiles * 64;
}

static void recompute_dims(vgold_t *g)
{
    uint32_t vd = R(g, REG_videoDimensions);
    int w = (int)VBIT(vd, 0, 10);
    int h = (int)VBIT(vd, 16, 10);
    if (w > 0 && h > 0) {
        g->width = w;
        g->height = h;
    }
}

/* ================================================================== */
/*  dither (MAME dither_helper; CONTRACTS §8)                          */
/* ================================================================== */

static const uint8_t dither4x4[16] = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5,
};
static const uint8_t dither2x2[16] = {
     8, 10,  8, 10,
    11,  9, 11,  9,
     8, 10,  8, 10,
    11,  9, 11,  9,
};

/* r,g,b in [0,255]; x,y are the dither coordinates (pixel x, post-flip y) */
static uint16_t dither565(uint32_t fbz, int x, int y, int r, int g, int b)
{
    if (!FBZ_dither(fbz))
        return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    const uint8_t *m = FBZ_dither2(fbz) ? dither2x2 : dither4x4;
    int d = m[((y & 3) << 2) | (x & 3)];
    int r5 = ((r << 1) - (r >> 4) + (r >> 7) + d) >> 4;
    int g6 = ((g << 2) - (g >> 4) + (g >> 6) + d) >> 4;
    int b5 = ((b << 1) - (b >> 4) + (b >> 7) + d) >> 4;
    return (uint16_t)((r5 << 11) | (g6 << 5) | b5);
}

/* ================================================================== */
/*  pseudo-clamp helpers — EXACT MAME semantics (render.cpp:66-154)    */
/* ================================================================== */

/* clamped_argb on one channel: MAME shifts the 12.12 iterator <<8 to 12.20
 * and does a LOGICAL >>20, i.e. field = (u32(iter) >> 12) & 0xfff. */
static int clamp_argb_chan(uint32_t iter1212, uint32_t fbzcp)
{
    uint32_t field = (iter1212 >> 12) & 0xfff;
    if (CP_rgbzwclamp(fbzcp))
        return field > 255 ? 255 : (int)field;
    if (field == 0xfff) return 0;
    if (field == 0x100) return 0xff;
    return (int)(field & 0xff);
}

static int32_t clamped_z(int32_t iterz, uint32_t fbzcp)
{
    if (CP_rgbzwclamp(fbzcp)) {
        int32_t v = asr32(iterz, 12);
        return iclamp(v, 0, 0xffff);
    }
    uint32_t r = (uint32_t)iterz >> 12;
    if (r == 0xfffff) return 0;
    if (r == 0x10000) return 0xffff;
    return (int32_t)(r & 0xffff);
}

/* gold keeps W as 16.32; MAME operates on the 16.48 iterator (= <<16) */
static int32_t clamped_w(int64_t iterw32, uint32_t fbzcp)
{
    if (CP_rgbzwclamp(fbzcp)) {
        int32_t v = (int32_t)(int16_t)(uint16_t)(((uint64_t)iterw32 >> 32) & 0xffff);
        return iclamp(v, 0, 0xff);
    }
    uint32_t r = (uint32_t)(((uint64_t)iterw32 >> 32) & 0xffff);
    if (r == 0xffff) return 0;
    if (r == 0x100) return 0xff;
    return (int32_t)(r & 0xff);
}

/* wfloat from the 16.32 W iterator <<16 — clzll formula, voodoo_soft:729-735 */
static int32_t wfloat_of(int64_t iterw32)
{
    int64_t iw = shl64(iterw32, 16);
    uint64_t uw = (uint64_t)iw;
    int exp = __builtin_clzll(uw ? uw : 1u) - 16;
    if (iw == 0 || exp < 0)
        return 0;
    if (exp >= 16)
        return 0xffff;
    return (int32_t)(((((uint32_t)exp << 12) |
                       (uint32_t)((((uint64_t)iw >> (35 - exp)) ^ 0x1fff) & 0x1fff)) + 1) & 0xffff);
}

/* shared 8-way compare (depth_function / alphafunction encoding) */
static bool compare_func(int func, int incoming, int stored)
{
    switch (func & 7) {
    case 0:  return false;
    case 1:  return incoming < stored;
    case 2:  return incoming == stored;
    case 3:  return incoming <= stored;
    case 4:  return incoming > stored;
    case 5:  return incoming != stored;
    case 6:  return incoming >= stored;
    default: return true;
    }
}

/* ================================================================== */
/*  texture (TMU0) — M3: integerize (doubles allowed per CONTRACTS §3) */
/* ================================================================== */

static void tex_default_palette(vgold_t *g)
{
    for (int i = 0; i < 256; i++)
        g->pal565[i] = to565(i, i, i);
}

/* recompute texture layout from current TMU0 regs (voodoo_soft tex_recompute) */
static void tex_recompute(vgold_t *g)
{
    uint32_t tmode = R(g, REG_textureMode);
    uint32_t tlod = R(g, REG_tLOD);

    g->lodmin = (int)VBIT(tlod, 0, 6) << 6;
    g->lodmax = (int)VBIT(tlod, 6, 6) << 6;
    g->lodbias = (int)(int8_t)(uint8_t)(VBIT(tlod, 12, 6) << 2) << 4;
    g->lodmask = 0x1ff;
    if (VBIT(tlod, 19, 1)) /* lod_tsplit */
        g->lodmask = VBIT(tlod, 18, 1) ? 0x0aa : 0x155;

    g->wmask = g->hmask = 0xff;
    int aspect = (int)VBIT(tlod, 21, 2);
    if (VBIT(tlod, 20, 1)) g->hmask >>= aspect; else g->wmask >>= aspect;

    g->tformat = (int)TM_format(tmode);
    g->bpt = (g->tformat < 8) ? 1 : 2;
    int bppscale = g->tformat >> 3;

    uint32_t base = (R(g, REG_texBaseAddr) & TEX_ADDR_MASK) << TEX_ADDR_SHIFT;
    g->lodoffset[0] = base & TEX_MASK;
    /* LODs 1-3 use the raw footprint (matches MAME single-base path) ... */
    for (int lod = 1; lod <= 3; lod++) {
        if (g->lodmask & (1 << (lod - 1)))
            base += (uint32_t)((((g->wmask >> (lod - 1)) + 1) *
                               ((g->hmask >> (lod - 1)) + 1)) << bppscale);
        g->lodoffset[lod] = base & TEX_MASK;
    }
    /* ... LODs 4-8 clamp each level's texel footprint to a minimum of 4 */
    for (int lod = 4; lod <= 8; lod++) {
        if (g->lodmask & (1 << (lod - 1))) {
            uint32_t size = (uint32_t)(((g->wmask >> (lod - 1)) + 1) *
                                       ((g->hmask >> (lod - 1)) + 1));
            if (size < 4) size = 4;
            base += size << bppscale;
        }
        g->lodoffset[lod] = base & TEX_MASK;
    }
}

/* expand one raw texel value to ARGB (voodoo_soft texel_expand) */
static argb_t texel_expand(const vgold_t *g, uint32_t raw)
{
    argb_t c;
    switch (g->tformat) {
    case 0: case 8: { /* RGB 3-3-2 */
        int r = (int)VBIT(raw, 5, 3), gg = (int)VBIT(raw, 2, 3), b = (int)VBIT(raw, 0, 2);
        c.r = (r << 5) | (r << 2) | (r >> 1);
        c.g = (gg << 5) | (gg << 2) | (gg >> 1);
        c.b = (b << 6) | (b << 4) | (b << 2) | b;
        c.a = 0xff; break;
    }
    case 2: { /* A8 -> AAAA */
        int v = (int)(raw & 0xff); c.a = c.r = c.g = c.b = v; break;
    }
    case 3: case 13: { /* int8 intensity: A=0xff, RGB=(v,v,v) */
        int v = (int)(raw & 0xff);
        c.a = 0xff; c.r = c.g = c.b = v; break;
    }
    case 1: case 5: case 7: { /* NCC / paletted (approx via palette) */
        int v = (int)(raw & 0xff);
        from565(g->pal565[v], &c.r, &c.g, &c.b); c.a = 0xff; break;
    }
    case 4: { /* AI44 */
        int a = (int)VBIT(raw, 4, 4), i = (int)VBIT(raw, 0, 4);
        c.a = (a << 4) | a; c.r = c.g = c.b = (i << 4) | i; break;
    }
    case 10: { /* RGB565 */
        from565((uint16_t)raw, &c.r, &c.g, &c.b); c.a = 0xff; break;
    }
    case 11: { /* ARGB1555 */
        c.a = VBIT(raw, 15, 1) ? 0xff : 0;
        int r = (int)VBIT(raw, 10, 5), gg = (int)VBIT(raw, 5, 5), b = (int)VBIT(raw, 0, 5);
        c.r = (r << 3) | (r >> 2); c.g = (gg << 3) | (gg >> 2); c.b = (b << 3) | (b >> 2);
        break;
    }
    case 12: { /* ARGB4444 */
        int a = (int)VBIT(raw, 12, 4), r = (int)VBIT(raw, 8, 4);
        int gg = (int)VBIT(raw, 4, 4), b = (int)VBIT(raw, 0, 4);
        c.a = (a << 4) | a; c.r = (r << 4) | r; c.g = (gg << 4) | gg; c.b = (b << 4) | b;
        break;
    }
    default:
        c.a = 0xff; c.r = 0xff; c.g = 0; c.b = 0xff; break; /* magenta = unimpl */
    }
    return c;
}

static argb_t lookup_texel(const vgold_t *g, uint32_t texbase, int s, int t)
{
    uint32_t raw;
    if (g->bpt == 1) {
        uint32_t addr = (texbase + (uint32_t)(t + s)) & TEX_MASK;
        raw = g->texram[addr];
    } else {
        uint32_t addr = (texbase + 2u * (uint32_t)(t + s)) & TEX_MASK & ~1u;
        raw = (uint32_t)g->texram[addr] | ((uint32_t)g->texram[addr + 1] << 8);
    }
    return texel_expand(g, raw);
}

/* log2 mantissa table (MAME s_log2_table). 7-bit mantissa index -> 8-bit frac. */
static const uint8_t s_log2_table[128] = {
      0,   2,   5,   8,  11,  14,  16,  19,  22,  25,  27,  30,  33,  35,  38,  40,
     43,  46,  48,  51,  53,  56,  58,  61,  63,  65,  68,  70,  73,  75,  77,  80,
     82,  84,  87,  89,  91,  93,  96,  98, 100, 102, 104, 106, 109, 111, 113, 115,
    117, 119, 121, 123, 125, 127, 129, 132, 134, 136, 138, 140, 141, 143, 145, 147,
    149, 151, 153, 155, 157, 159, 161, 162, 164, 166, 168, 170, 172, 173, 175, 177,
    179, 181, 182, 184, 186, 188, 189, 191, 193, 194, 196, 198, 200, 201, 203, 205,
    206, 208, 209, 211, 213, 214, 216, 218, 219, 221, 222, 224, 225, 227, 229, 230,
    232, 233, 235, 236, 238, 239, 241, 242, 244, 245, 247, 248, 250, 251, 253, 254
};

/* fast_log2 (24.8 fixed) — MAME's IEEE-754-double-bit form
 * (mame_voodoo_render.cpp:165). Reads the double's exponent (11 bits) and top
 * 7 mantissa bits; this is the FLOAT spec the RTL mirrors with Verilator
 * `real`. Negative values return 0 (sign already 0 by guard). */
static int32_t fast_log2(double value, int fracbits)
{
    if (value < 0)
        return 0;
    union { double d; uint64_t i; } temp;
    temp.d = value;
    uint32_t ival = (uint32_t)(temp.i >> 45);
    int32_t exp = (int32_t)(ival >> 7) - 1023 - fracbits;
    return (int32_t)(((uint32_t)exp << 8) | s_log2_table[ival & 127]);
}

/* base LOD from the texture-coordinate gradients (MAME double form). The
 * iterators are .32, so squares are .64; fast_log2(.,64)/2 = log of sqrt. */
static int32_t compute_lodbase(int64_t dsdx, int64_t dsdy, int64_t dtdx, int64_t dtdy)
{
    double fdsdx = (double)dsdx, fdsdy = (double)dsdy;
    double fdtdx = (double)dtdx, fdtdy = (double)dtdy;
    double texdx = fdsdx * fdsdx + fdtdx * fdtdx;
    double texdy = fdsdy * fdsdy + fdtdy * fdtdy;
    double maxval = texdx > texdy ? texdx : texdy;
    return fast_log2(maxval, 64) / 2;
}

/* fetch a filtered texel (MAME rasterizer_texture::fetch_texel, render.cpp:916).
 * Perspective/affine use DOUBLE math exactly as MAME — this is the FLOAT spec
 * the RTL mirrors with Verilator `real`. The iterators are passed as doubles
 * cast from the int64 accumulators at the call site. */
static argb_t fetch_texel(const vgold_t *g, uint32_t tmode,
                          double iters, double itert, double iterw, int lodbase)
{
    int32_t s, t, lod = lodbase;

    if (TM_persp(tmode)) {
        double recip = 256.0 / iterw;
        s = (int32_t)(iters * recip);
        t = (int32_t)(itert * recip);
        lod -= fast_log2(iterw, 32);
    } else {
        s = (int32_t)(iters * (1.0 / (double)(1 << 24)));
        t = (int32_t)(itert * (1.0 / (double)(1 << 24)));
    }
    if (TM_clampnegw(tmode) && iterw < 0)
        s = t = 0;

    lod += g->lodbias;
    lod = iclamp(lod, g->lodmin, g->lodmax);
    int ilod = lod >> 8;
    ilod += (~g->lodmask >> ilod) & 1;
    if (ilod > 8) ilod = 8;
    uint32_t texbase = g->lodoffset[ilod];
    int smax = g->wmask >> ilod;
    int tmax = g->hmask >> ilod;

    bool point = (lod == g->lodmin && !TM_magfilter(tmode)) ||
                 (lod != g->lodmin && !TM_minfilter(tmode));
    if (point) {
        int sh = ilod + 8;
        int ss = asr32(s, sh), tt = asr32(t, sh);
        if (TM_clamps(tmode)) ss = iclamp(ss, 0, smax);
        if (TM_clampt(tmode)) tt = iclamp(tt, 0, tmax);
        ss &= smax; tt &= tmax;
        tt *= smax + 1;
        return lookup_texel(g, texbase, ss, tt);
    } else {
        int ss = asr32(s, ilod), tt = asr32(t, ilod);
        ss -= 0x80; tt -= 0x80;
        int sfrac = ss & 0xf0, tfrac = tt & 0xf0;
        ss = asr32(ss, 8); tt = asr32(tt, 8);
        int s1 = ss + 1, t1 = tt + 1;
        if (TM_clamps(tmode)) { if (ss < 0) ss = s1 = 0; else if (ss >= smax) ss = s1 = smax; }
        if (TM_clampt(tmode)) { if (tt < 0) tt = t1 = 0; else if (tt >= tmax) tt = t1 = tmax; }
        ss &= smax; s1 &= smax; tt &= tmax; t1 &= tmax;
        tt *= smax + 1; t1 *= smax + 1;
        argb_t c00 = lookup_texel(g, texbase, ss, tt);
        argb_t c10 = lookup_texel(g, texbase, s1, tt);
        argb_t c01 = lookup_texel(g, texbase, ss, t1);
        argb_t c11 = lookup_texel(g, texbase, s1, t1);
        argb_t r;
        int isf = 256 - sfrac, itf = 256 - tfrac;
        int w00 = (isf * itf) >> 8, w10 = (sfrac * itf) >> 8;
        int w01 = (isf * tfrac) >> 8, w11 = (sfrac * tfrac) >> 8;
        r.a = (c00.a * w00 + c10.a * w10 + c01.a * w01 + c11.a * w11) >> 8;
        r.r = (c00.r * w00 + c10.r * w10 + c01.r * w01 + c11.r * w11) >> 8;
        r.g = (c00.g * w00 + c10.g * w10 + c01.g * w01 + c11.g * w11) >> 8;
        r.b = (c00.b * w00 + c10.b * w10 + c01.b * w01 + c11.b * w11) >> 8;
        return r;
    }
}

/* generic TMU combine unit (voodoo_soft combine(), used for the texture
 * combine stage only — the FBI color path uses combine_color_full below) */
typedef struct {
    int zero_o, zero_oa, sub, sub_a;
    int msel, msel_a, rev, rev_a;
    int add, add_a, inv, inv_a;
} combine_ctl;

static argb_t combine_generic(combine_ctl c, argb_t other, argb_t local, int texelA, int lodfrac)
{
    int br = c.zero_o ? 0 : other.r;
    int bg = c.zero_o ? 0 : other.g;
    int bb = c.zero_o ? 0 : other.b;
    int ba = c.zero_oa ? 0 : other.a;
    if (c.sub)   { br -= local.r; bg -= local.g; bb -= local.b; }
    if (c.sub_a) { ba -= local.a; }

    int fr, fg, fb, fa;
    switch (c.msel) {
    default: fr = fg = fb = 0; break;
    case 1: fr = local.r; fg = local.g; fb = local.b; break;
    case 2: fr = fg = fb = other.a; break;
    case 3: fr = fg = fb = local.a; break;
    case 4: fr = fg = fb = texelA; break;
    case 5: fr = fg = fb = lodfrac; break;
    }
    switch (c.msel_a) {
    default: fa = 0; break;
    case 1: case 3: fa = local.a; break;
    case 2: fa = other.a; break;
    case 4: fa = texelA; break;
    case 5: fa = lodfrac; break;
    }
    if (!c.rev)   { fr ^= 0xff; fg ^= 0xff; fb ^= 0xff; }
    if (!c.rev_a) { fa ^= 0xff; }
    fr++; fg++; fb++; fa++;

    int ar = 0, ag = 0, ab = 0, aa = 0;
    if (c.add == 1)      { ar = local.r; ag = local.g; ab = local.b; }
    else if (c.add == 2) { ar = ag = ab = local.a; }
    if (c.add_a) aa = local.a;

    argb_t out;
    out.r = iclamp(asr32(br * fr, 8) + ar, 0, 255);
    out.g = iclamp(asr32(bg * fg, 8) + ag, 0, 255);
    out.b = iclamp(asr32(bb * fb, 8) + ab, 0, 255);
    out.a = iclamp(asr32(ba * fa, 8) + aa, 0, 255);
    if (c.inv)   { out.r ^= 0xff; out.g ^= 0xff; out.b ^= 0xff; }
    if (c.inv_a) { out.a ^= 0xff; }
    return out;
}

/* ================================================================== */
/*  FBI color combine — full MAME combine_color semantics              */
/*  (mame_voodoo_render.cpp:1511-1729; chroma key / alpha mask = M4)   */
/* ================================================================== */

/* Returns true to keep the pixel, false to discard (chroma key / alpha mask
 * fail). On keep, *out receives the combined color. fbz is needed for the
 * chroma-key / alpha-mask enable bits (the tests live INSIDE combine). */
static bool combine_color_full(const vgold_t *g, uint32_t cp, uint32_t fbz, argb_t iter,
                               argb_t texel, int32_t iterz, int64_t iterw, argb_t *out)
{
    uint32_t c0v = R(g, REG_color0), c1v = R(g, REG_color1);
    argb_t color0 = { (int)VBIT(c0v, 24, 8), (int)VBIT(c0v, 16, 8),
                      (int)VBIT(c0v, 8, 8),  (int)VBIT(c0v, 0, 8) };
    argb_t color1 = { (int)VBIT(c1v, 24, 8), (int)VBIT(c1v, 16, 8),
                      (int)VBIT(c1v, 8, 8),  (int)VBIT(c1v, 0, 8) };

    /* c_other */
    argb_t cother;
    switch (CP_rgbselect(cp)) {
    case 0:  cother.r = iter.r;   cother.g = iter.g;   cother.b = iter.b;   break;
    case 1:  cother.r = texel.r;  cother.g = texel.g;  cother.b = texel.b;  break;
    case 2:  cother.r = color1.r; cother.g = color1.g; cother.b = color1.b; break;
    default: cother.r = cother.g = cother.b = 0; break;
    }
    /* chroma key test (basic V1 match), on c_other RGB, after rgbselect */
    if (FBZ_chromakey(fbz)) {
        uint32_t ck = R(g, REG_chromaKey) & 0xffffffu;
        uint32_t cv = (((uint32_t)(cother.r & 0xff)) << 16) |
                      (((uint32_t)(cother.g & 0xff)) << 8) |
                       ((uint32_t)(cother.b & 0xff));
        if (((cv ^ ck) & 0xffffffu) == 0)
            return false;
    }
    switch (CP_aselect(cp)) {
    case 0:  cother.a = iter.a;   break;
    case 1:  cother.a = texel.a;  break;
    case 2:  cother.a = color1.a; break;
    default: cother.a = 0; break;
    }
    /* alpha mask test, on a_other, after aselect */
    if (FBZ_alphamask(fbz) && (cother.a & 1) == 0)
        return false;

    /* c_local */
    argb_t clocal;
    if (CP_localovr(cp) == 0) {
        if (CP_localselect(cp) == 0) { clocal.r = iter.r;   clocal.g = iter.g;   clocal.b = iter.b; }
        else                         { clocal.r = color0.r; clocal.g = color0.g; clocal.b = color0.b; }
    } else {
        if (!(texel.a & 0x80))       { clocal.r = iter.r;   clocal.g = iter.g;   clocal.b = iter.b; }
        else                         { clocal.r = color0.r; clocal.g = color0.g; clocal.b = color0.b; }
    }
    switch (CP_cca_localsel(cp)) {
    default: clocal.a = iter.a; break;
    case 1:  clocal.a = color0.a; break;
    case 2:  clocal.a = (int)(uint8_t)(clamped_z(iterz, cp) >> 8); break;
    case 3:  clocal.a = (int)(uint8_t)clamped_w(iterw, cp); break;
    }

    /* select zero or other, subtract local */
    int br = CP_zero_other(cp) ? 0 : cother.r;
    int bg = CP_zero_other(cp) ? 0 : cother.g;
    int bb = CP_zero_other(cp) ? 0 : cother.b;
    int ba = CP_cca_zero(cp) ? 0 : cother.a;
    if (CP_sub_clocal(cp)) { br -= clocal.r; bg -= clocal.g; bb -= clocal.b; }
    if (CP_cca_sub(cp))    { ba -= clocal.a; }

    /* blend factors */
    int fr, fg, fb, fa;
    switch (CP_mselect(cp)) {
    default: fr = fg = fb = 0; break;
    case 1:  fr = clocal.r; fg = clocal.g; fb = clocal.b; break;
    case 2:  fr = fg = fb = cother.a; break;
    case 3:  fr = fg = fb = clocal.a; break;
    case 4:  fr = fg = fb = texel.a; break;
    case 5:  fr = texel.r; fg = texel.g; fb = texel.b; break;  /* V2 */
    }
    switch (CP_cca_mselect(cp)) {
    default: fa = 0; break;
    case 1: case 3: fa = clocal.a; break;
    case 2:  fa = cother.a; break;
    case 4:  fa = texel.a; break;
    }
    if (!CP_reverse(cp))     { fr ^= 0xff; fg ^= 0xff; fb ^= 0xff; }
    if (!CP_cca_reverse(cp)) { fa ^= 0xff; }

    /* add c_local / a_local */
    int ar, ag, ab, aa;
    switch (CP_add_aclocal(cp)) {
    case 1:  ar = clocal.r; ag = clocal.g; ab = clocal.b; break;
    case 2:  ar = ag = ab = clocal.a; break;
    default: ar = ag = ab = 0; break;                /* 0 and 3 (reserved) */
    }
    aa = CP_cca_add(cp) ? clocal.a : 0;

    /* (factor+1) multiply, >>8, add, clamp */
    fr++; fg++; fb++; fa++;
    argb_t cv;
    cv.r = iclamp(asr32(br * fr, 8) + ar, 0, 255);
    cv.g = iclamp(asr32(bg * fg, 8) + ag, 0, 255);
    cv.b = iclamp(asr32(bb * fb, 8) + ab, 0, 255);
    cv.a = iclamp(asr32(ba * fa, 8) + aa, 0, 255);

    if (CP_cca_invert(cp)) cv.a ^= 0xff;
    if (CP_invert(cp))     { cv.r ^= 0xff; cv.g ^= 0xff; cv.b ^= 0xff; }
    *out = cv;
    return true;
}

/* ================================================================== */
/*  fog — exact MAME apply_fogging (render.cpp:1896-1981)              */
/* ================================================================== */

/* Applies fog to `color` in place. fogcolor is the fogColor reg argb.
 * depthbias = zaColor; wfloat is the per-pixel wfloat; iterz/iterw the
 * iterators; itera = iterated alpha (for fog_zalpha==1). Alpha preserved. */
static void apply_fogging(const vgold_t *g, argb_t *color, uint32_t fogcolor,
                          uint32_t depthbias, uint32_t fbz, uint32_t fogmode,
                          uint32_t cp, int32_t wfloat, int32_t iterz,
                          int64_t iterw, int itera)
{
    argb_t fc = { (int)VBIT(fogcolor, 24, 8), (int)VBIT(fogcolor, 16, 8),
                  (int)VBIT(fogcolor, 8, 8),  (int)VBIT(fogcolor, 0, 8) };

    if (FOG_constant(fogmode)) {
        /* constant fog bypasses everything else */
        if (FOG_mult(fogmode) == 0) {
            fc.r = iclamp(fc.r + color->r, 0, 255);
            fc.g = iclamp(fc.g + color->g, 0, 255);
            fc.b = iclamp(fc.b + color->b, 0, 255);
        }
    } else {
        int32_t fogblend = 0;

        /* if fog_add is set, start with zero instead of the fog color */
        if (FOG_add(fogmode)) { fc.r = fc.g = fc.b = 0; }

        /* if fog_mult is zero, subtract the incoming color */
        if (!FOG_mult(fogmode)) {
            fc.r -= color->r; fc.g -= color->g; fc.b -= color->b;
        }

        switch (FOG_zalpha(fogmode)) {
        case 0: {       /* fog table */
            int32_t fog_depth = wfloat;
            if (FBZ_depthbias(fbz))
                fog_depth = iclamp(fog_depth + (int32_t)(int16_t)(uint16_t)(depthbias & 0xffff),
                                   0, 0xffff);
            int32_t delta = g->fogdelta[(fog_depth >> 10) & 0x3f];
            int32_t deltaval = (delta & 0xff) * ((fog_depth >> 2) & 0xff);  /* fogdelta_mask=0xff V1 */
            if (FOG_zones(fogmode) && (delta & 2))                          /* V2 */
                deltaval = -deltaval;
            deltaval >>= 6;
            /* fog_dither (V2) skipped */
            deltaval >>= 4;
            fogblend = g->fogblend[(fog_depth >> 10) & 0x3f] + deltaval;
            break;
        }
        case 1:         /* iterated A */
            fogblend = itera;
            break;
        case 2:         /* iterated Z */
            fogblend = clamped_z(iterz, cp) >> 8;
            break;
        case 3:         /* iterated W (V2) */
            fogblend = clamped_w(iterw, cp);
            break;
        }

        /* perform the blend: scale_imm_and_clamp(s16(fogblend)) */
        fogblend++;
        int16_t sf = (int16_t)fogblend;
        fc.r = iclamp(asr32(fc.r * sf, 8), 0, 255);
        fc.g = iclamp(asr32(fc.g * sf, 8), 0, 255);
        fc.b = iclamp(asr32(fc.b * sf, 8), 0, 255);
        if (FOG_mult(fogmode) == 0) {
            fc.r = iclamp(fc.r + color->r, 0, 255);
            fc.g = iclamp(fc.g + color->g, 0, 255);
            fc.b = iclamp(fc.b + color->b, 0, 255);
        }
    }

    /* preserve original alpha */
    color->r = fc.r; color->g = fc.g; color->b = fc.b;
}

/* ================================================================== */
/*  alpha blend — exact MAME alpha_blend (render.cpp:1990-2118)        */
/*  dst alpha = 255 this milestone (alpha-planes dst alpha is M4)      */
/* ================================================================== */

static int blend_rgb_scale(int mode, int sa, int da, int other_chan, int f15_chan)
{
    switch (mode & 0xf) {
    case 0:  return 0;                    /* AZERO */
    case 1:  return sa + 1;               /* ASRC_ALPHA */
    case 2:  return other_chan + 1;       /* A_COLOR (dst color for src factor,
                                           * src color for dst factor — caller
                                           * passes the right one) */
    case 3:  return da + 1;               /* ADST_ALPHA */
    case 4:  return 256;                  /* AONE */
    case 5:  return 0x100 - sa;           /* AOMSRC_ALPHA */
    case 6:  return 0x100 - other_chan;   /* AOM_COLOR */
    case 7:  return 0x100 - da;           /* AOMDST_ALPHA */
    case 15: return f15_chan + 1;         /* src: ASATURATE (caller passes
                                           * min(sa,0x100-da)); dst:
                                           * A_COLORBEFOREFOG (prefog chan) */
    default: return 0;                    /* reserved */
    }
}

static argb_t alpha_blend_full(uint32_t am, argb_t src, argb_t prefog, uint16_t dstpix)
{
    int dr, dg, db;
    from565(dstpix, &dr, &dg, &db);
    int da = 0xff;
    int sa = src.a;

    int srcmode = (int)AM_srcrgb(am);
    int dstmode = (int)AM_dstrgb(am);

    /* per-channel scales; the "color" referenced by A_COLOR/AOM_COLOR is the
     * DEST color for the source factor and the SOURCE color for the dest
     * factor; factor-15 differs per side (ASATURATE vs A_COLORBEFOREFOG). */
    int sat = 0x100 - da; if (sa < sat) sat = sa;
    int ssr = blend_rgb_scale(srcmode, sa, da, dr, sat);
    int ssg = blend_rgb_scale(srcmode, sa, da, dg, sat);
    int ssb = blend_rgb_scale(srcmode, sa, da, db, sat);
    int dsr = blend_rgb_scale(dstmode, sa, da, src.r, prefog.r);
    int dsg = blend_rgb_scale(dstmode, sa, da, src.g, prefog.g);
    int dsb = blend_rgb_scale(dstmode, sa, da, src.b, prefog.b);
    int sas = (AM_srca(am) == 4) ? 256 : 0;
    int das = (AM_dsta(am) == 4) ? 256 : 0;

    argb_t out;
    out.r = iclamp(asr32(src.r * ssr + dr * dsr, 8), 0, 255);
    out.g = iclamp(asr32(src.g * ssg + dg * dsg, 8), 0, 255);
    out.b = iclamp(asr32(src.b * ssb + db * dsb, 8), 0, 255);
    out.a = iclamp(asr32(sa * sas + da * das, 8), 0, 255);
    return out;
}

/* ================================================================== */
/*  per-pixel pipeline (M2 scope, spec §4 order)                       */
/* ================================================================== */

typedef struct {
    uint32_t fbz, cp, am, tm, fm;   /* fm = fogMode */
    uint32_t zacolor;
    uint32_t fogcolor;
    uint32_t destoffs;          /* byte offset of color buffer */
    bool     have_aux;
    int      yor;               /* effective y-origin */
    bool     texturing;
    int      lodbase;
    combine_ctl ctex;
    uint32_t stipple;           /* running stipple copy (mutated in rotate mode) */
} pipectx_t;

static void pixel_pipe(vgold_t *g, pipectx_t *c, int x, int y,
                       uint32_t ur, uint32_t ug, uint32_t ub, uint32_t ua,
                       uint32_t uz, uint64_t uw,
                       uint64_t us0, uint64_t ut0, uint64_t uw0)
{
    int sy = FBZ_yorigin(c->fbz) ? (c->yor - y) : y;

    /* 1) stipple test (spec §4 step 1, before wfloat) */
    if (FBZ_stipple(c->fbz)) {
        if (FBZ_stipplepat(c->fbz)) {
            int idx = ((sy & 3) << 3) | (~x & 7);
            if (((c->stipple >> idx) & 1) == 0)
                return;
        } else {
            c->stipple = rotr32(c->stipple, 1);
            if ((int32_t)c->stipple >= 0)
                return;
        }
    }

    /* 1b) wfloat */
    int32_t wfloat = wfloat_of((int64_t)uw);

    /* 2) depth value + test */
    int32_t depthval = FBZ_wbuffer(c->fbz) ? wfloat : clamped_z((int32_t)uz, c->cp);
    if (FBZ_depthbias(c->fbz)) {
        depthval += (int32_t)(int16_t)(uint16_t)(c->zacolor & 0xffff);
        depthval = iclamp(depthval, 0, 0xffff);
    }
    int32_t depthsrc = FBZ_depthsrc(c->fbz) ? (int32_t)(c->zacolor & 0xffff) : depthval;
    if (FBZ_depthen(c->fbz) && c->have_aux) {
        if (fb_word_ok(g, g->auxoffs, sy, x)) {
            int stored = g->fb[fb_word_index(g, g->auxoffs, sy, x)];
            if (!compare_func((int)FBZ_depthfn(c->fbz), depthsrc, stored))
                return;
        }
    }

    /* 3) color combine */
    argb_t iter;
    iter.r = clamp_argb_chan(ur, c->cp);
    iter.g = clamp_argb_chan(ug, c->cp);
    iter.b = clamp_argb_chan(ub, c->cp);
    iter.a = clamp_argb_chan(ua, c->cp);

    argb_t texel = { 255, 255, 255, 255 };
    if (c->texturing) {
        double diters = (double)(int64_t)us0;
        double ditert = (double)(int64_t)ut0;
        double diterw = (double)(int64_t)uw0;
        if (diterw == 0) diterw = 1;
        argb_t raw = fetch_texel(g, c->tm, diters, ditert, diterw, c->lodbase);
        argb_t zero = { 0, 0, 0, 0 };
        texel = combine_generic(c->ctex, zero, raw, raw.a, 0);
    }

    argb_t color;
    /* chroma key + alpha mask happen INSIDE combine; failure discards */
    if (!combine_color_full(g, c->cp, c->fbz, iter, texel, (int32_t)uz, (int64_t)uw, &color))
        return;

    /* 4) alpha test */
    if (AM_test(c->am) && !compare_func((int)AM_func(c->am), color.a, (int)AM_ref(c->am)))
        return;

    /* 5) fog (after alpha test, before alpha blend). prefog saved AFTER fog
     * (MAME saves prefog := post-combine color, then fogs into `color`; the
     * blend's A_COLORBEFOREFOG dst path uses prefog = pre-fog color). */
    argb_t prefog = color;
    if (FOG_enable(c->fm))
        apply_fogging(g, &color, c->fogcolor, c->zacolor, c->fbz, c->fm, c->cp,
                      wfloat, (int32_t)uz, (int64_t)uw, iter.a);

    /* 6) alpha blend */
    if (AM_blend(c->am)) {
        uint16_t dpix = 0;
        if (fb_word_ok(g, c->destoffs, sy, x))
            dpix = g->fb[fb_word_index(g, c->destoffs, sy, x)];
        color = alpha_blend_full(c->am, color, prefog, dpix);
    }

    /* 6) write (write masks honored; pixel counted regardless) */
    if (FBZ_rgbmask(c->fbz) && fb_word_ok(g, c->destoffs, sy, x))
        g->fb[fb_word_index(g, c->destoffs, sy, x)] =
            dither565(c->fbz, x, sy, color.r, color.g, color.b);
    if (FBZ_auxmask(c->fbz) && c->have_aux && fb_word_ok(g, g->auxoffs, sy, x))
        g->fb[fb_word_index(g, g->auxoffs, sy, x)] =
            FBZ_alphaplanes(c->fbz) ? (uint16_t)color.a : (uint16_t)depthval;
    g->regs[REG_fbiPixelsOut]++;
}

/* ================================================================== */
/*  triangle rasterizer — docs/raster-algorithm.md (NORMATIVE)         */
/* ================================================================== */

/* MAME poly.h round_coordinate: round-to-nearest, ties (.5 exactly) round
 * DOWN (floor). This is the FLOAT coverage rule the RTL mirrors in `real`. */
static int32_t round_coordinate(double v)
{
    double f = floor(v);
    return (int32_t)f + ((v - f) > 0.5 ? 1 : 0);
}

static void raster_triangle(vgold_t *g, uint32_t sign)
{
    (void)sign;
    pipectx_t c;
    c.fbz = R(g, REG_fbzMode);
    c.cp  = R(g, REG_fbzColorPath);
    c.am  = R(g, REG_alphaMode);
    c.tm  = R(g, REG_textureMode);
    c.fm  = R(g, REG_fogMode);
    c.zacolor = R(g, REG_zaColor);
    c.fogcolor = R(g, REG_fogColor);
    c.yor = yorigin_eff(g);
    c.have_aux = (g->auxoffs != ~0u);
    /* reseed the running stipple from the register at each primitive launch */
    c.stipple = R(g, REG_stipple);

    c.destoffs = draw_buffer_offs(g, (int)FBZ_drawbuf(c.fbz));
    if (c.destoffs == ~0u)
        return;

    c.texturing = CP_texenable(c.cp) && (c.tm != 0);
    c.lodbase = 0;
    memset(&c.ctex, 0, sizeof(c.ctex));
    if (c.texturing) {
        tex_recompute(g);
        c.lodbase = compute_lodbase(g->t0_ds_dx, g->t0_ds_dy, g->t0_dt_dx, g->t0_dt_dy);
        combine_ctl ct = {
            (int)TM_tc_zero(c.tm), (int)TM_tca_zero(c.tm),
            (int)TM_tc_sub(c.tm),  (int)TM_tca_sub(c.tm),
            (int)TM_tc_mselect(c.tm), (int)TM_tca_mselect(c.tm),
            (int)TM_tc_reverse(c.tm), (int)TM_tca_reverse(c.tm),
            (int)TM_tc_add(c.tm), (int)TM_tca_add(c.tm),
            (int)TM_tc_invert(c.tm), (int)TM_tca_invert(c.tm),
        };
        c.ctex = ct;
    }

    /* vertices: s16, 12.4 raw */
    int ax = (int)(int16_t)(uint16_t)R(g, REG_vertexAx);
    int ay = (int)(int16_t)(uint16_t)R(g, REG_vertexAy);
    int bx = (int)(int16_t)(uint16_t)R(g, REG_vertexBx);
    int by = (int)(int16_t)(uint16_t)R(g, REG_vertexBy);
    int cx = (int)(int16_t)(uint16_t)R(g, REG_vertexCx);
    int cy = (int)(int16_t)(uint16_t)R(g, REG_vertexCy);

    /* effective clip rect (rasterizer ALWAYS clips, CONTRACTS §9.9) */
    int cl, crr, ct_, cb;
    if (FBZ_clip(c.fbz)) {
        cl  = clip_min(R(g, REG_clipLeftRight));
        crr = clip_max(R(g, REG_clipLeftRight));
        ct_ = clip_min(R(g, REG_clipLowYHighY));
        cb  = clip_max(R(g, REG_clipLowYHighY));
    } else {
        cl = 0; crr = g->width; ct_ = 0; cb = g->height;
    }

    /* start values (unsigned working copies; mod 2^32 / 2^64) */
    uint32_t sr = (uint32_t)vsext(R(g, REG_startR), 24);
    uint32_t sg = (uint32_t)vsext(R(g, REG_startG), 24);
    uint32_t sb = (uint32_t)vsext(R(g, REG_startB), 24);
    uint32_t sa = (uint32_t)vsext(R(g, REG_startA), 24);
    uint32_t drdx = (uint32_t)vsext(R(g, REG_dRdX), 24), drdy = (uint32_t)vsext(R(g, REG_dRdY), 24);
    uint32_t dgdx = (uint32_t)vsext(R(g, REG_dGdX), 24), dgdy = (uint32_t)vsext(R(g, REG_dGdY), 24);
    uint32_t dbdx = (uint32_t)vsext(R(g, REG_dBdX), 24), dbdy = (uint32_t)vsext(R(g, REG_dBdY), 24);
    uint32_t dadx = (uint32_t)vsext(R(g, REG_dAdX), 24), dady = (uint32_t)vsext(R(g, REG_dAdY), 24);
    uint32_t sz = R(g, REG_startZ);
    uint32_t dzdx = R(g, REG_dZdX), dzdy = R(g, REG_dZdY);
    uint64_t sw = (uint64_t)g->fbi_startw;
    uint64_t dwdx = (uint64_t)g->fbi_dwdx, dwdy = (uint64_t)g->fbi_dwdy;
    uint64_t s0 = (uint64_t)g->t0_starts, ds0dx = (uint64_t)g->t0_ds_dx, ds0dy = (uint64_t)g->t0_ds_dy;
    uint64_t t0 = (uint64_t)g->t0_startt, dt0dx = (uint64_t)g->t0_dt_dx, dt0dy = (uint64_t)g->t0_dt_dy;
    uint64_t w0 = (uint64_t)g->t0_startw, dw0dx = (uint64_t)g->t0_dw_dx, dw0dy = (uint64_t)g->t0_dw_dy;

    /* subpixel start-value adjustment (fbzColorPath bit 26) — MAME signed form:
     * dxs = 8 - (ax & 15), dys = 8 - (ay & 15) (range -7..8), then
     * startP += (dxs*dPdX + dys*dPdY) >> 4 (arithmetic), full width mod 2^N. */
    if (CP_subpixel(c.cp)) {
        int32_t dxs = 8 - (ax & 15);
        int32_t dys = 8 - (ay & 15);
        sr += (uint32_t)asr32((int32_t)(dxs * (int32_t)drdx + dys * (int32_t)drdy), 4);
        sg += (uint32_t)asr32((int32_t)(dxs * (int32_t)dgdx + dys * (int32_t)dgdy), 4);
        sb += (uint32_t)asr32((int32_t)(dxs * (int32_t)dbdx + dys * (int32_t)dbdy), 4);
        sa += (uint32_t)asr32((int32_t)(dxs * (int32_t)dadx + dys * (int32_t)dady), 4);
        sz += (uint32_t)asr32((int32_t)(dxs * (int32_t)dzdx + dys * (int32_t)dzdy), 4);
        sw += (uint64_t)asr64((int64_t)dxs * (int64_t)dwdx + (int64_t)dys * (int64_t)dwdy, 4);
        s0 += (uint64_t)asr64((int64_t)dxs * (int64_t)ds0dx + (int64_t)dys * (int64_t)ds0dy, 4);
        t0 += (uint64_t)asr64((int64_t)dxs * (int64_t)dt0dx + (int64_t)dys * (int64_t)dt0dy, 4);
        w0 += (uint64_t)asr64((int64_t)dxs * (int64_t)dw0dx + (int64_t)dys * (int64_t)dw0dy, 4);
    }

    /* MAME float poly coverage (poly.h rule). Build float verts from the 12.4
     * coords (/16), sort by Y ascending (stable) into v1,v2,v3. The iterator
     * ORIGIN stays the ORIGINAL vertex-A register, floored: ox=ax>>4, oy=ay>>4
     * (arithmetic). Edge slopes are double dx/dy; per-scanline span endpoints
     * come from the long edge (v1->v3) and the appropriate minor edge, rounded
     * with round_coordinate (ties down), winding-agnostic (swap if start>stop),
     * EXCLUSIVE right. */
    typedef struct { double x, y; } fvert_t;
    fvert_t vv[3] = {
        { (double)ax * (1.0 / 16.0), (double)ay * (1.0 / 16.0) },
        { (double)bx * (1.0 / 16.0), (double)by * (1.0 / 16.0) },
        { (double)cx * (1.0 / 16.0), (double)cy * (1.0 / 16.0) },
    };
    /* stable sort of 3 by y ascending */
    if (vv[1].y < vv[0].y) { fvert_t t = vv[0]; vv[0] = vv[1]; vv[1] = t; }
    if (vv[2].y < vv[1].y) { fvert_t t = vv[1]; vv[1] = vv[2]; vv[2] = t; }
    if (vv[1].y < vv[0].y) { fvert_t t = vv[0]; vv[0] = vv[1]; vv[1] = t; }
    double v1x = vv[0].x, v1y = vv[0].y;
    double v2x = vv[1].x, v2y = vv[1].y;
    double v3x = vv[2].x, v3y = vv[2].y;

    double dxdy13 = (v3y != v1y) ? (v3x - v1x) / (v3y - v1y) : 0.0;
    double dxdy12 = (v2y != v1y) ? (v2x - v1x) / (v2y - v1y) : 0.0;
    double dxdy23 = (v3y != v2y) ? (v3x - v2x) / (v3y - v2y) : 0.0;

    int ox = asr32(ax, 4);                 /* iterator origin = floor(ax/16) */
    int oy = asr32(ay, 4);

    int iy1 = round_coordinate(v1y);
    int iy3 = round_coordinate(v3y);
    if (iy1 < ct_) iy1 = ct_;
    if (iy3 > cb)  iy3 = cb;

    for (int curscan = iy1; curscan < iy3; curscan++) {
        double fully = (double)curscan + 0.5;
        double startx = v1x + (fully - v1y) * dxdy13;
        double stopx  = (fully < v2y) ? v1x + (fully - v1y) * dxdy12
                                      : v2x + (fully - v2y) * dxdy23;
        int istartx = round_coordinate(startx);
        int istopx  = round_coordinate(stopx);
        if (istartx > istopx) { int tmp = istartx; istartx = istopx; istopx = tmp; }
        int left = istartx, right = istopx;       /* EXCLUSIVE right */
        if (left < cl)   left = cl;
        if (right > crr) right = crr;
        if (left >= right) continue;

        int dy = curscan - oy;
        uint32_t udy = (uint32_t)dy;
        uint64_t udy64 = (uint64_t)(int64_t)dy;
        for (int x = left; x < right; x++) {
            int dx = x - ox;
            uint32_t udx = (uint32_t)dx;
            uint64_t udx64 = (uint64_t)(int64_t)dx;
            pixel_pipe(g, &c, x, curscan,
                       sr + udx * drdx + udy * drdy,
                       sg + udx * dgdx + udy * dgdy,
                       sb + udx * dbdx + udy * dbdy,
                       sa + udx * dadx + udy * dady,
                       sz + udx * dzdx + udy * dzdy,
                       sw + udx64 * dwdx + udy64 * dwdy,
                       s0 + udx64 * ds0dx + udy64 * ds0dy,
                       t0 + udx64 * dt0dx + udy64 * dt0dy,
                       w0 + udx64 * dw0dx + udy64 * dw0dy);
        }
    }
}

/* ================================================================== */
/*  fastfill (MAME reg_fastfill_w / rasterizer_fastfill; CONTRACTS §9.3:
 *  dithered color1, clip-rect regs unconditionally, NO y-flip)        */
/* ================================================================== */

static void do_fastfill(vgold_t *g)
{
    uint32_t fbz = R(g, REG_fbzMode);
    uint32_t destoffs = draw_buffer_offs(g, (int)FBZ_drawbuf(fbz));
    if (destoffs == ~0u)
        return;
    bool have_aux = (g->auxoffs != ~0u);

    int cl = clip_min(R(g, REG_clipLeftRight));
    int cr = clip_max(R(g, REG_clipLeftRight));
    int ct = clip_min(R(g, REG_clipLowYHighY));
    int cb = clip_max(R(g, REG_clipLowYHighY));

    uint32_t c1 = R(g, REG_color1);
    int fr = (int)VBIT(c1, 16, 8), fg = (int)VBIT(c1, 8, 8), fb = (int)VBIT(c1, 0, 8);
    uint16_t zfill = (uint16_t)(R(g, REG_zaColor) & 0xffff);
    bool rgb_wr = FBZ_rgbmask(fbz);
    bool aux_wr = FBZ_auxmask(fbz);
    if (!rgb_wr && !aux_wr)
        return;

    uint32_t npix = 0;
    for (int y = ct; y < cb; y++) {
        for (int x = cl; x < cr; x++) {
            if (rgb_wr && fb_word_ok(g, destoffs, y, x))
                g->fb[fb_word_index(g, destoffs, y, x)] = dither565(fbz, x, y, fr, fg, fb);
            if (aux_wr && have_aux && fb_word_ok(g, g->auxoffs, y, x))
                g->fb[fb_word_index(g, g->auxoffs, y, x)] = zfill;
        }
        if (rgb_wr && cr > cl)
            npix += (uint32_t)(cr - cl);
    }
    g->regs[REG_fbiPixelsOut] += npix;
}

/* ================================================================== */
/*  buffer swap (immediate, CONTRACTS §9.4)                            */
/* ================================================================== */

static void swap_buffers(vgold_t *g)
{
    int buffers = (g->rgboffs[2] == ~0u) ? 2 : 3;
    g->frontbuf = (g->frontbuf + 1) % buffers;
    g->backbuf = (g->frontbuf + 1) % buffers;
}

/* ================================================================== */
/*  LFB access — exact MAME internal_lfb_w/expand_lfb_data/internal_lfb_r */
/* ================================================================== */

/* LFB present flags (mame_voodoo.h:463-472) */
#define LFB_RGB0   0x01u
#define LFB_A0     0x02u
#define LFB_D0     0x04u
#define LFB_DM0    0x08u
#define LFB_PIX0   0x0fu
#define LFB_RGB1   0x10u
#define LFB_A1     0x20u
#define LFB_D1     0x40u
#define LFB_PIX1   0x70u

/* expand a 32-bit raw datum to up to two ARGB + depth values; returns the
 * present mask (verbatim port of MAME expand_lfb_data, all 16 formats x 4
 * lane modes; unhandled/reserved formats produce mask 0) */
static uint32_t expand_lfb_data(const vgold_t *g, uint32_t lfb, uint32_t data,
                                argb_t col[2], uint16_t dep[2])
{
    uint32_t za = R(g, REG_zaColor);
    dep[0] = dep[1] = (uint16_t)(za & 0xffff);
    uint8_t src_alpha = (uint8_t)(za >> 24);
    argb_t z = { 0, 0, 0, 0 };
    col[0] = z; col[1] = z;

#define RGBX(i, d, rp, rw, gp, gw, bp, bw, av) do {          \
        col[i].r = expbits((d) >> (rp), rw);                 \
        col[i].g = expbits((d) >> (gp), gw);                 \
        col[i].b = expbits((d) >> (bp), bw);                 \
        col[i].a = (av);                                     \
    } while (0)
#define ARGBX(i, d, ap, rp, gp, bp, w0, w1, w2, w3) do {     \
        col[i].a = expbits((d) >> (ap), w0);                 \
        col[i].r = expbits((d) >> (rp), w1);                 \
        col[i].g = expbits((d) >> (gp), w2);                 \
        col[i].b = expbits((d) >> (bp), w3);                 \
    } while (0)

    switch (16 * LFB_lanes(lfb) + LFB_wformat(lfb)) {
    case 16*0 + 0:      /* ARGB, format 0: 16-bit RGB 5-6-5 */
    case 16*2 + 0:      /* RGBA, format 0 */
        RGBX(0, data, 11, 5,  5, 6,  0, 5, src_alpha);
        RGBX(1, data, 27, 5, 21, 6, 16, 5, src_alpha);
        return LFB_RGB0 | LFB_RGB1;
    case 16*1 + 0:      /* ABGR, format 0 */
    case 16*3 + 0:      /* BGRA, format 0 */
        RGBX(0, data,  0, 5,  5, 6, 11, 5, src_alpha);
        RGBX(1, data, 16, 5, 21, 6, 27, 5, src_alpha);
        return LFB_RGB0 | LFB_RGB1;

    case 16*0 + 1:      /* ARGB, format 1: 16-bit RGB x-5-5-5 */
        RGBX(0, data, 10, 5,  5, 5,  0, 5, src_alpha);
        RGBX(1, data, 26, 5, 21, 5, 16, 5, src_alpha);
        return LFB_RGB0 | LFB_RGB1;
    case 16*1 + 1:      /* ABGR, format 1 */
        RGBX(0, data,  0, 5,  5, 5, 10, 5, src_alpha);
        RGBX(1, data, 16, 5, 21, 5, 26, 5, src_alpha);
        return LFB_RGB0 | LFB_RGB1;
    case 16*2 + 1:      /* RGBA, format 1 */
        RGBX(0, data, 11, 5,  6, 5,  1, 5, src_alpha);
        RGBX(1, data, 27, 5, 22, 5, 17, 5, src_alpha);
        return LFB_RGB0 | LFB_RGB1;
    case 16*3 + 1:      /* BGRA, format 1 */
        RGBX(0, data,  1, 5,  6, 5, 11, 5, src_alpha);
        RGBX(1, data, 17, 5, 22, 5, 27, 5, src_alpha);
        return LFB_RGB0 | LFB_RGB1;

    case 16*0 + 2:      /* ARGB, format 2: 16-bit ARGB 1-5-5-5 */
        ARGBX(0, data, 15, 10,  5,  0, 1, 5, 5, 5);
        ARGBX(1, data, 31, 26, 21, 16, 1, 5, 5, 5);
        return LFB_RGB0 | LFB_A0 | LFB_RGB1 | LFB_A1;
    case 16*1 + 2:      /* ABGR, format 2 */
        ARGBX(0, data, 15,  0,  5, 10, 1, 5, 5, 5);
        ARGBX(1, data, 31, 16, 21, 26, 1, 5, 5, 5);
        return LFB_RGB0 | LFB_A0 | LFB_RGB1 | LFB_A1;
    case 16*2 + 2:      /* RGBA, format 2 */
        ARGBX(0, data,  0, 11,  6,  1, 1, 5, 5, 5);
        ARGBX(1, data, 16, 27, 22, 17, 1, 5, 5, 5);
        return LFB_RGB0 | LFB_A0 | LFB_RGB1 | LFB_A1;
    case 16*3 + 2:      /* BGRA, format 2 */
        ARGBX(0, data,  0,  1,  6, 11, 1, 5, 5, 5);
        ARGBX(1, data, 16, 17, 22, 27, 1, 5, 5, 5);
        return LFB_RGB0 | LFB_A0 | LFB_RGB1 | LFB_A1;

    case 16*0 + 4:      /* ARGB, format 4: 32-bit RGB x-8-8-8 */
        RGBX(0, data, 16, 8, 8, 8, 0, 8, src_alpha);
        return LFB_RGB0;
    case 16*1 + 4:      /* ABGR, format 4 */
        RGBX(0, data, 0, 8, 8, 8, 16, 8, src_alpha);
        return LFB_RGB0;
    case 16*2 + 4:      /* RGBA, format 4 */
        RGBX(0, data, 24, 8, 16, 8, 8, 8, src_alpha);
        return LFB_RGB0;
    case 16*3 + 4:      /* BGRA, format 4 */
        RGBX(0, data, 8, 8, 16, 8, 24, 8, src_alpha);
        return LFB_RGB0;

    case 16*0 + 5:      /* ARGB, format 5: 32-bit ARGB 8-8-8-8 */
        ARGBX(0, data, 24, 16, 8, 0, 8, 8, 8, 8);
        return LFB_RGB0 | LFB_A0;
    case 16*1 + 5:      /* ABGR, format 5 */
        ARGBX(0, data, 24, 0, 8, 16, 8, 8, 8, 8);
        return LFB_RGB0 | LFB_A0;
    case 16*2 + 5:      /* RGBA, format 5 */
        ARGBX(0, data, 0, 24, 16, 8, 8, 8, 8, 8);
        return LFB_RGB0 | LFB_A0;
    case 16*3 + 5:      /* BGRA, format 5 */
        ARGBX(0, data, 0, 8, 16, 24, 8, 8, 8, 8);
        return LFB_RGB0 | LFB_A0;

    case 16*0 + 12:     /* ARGB, format 12: 32-bit depth+RGB 5-6-5 */
    case 16*2 + 12:     /* RGBA, format 12 */
        RGBX(0, data, 11, 5, 5, 6, 0, 5, src_alpha);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_DM0;
    case 16*1 + 12:     /* ABGR, format 12 */
    case 16*3 + 12:     /* BGRA, format 12 */
        RGBX(0, data, 0, 5, 5, 6, 11, 5, src_alpha);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_DM0;

    case 16*0 + 13:     /* ARGB, format 13: 32-bit depth+RGB x-5-5-5 */
        RGBX(0, data, 10, 5, 5, 5, 0, 5, src_alpha);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_DM0;
    case 16*1 + 13:     /* ABGR, format 13 */
        RGBX(0, data, 0, 5, 5, 5, 10, 5, src_alpha);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_DM0;
    case 16*2 + 13:     /* RGBA, format 13 */
        RGBX(0, data, 11, 5, 6, 5, 1, 5, src_alpha);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_DM0;
    case 16*3 + 13:     /* BGRA, format 13 */
        RGBX(0, data, 1, 5, 6, 5, 11, 5, src_alpha);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_DM0;

    case 16*0 + 14:     /* ARGB, format 14: 32-bit depth+ARGB 1-5-5-5 */
        ARGBX(0, data, 15, 10, 5, 0, 1, 5, 5, 5);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_A0 | LFB_DM0;
    case 16*1 + 14:     /* ABGR, format 14 */
        ARGBX(0, data, 15, 0, 5, 10, 1, 5, 5, 5);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_A0 | LFB_DM0;
    case 16*2 + 14:     /* RGBA, format 14 */
        ARGBX(0, data, 0, 11, 6, 1, 1, 5, 5, 5);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_A0 | LFB_DM0;
    case 16*3 + 14:     /* BGRA, format 14 */
        ARGBX(0, data, 0, 1, 6, 11, 1, 5, 5, 5);
        dep[0] = (uint16_t)(data >> 16);
        return LFB_RGB0 | LFB_A0 | LFB_DM0;

    case 16*0 + 15:     /* format 15: 16-bit depth x2 (all lane modes) */
    case 16*1 + 15:
    case 16*2 + 15:
    case 16*3 + 15:
        dep[0] = (uint16_t)(data & 0xffff);
        dep[1] = (uint16_t)(data >> 16);
        return LFB_D0 | LFB_D1;

    default:            /* reserved formats: no effect */
        return 0;
    }
#undef RGBX
#undef ARGBX
}

/* LFB pixel-pipeline write of one expanded pixel (MAME pixel_pipeline,
 * render.cpp:2152). depthval is taken directly from src_depth (no bias);
 * the source color is the expanded LFB RGBA; iterz/iterw derive from sz and
 * zaColor exactly as MAME. y is the unflipped row. */
static void lfb_pixel_pipeline(vgold_t *g, int x, int y, argb_t src, uint16_t sz)
{
    uint32_t fbz = R(g, REG_fbzMode);
    uint32_t cp  = R(g, REG_fbzColorPath);
    uint32_t am  = R(g, REG_alphaMode);
    uint32_t fm  = R(g, REG_fogMode);
    uint32_t lfb = R(g, REG_lfbMode);
    uint32_t za  = R(g, REG_zaColor);

    int scry = FBZ_yorigin(fbz) ? (yorigin_eff(g) - y) : y;

    uint32_t destoffs = draw_buffer_offs(g, (int)LFB_wbufsel(lfb));
    if (destoffs == ~0u)
        return;
    bool have_aux = (g->auxoffs != ~0u);

    /* stipple (reseeded from the register each LFB pixel, per MAME) */
    if (FBZ_stipple(fbz)) {
        uint32_t stip = R(g, REG_stipple);
        if (FBZ_stipplepat(fbz)) {
            int idx = ((scry & 3) << 3) | (~x & 7);
            if (((stip >> idx) & 1) == 0)
                return;
        } else {
            stip = rotr32(stip, 1);
            if ((int32_t)stip >= 0)
                return;
        }
    }

    /* depth: value is directly sz (no biasing for LFB pipeline writes) */
    int32_t depthval = (int32_t)(uint32_t)sz;
    int32_t depthsrc = FBZ_depthsrc(fbz) ? (int32_t)(za & 0xffff) : depthval;
    if (FBZ_depthen(fbz) && have_aux) {
        if (fb_word_ok(g, g->auxoffs, scry, x)) {
            int stored = g->fb[fb_word_index(g, g->auxoffs, scry, x)];
            if (!compare_func((int)FBZ_depthfn(fbz), depthsrc, stored))
                return;
        }
    }

    /* combine: c_other/c_local source from the LFB color; chroma key + alpha
     * mask live inside combine. texel = white (no texturing on LFB writes). */
    argb_t texel = { 255, 255, 255, 255 };
    int32_t iterz = (int32_t)((uint32_t)sz << 12);
    /* iterw per MAME: write_w_select ? u32(za<<16) : u32(sz<<16). lfbMode
     * write_w_select is bit 1. */
    int64_t iterw = (int64_t)(uint32_t)(LFB_wsel(lfb) ? (za << 16) : ((uint32_t)sz << 16));

    argb_t color;
    if (!combine_color_full(g, cp, fbz, src, texel, iterz, iterw, &color))
        return;

    /* alpha test */
    if (AM_test(am) && !compare_func((int)AM_func(am), color.a, (int)AM_ref(am)))
        return;

    /* fog (wfloat = depthval; iterargb alpha = 0 per MAME rgbaint_t(0)) */
    argb_t prefog = color;
    if (FOG_enable(fm))
        apply_fogging(g, &color, R(g, REG_fogColor), za, fbz, fm, cp,
                      depthval, iterz, iterw, 0);

    /* alpha blend */
    if (AM_blend(am)) {
        uint16_t dpix = 0;
        if (fb_word_ok(g, destoffs, scry, x))
            dpix = g->fb[fb_word_index(g, destoffs, scry, x)];
        color = alpha_blend_full(am, color, prefog, dpix);
    }

    /* write */
    if (FBZ_rgbmask(fbz) && fb_word_ok(g, destoffs, scry, x))
        g->fb[fb_word_index(g, destoffs, scry, x)] =
            dither565(fbz, x, scry, color.r, color.g, color.b);
    if (FBZ_auxmask(fbz) && have_aux && fb_word_ok(g, g->auxoffs, scry, x))
        g->fb[fb_word_index(g, g->auxoffs, scry, x)] =
            FBZ_alphaplanes(fbz) ? (uint16_t)color.a : (uint16_t)depthval;
    g->regs[REG_fbiPixelsOut]++;
}

static void lfb_write(vgold_t *g, uint32_t dwoff, uint32_t data, uint32_t mem_mask)
{
    uint32_t lfb = R(g, REG_lfbMode);
    uint32_t fbz = R(g, REG_fbzMode);

    if (LFB_byteswz(lfb)) { data = bswap32(data); mem_mask = bswap32(mem_mask); }
    if (LFB_wswap(lfb))   { data = rot16(data); mem_mask = rot16(mem_mask); }

    argb_t col[2];
    uint16_t dep[2];
    uint32_t mask = expand_lfb_data(g, lfb, data, col, dep);

    /* two-pixel formats address two pixels per dword */
    uint32_t off = dwoff;
    if (mask & LFB_PIX1)
        off <<= 1;
    int x = (int)(off & 0x3ff);
    int y = (int)((off >> 10) & 0x3ff);

    /* present-mask vs mem_mask (exact MAME semantics) */
    if (!(mem_mask & 0x0000ffffu)) mask &= ~(LFB_PIX0 - LFB_DM0);     /* keep DM0 */
    if (!(mem_mask & 0xffff0000u)) mask &= ~(LFB_PIX1 + LFB_DM0);

    uint32_t destoffs = draw_buffer_offs(g, (int)LFB_wbufsel(lfb));
    if (destoffs == ~0u)
        return;
    bool have_aux = (g->auxoffs != ~0u);

    int scry = y;
    if (LFB_yorigin(lfb))
        scry = yorigin_eff(g) - y;

    /* pixel-pipeline path (lfbMode bit8): run the expanded src color/depth
     * through the full per-pixel pipeline (MAME internal_lfb_w tricky case). */
    if (LFB_pixpipe(lfb)) {
        int xx = x;
        for (uint32_t m = mask; m != 0; m >>= 4, xx++) {
            if (m & LFB_PIX0)
                lfb_pixel_pipeline(g, xx, y, col[(xx - x) & 1], dep[(xx - x) & 1]);
        }
        return;
    }

    /* raw path */
    for (int pix = 0; mask != 0; pix++) {
        if (mask & LFB_PIX0) {
            int px = x + pix;
            if ((mask & LFB_RGB0) && fb_word_ok(g, destoffs, scry, px))
                g->fb[fb_word_index(g, destoffs, scry, px)] =
                    dither565(fbz, px, scry, col[pix].r, col[pix].g, col[pix].b);
            if (have_aux) {
                if (FBZ_alphaplanes(fbz)) {
                    if ((mask & LFB_A0) && fb_word_ok(g, g->auxoffs, scry, px))
                        g->fb[fb_word_index(g, g->auxoffs, scry, px)] = (uint16_t)col[pix].a;
                } else {
                    if ((mask & (LFB_D0 | LFB_DM0)) && fb_word_ok(g, g->auxoffs, scry, px))
                        g->fb[fb_word_index(g, g->auxoffs, scry, px)] = dep[pix];
                }
            }
            /* pixel counted regardless of write masks */
            g->regs[REG_fbiPixelsOut]++;
        }
        mask >>= 4;
    }
}

static uint32_t lfb_read(vgold_t *g, uint32_t dwoff)
{
    uint32_t lfb = R(g, REG_lfbMode);
    uint32_t off = dwoff << 1;
    int x = (int)(off & 0x3ff);
    int scry = (int)((off >> 10) & 0x3ff);
    if (LFB_yorigin(lfb))
        scry = yorigin_eff(g) - scry;

    uint32_t boffs = lfb_buffer_offs(g, (int)LFB_rbufsel(lfb));
    if (boffs == ~0u)
        return 0xffffffffu;
    if (!fb_word_ok(g, boffs, scry, x) || !fb_word_ok(g, boffs, scry, (int64_t)x + 1))
        return 0xffffffffu;

    uint32_t w0 = fb_word_index(g, boffs, scry, x);
    uint32_t data = (uint32_t)g->fb[w0] | ((uint32_t)g->fb[w0 + 1] << 16);
    if (LFB_wswap_r(lfb))
        data = rot16(data);
    if (LFB_byteswz_r(lfb))
        data = bswap32(data);
    return data;
}

/* ================================================================== */
/*  texture download (voodoo_soft soft_tex_write, texmask 0x1fffff)    */
/* ================================================================== */

static void tex_write(vgold_t *g, uint32_t dwoff, uint32_t data)
{
    tex_recompute(g);

    uint32_t tlod = R(g, REG_tLOD);
    if (VBIT(tlod, 25, 1)) data = bswap32(data);   /* tdata_swizzle */
    if (VBIT(tlod, 26, 1)) data = rot16(data);     /* tdata_swap */

    int bpt = g->bpt;
    bool seq8 = VBIT(R(g, REG_textureMode), 31, 1) != 0;
    uint32_t lod = VBIT(dwoff, 15, 4);
    uint32_t tt  = VBIT(dwoff, 7, 8);
    uint32_t ts  = (dwoff << ((seq8 && bpt == 1) ? 2 : 1)) & 0xff;
    if (lod > 8)
        return;

    uint32_t smax = (uint32_t)(g->wmask >> lod);
    uint32_t offs = tt * (smax + 1) + ts;
    uint32_t base = (g->lodoffset[lod] + (((uint32_t)bpt * offs) & ~3u)) & TEX_MASK;

    if (bpt == 1) {
        for (int i = 0; i < 4; i++)
            g->texram[(base + (uint32_t)i) & TEX_MASK] = (uint8_t)((data >> (8 * i)) & 0xff);
    } else {
        uint32_t a0 = base & TEX_MASK & ~1u;
        uint32_t a1 = (base + 2) & TEX_MASK & ~1u;
        g->texram[a0]     = (uint8_t)(data & 0xff);
        g->texram[a0 + 1] = (uint8_t)((data >> 8) & 0xff);
        g->texram[a1]     = (uint8_t)((data >> 16) & 0xff);
        g->texram[a1 + 1] = (uint8_t)((data >> 24) & 0xff);
    }
}

/* ================================================================== */
/*  register write dispatch (voodoo_soft soft_reg_write port)          */
/* ================================================================== */

static void set_stw(vgold_t *g, int target, int64_t v)
{
    switch (target) {
    case REG_startS: g->t0_starts = v; break;
    case REG_dSdX:   g->t0_ds_dx = v; break;
    case REG_dSdY:   g->t0_ds_dy = v; break;
    case REG_startT: g->t0_startt = v; break;
    case REG_dTdX:   g->t0_dt_dx = v; break;
    case REG_dTdY:   g->t0_dt_dy = v; break;
    case REG_startW: g->fbi_startw = v; g->t0_startw = v; break;
    case REG_dWdX:   g->fbi_dwdx = v;   g->t0_dw_dx = v;  break;
    case REG_dWdY:   g->fbi_dwdy = v;   g->t0_dw_dy = v;  break;
    default: break;
    }
}
static inline bool is_s(int r) { return r == REG_startS || r == REG_dSdX || r == REG_dSdY; }
static inline bool is_t(int r) { return r == REG_startT || r == REG_dTdX || r == REG_dTdY; }
static inline bool is_w(int r) { return r == REG_startW || r == REG_dWdX || r == REG_dWdY; }

static void reg_write(vgold_t *g, uint32_t regnum, uint32_t data)
{
    regnum &= 0xff;

    /* float-form geometry registers (0x22..0x3f) -> fixed slots */
    if (regnum >= REG_fvertexAx && regnum <= REG_fdWdY) {
        int target = (int)regnum - 0x20;
        if (is_s(target) || is_t(target) || is_w(target)) {
            set_stw(g, target, float_to_int64(data, 32));
            return;
        }
        int fbits = (target >= REG_vertexAx && target <= REG_vertexCy) ? 4 : 12;
        g->regs[target] = (uint32_t)float_to_int32(data, fbits);
        return;
    }

    /* fixed-form S/T/W iterators */
    if (is_s((int)regnum) || is_t((int)regnum)) {
        set_stw(g, (int)regnum, shl64((int64_t)(int32_t)data, 14));
        return;
    }
    if (is_w((int)regnum)) {
        set_stw(g, (int)regnum, shl64((int64_t)(int32_t)data, 2));
        return;
    }

    /* fogTable write decode (regnum 0x58..0x77 -> write_fog), MAME-exact */
    if (regnum >= REG_fogTable && regnum <= 0x77) {
        uint32_t base = 2u * (regnum - REG_fogTable);
        g->fogdelta[base + 0] = (uint8_t)VBIT(data, 0, 8);
        g->fogblend[base + 0] = (uint8_t)VBIT(data, 8, 8);
        g->fogdelta[base + 1] = (uint8_t)VBIT(data, 16, 8);
        g->fogblend[base + 1] = (uint8_t)VBIT(data, 24, 8);
        g->regs[regnum] = data;
        return;
    }

    switch (regnum) {
    case REG_triangleCMD:
    case REG_ftriangleCMD:
        /* bit31 of the write data = rasterizer sign */
        raster_triangle(g, data >> 31);
        return;
    case REG_nopCMD:
        return;
    case REG_fastfillCMD:
        do_fastfill(g);
        return;
    case REG_swapbufferCMD:
        swap_buffers(g);
        return;

    case REG_fbiInit1:
    case REG_fbiInit2:
        g->regs[regnum] = data;
        recompute_video_memory(g);
        return;
    case REG_fbiInit3:
        g->regs[regnum] = data;
        g->yorigin = (int)VBIT(data, 22, 10);
        return;
    case REG_videoDimensions:
        g->regs[regnum] = data;
        recompute_dims(g);
        return;

    case REG_dacData: {
        int rn = (int)(VBIT(data, 8, 3) + 8 * VBIT(data, 12, 2));
        if (rn < 8) {
            if (!VBIT(data, 11, 1)) {
                g->dac_reg[rn] = (uint8_t)VBIT(data, 0, 8);
            } else {
                g->dac_read_result = g->dac_reg[rn];
                switch (g->dac_reg[7]) {
                case 0x01: g->dac_read_result = 0x55; break;
                case 0x07: g->dac_read_result = 0x71; break;
                case 0x0b: g->dac_read_result = 0x79; break;
                default: break;
                }
            }
        }
        g->regs[regnum] = data;
        return;
    }

    default:
        g->regs[regnum] = data;
        return;
    }
}

static uint32_t reg_read(vgold_t *g, uint32_t regnum)
{
    regnum &= 0xff;
    if (regnum == REG_status) {
        uint32_t s = 0x3f;                 /* PCI FIFO has free space */
        s |= 1u << 6;                      /* vertical retrace */
        s |= (uint32_t)(g->frontbuf & 3) << 10;
        s |= 0xffffu << 12;                /* memory FIFO empty */
        return s;
    }
    if (regnum == REG_fbiInit2) {
        if (g->init_enable & (1u << 2))
            return g->dac_read_result;
        return g->regs[regnum];
    }
    return g->regs[regnum];
}

/* ================================================================== */
/*  BAR decode (CONTRACTS §2)                                          */
/* ================================================================== */

void vgold_bar_write(vgold_t *g, uint32_t addr, uint32_t data, uint32_t mask)
{
    addr &= 0xffffffu;
    if (addr < 0x400000u) {
        uint32_t dwoff = (addr >> 2) & 0xfffffu;
        uint32_t regnum = dwoff & 0xff;
        uint32_t chipmask = (dwoff >> 8) & 0xf;
        if (chipmask == 0)
            chipmask = 0xf;
        (void)chipmask;     /* single-TMU config: consumers ignore chipmask */
        if ((dwoff & (1u << 18)) && (g->regs[REG_fbiInit0] & (1u << 3)))
            data = bswap32(data);
        if ((dwoff & (1u << 19)) && (g->regs[REG_fbiInit3] & 1u) && regnum < 0x40)
            regnum = alias_map[dwoff & 0x3f];
        reg_write(g, regnum, data);
    } else if (addr < 0x800000u) {
        lfb_write(g, (addr - 0x400000u) >> 2, data, mask);
    } else {
        tex_write(g, (addr - 0x800000u) >> 2, data);
    }
}

uint32_t vgold_bar_read(vgold_t *g, uint32_t addr)
{
    addr &= 0xffffffu;
    if (addr < 0x400000u) {
        uint32_t dwoff = (addr >> 2) & 0xfffffu;
        uint32_t regnum = dwoff & 0xff;
        /* alias applies to reads too; no swizzle on reads */
        if ((dwoff & (1u << 19)) && (g->regs[REG_fbiInit3] & 1u) && regnum < 0x40)
            regnum = alias_map[dwoff & 0x3f];
        return reg_read(g, regnum);
    }
    if (addr < 0x800000u)
        return lfb_read(g, (addr - 0x400000u) >> 2);
    return 0xffffffffu;     /* texture region is write-only */
}

void vgold_set_init_enable(vgold_t *g, uint32_t val)
{
    g->init_enable = val;
}

/* ================================================================== */
/*  lifecycle / inspection                                             */
/* ================================================================== */

vgold_t *vgold_create(void)
{
    vgold_t *g = calloc(1, sizeof(*g));
    if (!g)
        return NULL;
    g->fb = calloc(1, VGOLD_FB_BYTES);
    g->texram = calloc(1, VGOLD_TEX_BYTES);
    if (!g->fb || !g->texram) {
        free(g->fb);
        free(g->texram);
        free(g);
        return NULL;
    }
    /* defaults as in voodoo.c realize */
    g->width = 640;
    g->height = 480;
    g->rowpixels = 640;
    g->rgboffs[0] = 0;
    g->rgboffs[1] = 1u << 20;
    g->rgboffs[2] = ~0u;
    g->auxoffs = 2u << 20;
    g->frontbuf = 0;
    g->backbuf = 1;
    g->yorigin = 0;
    tex_default_palette(g);
    return g;
}

void vgold_destroy(vgold_t *g)
{
    if (!g)
        return;
    free(g->fb);
    free(g->texram);
    free(g);
}

const uint16_t *vgold_fb(const vgold_t *g)     { return g->fb; }
const uint8_t  *vgold_texram(const vgold_t *g) { return g->texram; }
int             vgold_frontbuf(const vgold_t *g) { return g->frontbuf; }

void vgold_layout(const vgold_t *g, uint32_t rgboffs[3], uint32_t *auxoffs,
                  uint32_t *rowpixels, int *w, int *h)
{
    if (rgboffs) {
        rgboffs[0] = g->rgboffs[0];
        rgboffs[1] = g->rgboffs[1];
        rgboffs[2] = g->rgboffs[2];
    }
    if (auxoffs)   *auxoffs = g->auxoffs;
    if (rowpixels) *rowpixels = g->rowpixels;
    if (w)         *w = g->width;
    if (h)         *h = g->height;
}

/* ================================================================== */
/*  trace replay (CONTRACTS §1)                                        */
/* ================================================================== */

typedef struct {
    uint8_t  op;
    uint8_t  flags;
    uint16_t _rsvd;
    uint32_t addr;
    uint32_t data;
    uint32_t mask;
} vvt_rec_t;

int vgold_run_trace(vgold_t *g, const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "vgold: cannot open %s\n", path);
        return -1;
    }
    char magic[4];
    uint32_t count;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "VVT1", 4) != 0 ||
        fread(&count, 4, 1, f) != 1) {
        fprintf(stderr, "vgold: %s: bad header\n", path);
        fclose(f);
        return -1;
    }
    int mismatches = 0;
    for (uint32_t i = 0; i < count; i++) {
        vvt_rec_t r;
        if (fread(&r, sizeof(r), 1, f) != 1) {
            fprintf(stderr, "vgold: %s: truncated at record %u/%u\n", path, i, count);
            fclose(f);
            return -1;
        }
        switch (r.op) {
        case 0:
            vgold_bar_write(g, r.addr, r.data, r.mask);
            break;
        case 1: {
            uint32_t v = vgold_bar_read(g, r.addr);
            if ((r.flags & 1) && v != r.data) {
                fprintf(stderr,
                        "vgold: %s: rec %u read 0x%06x = 0x%08x, expected 0x%08x\n",
                        path, i, r.addr, v, r.data);
                mismatches++;
            }
            break;
        }
        case 2:
            vgold_set_init_enable(g, r.data);
            break;
        case 3:
            break;  /* MARK */
        default:
            fprintf(stderr, "vgold: %s: rec %u unknown op %u\n", path, i, r.op);
            fclose(f);
            return -1;
        }
    }
    fclose(f);
    return mismatches;
}

/* ================================================================== */
/*  PPM dump (front buffer, rowpixels stride, 565 -> 888 replication)  */
/* ================================================================== */

int vgold_dump_ppm(const vgold_t *g, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return -1;
    fprintf(f, "P6\n%d %d\n255\n", g->width, g->height);
    uint32_t base = (g->rgboffs[g->frontbuf] == ~0u)
                    ? 0 : ((g->rgboffs[g->frontbuf] & FB_MASK) >> 1);
    for (int y = 0; y < g->height; y++) {
        for (int x = 0; x < g->width; x++) {
            uint32_t word = base + (uint32_t)y * g->rowpixels + (uint32_t)x;
            uint16_t p = (word < FB_WORDS) ? g->fb[word] : 0;
            int r, gg, b;
            from565(p, &r, &gg, &b);
            uint8_t rgb[3] = { (uint8_t)r, (uint8_t)gg, (uint8_t)b };
            if (fwrite(rgb, 1, 3, f) != 3) {
                fclose(f);
                return -1;
            }
        }
    }
    if (fclose(f) != 0)
        return -1;
    return 0;
}
