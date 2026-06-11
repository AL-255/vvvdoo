// ut_lfb.cpp — gold-level known-vector tests of the LFB raw-write expansion
// (CONTRACTS §8 M1 / §10 "make unit" test (b)), driven through
// vgold_bar_write into the LFB window (BAR + 0x400000).
//
// Default layout (vgold_create): 640x480, rowpixels 640, front buffer at
// word 0, back buffer at word 0x80000, aux at word 0x100000.
// LFB BAR addressing (1024-pixel stride): two-pixel formats dwoff =
// (y*1024 + x)/2; one-pixel formats dwoff = y*1024 + x.
//
// Expected values are computed locally from the documented formulas
// (bit-replication expand, MAME dither_helper) — not by calling gold code.

#include <cstdint>
#include <cstdio>

#include "voodoo_gold.h"

static int failures = 0;

#define CHECK(cond, ...) do {                              \
        if (!(cond)) {                                     \
            failures++;                                    \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);    \
            printf(__VA_ARGS__);                           \
            printf("\n");                                  \
        }                                                  \
    } while (0)

// register word indices
enum {
    REG_fbzMode = 0x44,
    REG_lfbMode = 0x45,
    REG_zaColor = 0x4c,
};

static const uint32_t FRONT_W = 0x00000u;   // front buffer base, 16-bit words
static const uint32_t BACK_W  = 0x80000u;   // back buffer
static const uint32_t AUX_W   = 0x100000u;  // aux (depth/alpha) buffer
static const uint32_t ROWPIX  = 640u;

static void vw(vgold_t *g, uint32_t regnum, uint32_t val)
{
    vgold_bar_write(g, regnum << 2, val, 0xffffffffu);
}

static void lfb_w2(vgold_t *g, int x, int y, uint32_t data)  // two-pixel fmts
{
    uint32_t dwoff = ((uint32_t)y * 1024u + (uint32_t)x) >> 1;
    vgold_bar_write(g, 0x400000u + dwoff * 4u, data, 0xffffffffu);
}

static void lfb_w1(vgold_t *g, int x, int y, uint32_t data)  // one-pixel fmts
{
    uint32_t dwoff = (uint32_t)y * 1024u + (uint32_t)x;
    vgold_bar_write(g, 0x400000u + dwoff * 4u, data, 0xffffffffu);
}

// ------------------------------------------------------------------
// documented formulas (raster-algorithm/CONTRACTS §8): 888 expansion by
// bit replication; MAME dither_helper 565 packing
// ------------------------------------------------------------------
static int expbits(uint32_t v, int n)
{
    switch (n) {
    case 5:  v &= 0x1f; return (int)((v << 3) | (v >> 2));
    case 6:  v &= 0x3f; return (int)((v << 2) | (v >> 4));
    default: return (int)(v & 0xff);
    }
}

static const int dither4x4[16] = { 0, 8, 2, 10, 12, 4, 14, 6,
                                   3, 11, 1, 9, 15, 7, 13, 5 };
static const int dither2x2[16] = { 8, 10, 8, 10, 11, 9, 11, 9,
                                   8, 10, 8, 10, 11, 9, 11, 9 };

// r,g,b in [0,255]; x = pixel x, y = post-flip scanline
static uint16_t dith565(int r, int g, int b, bool en, bool use2x2, int x, int y)
{
    if (!en)
        return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    int d = (use2x2 ? dither2x2 : dither4x4)[((y & 3) << 2) | (x & 3)];
    int r5 = ((r << 1) - (r >> 4) + (r >> 7) + d) >> 4;
    int g6 = ((g << 2) - (g >> 4) + (g >> 6) + d) >> 4;
    int b5 = ((b << 1) - (b >> 4) + (b >> 7) + d) >> 4;
    return (uint16_t)((r5 << 11) | (g6 << 5) | b5);
}

