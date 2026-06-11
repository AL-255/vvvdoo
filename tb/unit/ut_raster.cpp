// ut_raster.cpp — gold-level unit test of the integer rasterization rule
// (docs/raster-algorithm.md §6 worked vectors + tie cases), driven purely
// through vgold_bar_write (CONTRACTS §10 "make unit", test (a)).
//
// Layout: vgold_create defaults — 640x480, rowpixels 640, front buffer at
// word 0.  Each sub-test uses a fresh vgold instance (calloc'd FB = all 0),
// so "covered" == nonzero fb word.

#include <cstdint>
#include <cstdio>

#include "voodoo_gold.h"

// register word indices (CONTRACTS §2 / voodoo_pkg.sv)
enum {
    REG_vertexAx     = 0x02,
    REG_vertexAy     = 0x03,
    REG_vertexBx     = 0x04,
    REG_vertexBy     = 0x05,
    REG_vertexCx     = 0x06,
    REG_vertexCy     = 0x07,
    REG_startR       = 0x08,
    REG_startG       = 0x09,
    REG_startB       = 0x0a,
    REG_startZ       = 0x0b,
    REG_startA       = 0x0c,
    REG_dRdX         = 0x10,
    REG_dGdX         = 0x11,
    REG_dBdX         = 0x12,
    REG_dZdX         = 0x13,
    REG_dAdX         = 0x14,
    REG_dRdY         = 0x18,
    REG_dGdY         = 0x19,
    REG_dBdY         = 0x1a,
    REG_dZdY         = 0x1b,
    REG_dAdY         = 0x1c,
    REG_triangleCMD  = 0x20,
    REG_fbzColorPath = 0x41,
    REG_fogMode      = 0x42,
    REG_alphaMode    = 0x43,
    REG_fbzMode      = 0x44,
};

static int failures = 0;

#define CHECK(cond, ...) do {                              \
        if (!(cond)) {                                     \
            failures++;                                    \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);    \
            printf(__VA_ARGS__);                           \
            printf("\n");                                  \
        }                                                  \
    } while (0)

static void vw(vgold_t *g, uint32_t regnum, uint32_t val)
{
    vgold_bar_write(g, regnum << 2, val, 0xffffffffu);
}

// program modes + vertices and fire triangleCMD.
// fbzMode: rgb mask on only (no depth, no dither, no clipping).
// fbzColorPath = 0: iterated RGB straight through (cc_mselect=0,
// reverse_blend=0 -> factor 0x100 -> c_other unchanged).
static void draw_tri(vgold_t *g, int ax, int ay, int bx, int by, int cx, int cy,
                     uint32_t sign, uint32_t startr, uint32_t drdx,
                     uint32_t startg)
{
    vw(g, REG_fbzMode, 1u << 9);
    vw(g, REG_fbzColorPath, 0);
    vw(g, REG_alphaMode, 0);
    vw(g, REG_fogMode, 0);
    vw(g, REG_vertexAx, (uint32_t)(uint16_t)(int16_t)ax);
    vw(g, REG_vertexAy, (uint32_t)(uint16_t)(int16_t)ay);
    vw(g, REG_vertexBx, (uint32_t)(uint16_t)(int16_t)bx);
    vw(g, REG_vertexBy, (uint32_t)(uint16_t)(int16_t)by);
    vw(g, REG_vertexCx, (uint32_t)(uint16_t)(int16_t)cx);
    vw(g, REG_vertexCy, (uint32_t)(uint16_t)(int16_t)cy);
    vw(g, REG_startR, startr);
    vw(g, REG_dRdX, drdx);
    vw(g, REG_dRdY, 0);
    vw(g, REG_startG, startg);
    vw(g, REG_dGdX, 0);
    vw(g, REG_dGdY, 0);
    vw(g, REG_startB, 0);
    vw(g, REG_dBdX, 0);
    vw(g, REG_dBdY, 0);
    vw(g, REG_startA, 0);
    vw(g, REG_dAdX, 0);
    vw(g, REG_dAdY, 0);
    vw(g, REG_startZ, 0);
    vw(g, REG_dZdX, 0);
    vw(g, REG_dZdY, 0);
    vw(g, REG_triangleCMD, sign << 31);
}

// flat-green triangle: every covered pixel == 0x07E0 (G=0xFF, R=B=0)
static void draw_flat(vgold_t *g, int ax, int ay, int bx, int by, int cx, int cy,
                      uint32_t sign)
{
    draw_tri(g, ax, ay, bx, by, cx, cy, sign, 0, 0, 0xFFu << 12);
}