int main(void)
{
    // ---- format 0 (RGB565 x2, lanes 0=ARGB), dither OFF: exact round trip
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 0);                 // dither off
        vw(g, REG_lfbMode, 0);                 // fmt 0, front buffer
        const uint16_t p0 = 0x1234, p1 = 0xABCD;
        lfb_w2(g, 10, 20, ((uint32_t)p1 << 16) | p0);   // pixels (10,20),(11,20)
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[FRONT_W + 20 * ROWPIX + 10] == p0,
              "fmt0 px0: 0x%04x want 0x%04x", fb[FRONT_W + 20 * ROWPIX + 10], p0);
        CHECK(fb[FRONT_W + 20 * ROWPIX + 11] == p1,
              "fmt0 px1: 0x%04x want 0x%04x", fb[FRONT_W + 20 * ROWPIX + 11], p1);
        // CONTRACTS §9.2: fmt 0 carries no depth -> aux untouched
        CHECK(fb[AUX_W + 20 * ROWPIX + 10] == 0, "fmt0 must not write aux px0");
        CHECK(fb[AUX_W + 20 * ROWPIX + 11] == 0, "fmt0 must not write aux px1");
        vgold_destroy(g);
    }

    // ---- format 5 (ARGB8888, one pixel), dither ON (4x4) at (3,7) ----
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 1u << 8);           // dither enable, 4x4 type
        vw(g, REG_lfbMode, 5);
        lfb_w1(g, 3, 7, 0xAA80C040u);          // a=0xAA r=0x80 g=0xC0 b=0x40
        uint16_t want = dith565(0x80, 0xC0, 0x40, true, false, 3, 7);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[FRONT_W + 7 * ROWPIX + 3] == want,
              "fmt5 dithered: 0x%04x want 0x%04x", fb[FRONT_W + 7 * ROWPIX + 3], want);
        // fmt 5 carries no depth and alpha planes are off -> aux untouched
        CHECK(fb[AUX_W + 7 * ROWPIX + 3] == 0, "fmt5 must not write aux");
        vgold_destroy(g);
    }

    // ---- format 15 (16-bit depth x2): writes the aux buffer only ----
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 0);
        vw(g, REG_lfbMode, 15);
        lfb_w2(g, 100, 50, 0xBEEF1234u);       // dep0=0x1234 dep1=0xBEEF
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[AUX_W + 50 * ROWPIX + 100] == 0x1234,
              "fmt15 dep0: 0x%04x want 0x1234", fb[AUX_W + 50 * ROWPIX + 100]);
        CHECK(fb[AUX_W + 50 * ROWPIX + 101] == 0xBEEF,
              "fmt15 dep1: 0x%04x want 0xBEEF", fb[AUX_W + 50 * ROWPIX + 101]);
        CHECK(fb[FRONT_W + 50 * ROWPIX + 100] == 0, "fmt15 must not write color");
        CHECK(fb[FRONT_W + 50 * ROWPIX + 101] == 0, "fmt15 must not write color");
        vgold_destroy(g);
    }

    // ---- lanes != 0: format 5 with lanes=2 (RGBA) ----
    // RGBA dword: r=[31:24] g=[23:16] b=[15:8] a=[7:0]
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 0);
        vw(g, REG_lfbMode, 5u | (2u << 9));
        lfb_w1(g, 5, 9, 0x80C04020u);          // r=0x80 g=0xC0 b=0x40 a=0x20
        uint16_t want = dith565(0x80, 0xC0, 0x40, false, false, 5, 9);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[FRONT_W + 9 * ROWPIX + 5] == want,
              "fmt5 lanes=RGBA: 0x%04x want 0x%04x",
              fb[FRONT_W + 9 * ROWPIX + 5], want);
        vgold_destroy(g);
    }

    // ---- word_swap writes (lfbMode bit 11), fmt 0, BACK buffer ----
    // rot16 applies before expansion: pixel0 <- data[31:16], pixel1 <- data[15:0]
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 0);
        vw(g, REG_lfbMode, 0u | (1u << 4) | (1u << 11));  // back buffer select
        const uint16_t pHI = 0x5678, pLO = 0x9ABC;
        lfb_w2(g, 8, 3, ((uint32_t)pHI << 16) | pLO);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[BACK_W + 3 * ROWPIX + 8] == pHI,
              "wswap px0: 0x%04x want 0x%04x", fb[BACK_W + 3 * ROWPIX + 8], pHI);
        CHECK(fb[BACK_W + 3 * ROWPIX + 9] == pLO,
              "wswap px1: 0x%04x want 0x%04x", fb[BACK_W + 3 * ROWPIX + 9], pLO);
        // front buffer untouched
        CHECK(fb[FRONT_W + 3 * ROWPIX + 8] == 0, "wswap must target back buffer");
        vgold_destroy(g);
    }

    // ---- byte_swizzle writes (lfbMode bit 12), fmt 5 ----
    // bswap32 applies before expansion: 0x11223344 -> 0x44332211
    // -> a=0x44 r=0x33 g=0x22 b=0x11
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 0);
        vw(g, REG_lfbMode, 5u | (1u << 12));
        lfb_w1(g, 2, 1, 0x11223344u);
        uint16_t want = dith565(0x33, 0x22, 0x11, false, false, 2, 1);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[FRONT_W + 1 * ROWPIX + 2] == want,
              "byteswz: 0x%04x want 0x%04x", fb[FRONT_W + 1 * ROWPIX + 2], want);
        vgold_destroy(g);
    }

    // ---- format 1 (RGB555 x2), dither OFF: 555 -> replicated 888 -> 565 ----
    // (a second multi-bit format known-vector through the expand table)
    {
        vgold_t *g = vgold_create();
        vw(g, REG_fbzMode, 0);
        vw(g, REG_lfbMode, 1);
        const uint16_t q = 0x7FFF;             // white in x555
        lfb_w2(g, 0, 0, (uint32_t)q);          // pixel (0,0) only in low half
        int r, gg, b;
        r  = expbits((q >> 10) & 0x1f, 5);
        gg = expbits((q >> 5) & 0x1f, 5);
        b  = expbits(q & 0x1f, 5);
        uint16_t want = dith565(r, gg, b, false, false, 0, 0);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[FRONT_W + 0] == want,
              "fmt1: 0x%04x want 0x%04x", fb[FRONT_W + 0], want);
        // high half was 0 -> pixel (1,0) written as black (present, RGB=0)
        CHECK(fb[FRONT_W + 1] == 0, "fmt1 px1: 0x%04x want 0x0000", fb[FRONT_W + 1]);
        vgold_destroy(g);
    }

    if (failures) {
        printf("ut_lfb: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("ut_lfb: PASS\n");
    return 0;
}