// assert row y covers EXACTLY the pixel set [x0..x1] (x0 > x1 == empty row),
// each covered word equal to `val`
static void check_row(const uint16_t *fb, int y, int x0, int x1, uint16_t val,
                      const char *what)
{
    for (int x = 0; x < 640; x++) {
        uint16_t got = fb[y * 640 + x];
        bool in = (x >= x0 && x <= x1);
        if (in)
            CHECK(got == val, "%s: row %d x %d = 0x%04x, want 0x%04x",
                  what, y, x, got, val);
        else
            CHECK(got == 0, "%s: row %d x %d = 0x%04x, want EMPTY",
                  what, y, x, got);
    }
}

static int row_count(const uint16_t *fb, int y)
{
    int n = 0;
    for (int x = 0; x < 640; x++)
        if (fb[y * 640 + x] != 0)
            n++;
    return n;
}

int main(void)
{
    // ---- §6 worked triangle, flat color: exact pixel sets ----
    // A=(160,16) B=(32,144) C=(288,144), area < 0 -> sign = 1
    {
        vgold_t *g = vgold_create();
        draw_flat(g, 160, 16, 32, 144, 288, 144, 1);
        const uint16_t *fb = vgold_fb(g);
        check_row(fb, 0, 1, 0, 0x07E0, "worked row 0 empty");
        check_row(fb, 1, 9, 9, 0x07E0, "worked row 1 == {9}");
        check_row(fb, 8, 2, 16, 0x07E0, "worked row 8 == {2..16}");
        check_row(fb, 9, 1, 0, 0x07E0, "worked row 9 empty");
        vgold_destroy(g);
    }

    // ---- §6 iterator vector: startR=0x100000, dRdX=0x1000, dRdY=0 ----
    // R(9,1) = 0x100000 + (9-10)*0x1000 = 0xFF000 -> >>12 = 0xFF
    // -> fb word 0xF800 (dither off, G=B=0)
    {
        vgold_t *g = vgold_create();
        draw_tri(g, 160, 16, 32, 144, 288, 144, 1, 0x100000u, 0x1000u, 0);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[1 * 640 + 9] == 0xF800,
              "iterator at (9,1): fb=0x%04x, want 0xF800", fb[1 * 640 + 9]);
        vgold_destroy(g);
    }

    // ---- top tie IN: flat-top triangle, Ay=By=24 (row-1 center 1.5 == Ay)
    // ystart0 = (24+7)>>4 = 1 -> row 1 IS drawn (top tie included)
    {
        vgold_t *g = vgold_create();
        draw_flat(g, 160, 24, 32, 24, 288, 144, 1);
        const uint16_t *fb = vgold_fb(g);
        CHECK(row_count(fb, 0) == 0, "tie Ay=24: row 0 must be empty");
        CHECK(row_count(fb, 1) > 0, "tie Ay=24: row 1 must be drawn");
        vgold_destroy(g);
    }

    // ---- top tie shifted: Ay=By=25 -> ystart0 = (25+7)>>4 = 2 ----
    {
        vgold_t *g = vgold_create();
        draw_flat(g, 160, 25, 32, 25, 288, 144, 1);
        const uint16_t *fb = vgold_fb(g);
        CHECK(row_count(fb, 1) == 0, "tie Ay=25: row 1 must be empty");
        CHECK(row_count(fb, 2) > 0, "tie Ay=25: row 2 must be drawn");
        vgold_destroy(g);
    }

    // ---- bottom tie OUT: Cy=136 (row-8 center 8.5 == Cy) ----
    // yend0 = (136+7)>>4 = 8 (exclusive) -> row 8 NOT drawn
    {
        vgold_t *g = vgold_create();
        draw_flat(g, 160, 16, 32, 136, 288, 136, 1);
        const uint16_t *fb = vgold_fb(g);
        CHECK(row_count(fb, 8) == 0, "tie Cy=136: row 8 must NOT be drawn");
        CHECK(row_count(fb, 7) > 0, "tie Cy=136: row 7 must be drawn");
        vgold_destroy(g);
    }

    // ---- bottom tie shifted: Cy=137 -> yend0 = 9 -> row 8 IS drawn ----
    {
        vgold_t *g = vgold_create();
        draw_flat(g, 160, 16, 32, 137, 288, 137, 1);
        const uint16_t *fb = vgold_fb(g);
        CHECK(row_count(fb, 8) > 0, "tie Cy=137: row 8 must be drawn");
        vgold_destroy(g);
    }

    if (failures) {
        printf("ut_raster: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("ut_raster: PASS\n");
    return 0;
}
