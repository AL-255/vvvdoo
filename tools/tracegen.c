/*
 * tracegen — generate the milestone .vvt traces (CONTRACTS §4) by driving a
 * vgold instance through a recording wrapper: every generated access goes
 * both to the gold model and into the trace file. Also emits the golden
 * front-buffer PPM and full-FB CRC32 next to each trace.
 *
 *   tracegen <outdir>     (traces in <outdir>/, golden refs in <outdir>/golden/)
 *
 * Acts as a correct driver per docs/raster-algorithm.md §8: vertices sorted
 * ascending by y (stable), sign = ((Bx-Ax)*(Cy-Ay) - (Cx-Ax)*(By-Ay) < 0)
 * computed in int64 on the 12.4 ints, written as bit31 of (f)triangleCMD.
 *
 * Before generating anything it validates the worked vectors of
 * docs/raster-algorithm.md §6 (plus the tie rules) against the gold model.
 */
#define _POSIX_C_SOURCE 200809L
#include "voodoo_gold.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

/* ---------------- register word indices (voodoo_render.h) ------------- */
enum {
    REG_vertexAx = 0x02, REG_vertexAy = 0x03,
    REG_vertexBx = 0x04, REG_vertexBy = 0x05,
    REG_vertexCx = 0x06, REG_vertexCy = 0x07,
    REG_startR = 0x08, REG_startG = 0x09, REG_startB = 0x0a,
    REG_startZ = 0x0b, REG_startA = 0x0c,
    REG_startS = 0x0d, REG_startT = 0x0e, REG_startW = 0x0f,
    REG_dRdX = 0x10, REG_dGdX = 0x11, REG_dBdX = 0x12,
    REG_dZdX = 0x13, REG_dAdX = 0x14,
    REG_dSdX = 0x15, REG_dTdX = 0x16, REG_dWdX = 0x17,
    REG_dRdY = 0x18, REG_dGdY = 0x19, REG_dBdY = 0x1a,
    REG_dZdY = 0x1b, REG_dAdY = 0x1c,
    REG_dSdY = 0x1d, REG_dTdY = 0x1e, REG_dWdY = 0x1f,
    REG_triangleCMD = 0x20,
    REG_fvertexAx = 0x22, REG_fvertexAy = 0x23,
    REG_fvertexBx = 0x24, REG_fvertexBy = 0x25,
    REG_fvertexCx = 0x26, REG_fvertexCy = 0x27,
    REG_fstartR = 0x28, REG_fstartG = 0x29, REG_fstartB = 0x2a,
    REG_fstartZ = 0x2b, REG_fstartA = 0x2c,
    REG_fstartS = 0x2d, REG_fstartT = 0x2e, REG_fstartW = 0x2f,
    REG_fdRdX = 0x30, REG_fdGdX = 0x31, REG_fdBdX = 0x32,
    REG_fdZdX = 0x33, REG_fdAdX = 0x34,
    REG_fdSdX = 0x35, REG_fdTdX = 0x36, REG_fdWdX = 0x37,
    REG_fdRdY = 0x38, REG_fdGdY = 0x39, REG_fdBdY = 0x3a,
    REG_fdZdY = 0x3b, REG_fdAdY = 0x3c,
    REG_fdSdY = 0x3d, REG_fdTdY = 0x3e, REG_fdWdY = 0x3f,
    REG_ftriangleCMD = 0x40,
    REG_fbzColorPath = 0x41,
    REG_fogMode = 0x42,
    REG_alphaMode = 0x43,
    REG_fbzMode = 0x44,
    REG_lfbMode = 0x45,
    REG_clipLeftRight = 0x46,
    REG_clipLowYHighY = 0x47,
    REG_nopCMD = 0x48,
    REG_fastfillCMD = 0x49,
    REG_swapbufferCMD = 0x4a,
    REG_fogColor = 0x4b,
    REG_zaColor = 0x4c,
    REG_chromaKey = 0x4d,
    REG_stipple = 0x50,
    REG_color0 = 0x51,
    REG_color1 = 0x52,
    REG_fogTable = 0x58,
    REG_videoDimensions = 0x83,
    REG_fbiInit0 = 0x84,
    REG_fbiInit1 = 0x85,
    REG_fbiInit2 = 0x86,
    REG_fbiInit3 = 0x87,
    REG_dacData = 0x8b,
    REG_textureMode = 0xc0,
    REG_tLOD = 0xc1,
    REG_texBaseAddr = 0xc3,
};

/* ---------------- trace recording wrapper ----------------------------- */

typedef struct {
    uint8_t  op;
    uint8_t  flags;
    uint16_t rsvd;
    uint32_t addr;
    uint32_t data;
    uint32_t mask;
} rec_t;

static vgold_t *G;
static rec_t *recs;
static size_t nrec, ncap;

static void rpush(uint8_t op, uint8_t flags, uint32_t addr, uint32_t data, uint32_t mask)
{
    if (nrec == ncap) {
        ncap = ncap ? ncap * 2 : 4096;
        recs = realloc(recs, ncap * sizeof(rec_t));
        if (!recs) { fprintf(stderr, "tracegen: oom\n"); exit(1); }
    }
    recs[nrec].op = op;
    recs[nrec].flags = flags;
    recs[nrec].rsvd = 0;
    recs[nrec].addr = addr;
    recs[nrec].data = data;
    recs[nrec].mask = mask;
    nrec++;
}

static void wr(uint32_t addr, uint32_t data, uint32_t mask)
{
    vgold_bar_write(G, addr, data, mask);
    rpush(0, 0, addr, data, mask);
}
static uint32_t rd_cmp(uint32_t addr)
{
    uint32_t v = vgold_bar_read(G, addr);
    rpush(1, 1, addr, v, 0);
    return v;
}
static uint32_t rd_nocmp(uint32_t addr)
{
    uint32_t v = vgold_bar_read(G, addr);
    rpush(1, 0, addr, v, 0);
    return v;
}
static void tinit(uint32_t val)
{
    vgold_set_init_enable(G, val);
    rpush(2, 0, 0, val, 0);
}
static void mark(uint32_t tag) { rpush(3, 0, 0, tag, 0); }

static void regw(uint32_t regnum, uint32_t v) { wr(regnum << 2, v, 0xffffffffu); }

static void begin_trace(void)
{
    if (G)
        vgold_destroy(G);
    G = vgold_create();
    if (!G) { fprintf(stderr, "tracegen: oom\n"); exit(1); }
    nrec = 0;
}

/* zlib-polynomial CRC32 (init 0xffffffff, reflected, final xor) */
static uint32_t crc32_buf(const void *buf, size_t len)
{
    static uint32_t table[256];
    static int have_table = 0;
    if (!have_table) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++)
                c = (c & 1) ? (0xedb88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        have_table = 1;
    }
    uint32_t c = 0xffffffffu;
    const uint8_t *p = buf;
    for (size_t i = 0; i < len; i++)
        c = table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xffffffffu;
}

static void end_trace(const char *dir, const char *name)
{
    char path[1024];

    snprintf(path, sizeof(path), "%s/%s.vvt", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "tracegen: cannot write %s\n", path); exit(1); }
    uint32_t count = (uint32_t)nrec;
    if (fwrite("VVT1", 1, 4, f) != 4 || fwrite(&count, 4, 1, f) != 1 ||
        fwrite(recs, sizeof(rec_t), nrec, f) != nrec) {
        fprintf(stderr, "tracegen: short write %s\n", path);
        exit(1);
    }
    fclose(f);

    snprintf(path, sizeof(path), "%s/golden/%s.ppm", dir, name);
    if (vgold_dump_ppm(G, path) != 0) {
        fprintf(stderr, "tracegen: cannot write %s\n", path);
        exit(1);
    }

    snprintf(path, sizeof(path), "%s/golden/%s.fb.crc", dir, name);
    f = fopen(path, "w");
    if (!f) { fprintf(stderr, "tracegen: cannot write %s\n", path); exit(1); }
    fprintf(f, "%08x\n", crc32_buf(vgold_fb(G), VGOLD_FB_BYTES));
    fclose(f);

    printf("tracegen: %s.vvt  (%zu records)\n", name, nrec);
}

/* ---------------- driver-side triangle submission ---------------------- */

static uint32_t fbits(double v)
{
    union { float f; uint32_t u; } x;
    x.f = (float)v;
    return x.u;
}
static uint32_t c1212(double v) { return (uint32_t)(int32_t)lrint(v * 4096.0) & 0xffffff; }
static uint32_t z2012(double v) { return (uint32_t)(int32_t)lrint(v * 4096.0); }
static uint32_t st418(double v) { return (uint32_t)(int32_t)lrint(v * 262144.0); }      /* S/T int input */
static uint32_t w230(double v)  { return (uint32_t)(int32_t)lrint(v * 1073741824.0); }  /* W int input (2.30) */

typedef struct {
    double x, y;            /* pixels (quantized to 12.4) */
    double r, g, b, a;      /* 0..255 */
    double z;               /* depth units 0..65535 */
    double w;               /* FBI/TMU W value (2.30 input units) */
    double s, t;            /* TMU0 texel coords (driver units, see flags) */
    double q;               /* TMU0 W for the float S/T/W path */
} tvtx_t;

#define T_FLOAT 1u          /* use the float register path */
#define T_W     2u          /* program startW/dWdX/dWdY (integer 2.30 input) */
#define T_ST    4u          /* program S/T (integer input = value * 2^18) */
#define T_STWQ  8u          /* program S/T/W via float regs from s,t,q */

/* plane gradient through 3 (x,y,val) points; val at sorted vertex A is v[0] */
static void grad(const double px[3], const double py[3], const double v[3],
                 double *ddx, double *ddy)
{
    double dxb = px[1] - px[0], dyb = py[1] - py[0];
    double dxc = px[2] - px[0], dyc = py[2] - py[0];
    double det = dxb * dyc - dxc * dyb;
    if (fabs(det) < 1e-9) { *ddx = 0; *ddy = 0; return; }
    double db = v[1] - v[0], dc = v[2] - v[0];
    *ddx = (db * dyc - dc * dyb) / det;
    *ddy = (dc * dxb - db * dxc) / det;
}

static void tri_submit(const tvtx_t *v0, const tvtx_t *v1, const tvtx_t *v2,
                       unsigned flags)
{
    const tvtx_t *in[3] = { v0, v1, v2 };
    int xi[3], yi[3];
    for (int i = 0; i < 3; i++) {
        xi[i] = (int)lrint(in[i]->x * 16.0);
        yi[i] = (int)lrint(in[i]->y * 16.0);
    }
    /* stable sort ascending by y */
    int ord[3] = { 0, 1, 2 };
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2 - i; j++)
            if (yi[ord[j + 1]] < yi[ord[j]]) {
                int t = ord[j]; ord[j] = ord[j + 1]; ord[j + 1] = t;
            }
    const tvtx_t *sv[3] = { in[ord[0]], in[ord[1]], in[ord[2]] };
    int sx[3] = { xi[ord[0]], xi[ord[1]], xi[ord[2]] };
    int sy[3] = { yi[ord[0]], yi[ord[1]], yi[ord[2]] };

    /* sign from the int64 cross product on the 12.4 ints */
    int64_t area = (int64_t)(sx[1] - sx[0]) * (int64_t)(sy[2] - sy[0]) -
                   (int64_t)(sx[2] - sx[0]) * (int64_t)(sy[1] - sy[0]);
    uint32_t sign = (area < 0) ? 1u : 0u;

    double px[3], py[3];
    for (int i = 0; i < 3; i++) { px[i] = sx[i] / 16.0; py[i] = sy[i] / 16.0; }

#define GRAD3(field, gx, gy) do {                                      \
        double vv[3] = { sv[0]->field, sv[1]->field, sv[2]->field };   \
        grad(px, py, vv, &(gx), &(gy));                                \
    } while (0)

    double rdx, rdy, gdx, gdy, bdx, bdy, adx, ady, zdx, zdy;
    GRAD3(r, rdx, rdy);
    GRAD3(g, gdx, gdy);
    GRAD3(b, bdx, bdy);
    GRAD3(a, adx, ady);
    GRAD3(z, zdx, zdy);
    double wdx = 0, wdy = 0, sdx = 0, sdy = 0, tdx = 0, tdy = 0, qdx = 0, qdy = 0;
    if (flags & (T_W | T_STWQ))
        GRAD3(w, wdx, wdy);
    if (flags & (T_ST | T_STWQ)) {
        GRAD3(s, sdx, sdy);
        GRAD3(t, tdx, tdy);
    }
    if (flags & T_STWQ)
        GRAD3(q, qdx, qdy);
#undef GRAD3

    if (!(flags & T_FLOAT)) {
        regw(REG_vertexAx, (uint32_t)(uint16_t)(int16_t)sx[0]);
        regw(REG_vertexAy, (uint32_t)(uint16_t)(int16_t)sy[0]);
        regw(REG_vertexBx, (uint32_t)(uint16_t)(int16_t)sx[1]);
        regw(REG_vertexBy, (uint32_t)(uint16_t)(int16_t)sy[1]);
        regw(REG_vertexCx, (uint32_t)(uint16_t)(int16_t)sx[2]);
        regw(REG_vertexCy, (uint32_t)(uint16_t)(int16_t)sy[2]);
        regw(REG_startR, c1212(sv[0]->r));
        regw(REG_dRdX, c1212(rdx));
        regw(REG_dRdY, c1212(rdy));
        regw(REG_startG, c1212(sv[0]->g));
        regw(REG_dGdX, c1212(gdx));
        regw(REG_dGdY, c1212(gdy));
        regw(REG_startB, c1212(sv[0]->b));
        regw(REG_dBdX, c1212(bdx));
        regw(REG_dBdY, c1212(bdy));
        regw(REG_startA, c1212(sv[0]->a));
        regw(REG_dAdX, c1212(adx));
        regw(REG_dAdY, c1212(ady));
        regw(REG_startZ, z2012(sv[0]->z));
        regw(REG_dZdX, z2012(zdx));
        regw(REG_dZdY, z2012(zdy));
        if (flags & T_W) {
            regw(REG_startW, w230(sv[0]->w));
            regw(REG_dWdX, w230(wdx));
            regw(REG_dWdY, w230(wdy));
        }
        if (flags & T_ST) {
            regw(REG_startS, st418(sv[0]->s));
            regw(REG_dSdX, st418(sdx));
            regw(REG_dSdY, st418(sdy));
            regw(REG_startT, st418(sv[0]->t));
            regw(REG_dTdX, st418(tdx));
            regw(REG_dTdY, st418(tdy));
        }
        regw(REG_triangleCMD, sign << 31);
    } else {
        regw(REG_fvertexAx, fbits(px[0]));
        regw(REG_fvertexAy, fbits(py[0]));
        regw(REG_fvertexBx, fbits(px[1]));
        regw(REG_fvertexBy, fbits(py[1]));
        regw(REG_fvertexCx, fbits(px[2]));
        regw(REG_fvertexCy, fbits(py[2]));
        regw(REG_fstartR, fbits(sv[0]->r));
        regw(REG_fdRdX, fbits(rdx));
        regw(REG_fdRdY, fbits(rdy));
        regw(REG_fstartG, fbits(sv[0]->g));
        regw(REG_fdGdX, fbits(gdx));
        regw(REG_fdGdY, fbits(gdy));
        regw(REG_fstartB, fbits(sv[0]->b));
        regw(REG_fdBdX, fbits(bdx));
        regw(REG_fdBdY, fbits(bdy));
        regw(REG_fstartA, fbits(sv[0]->a));
        regw(REG_fdAdX, fbits(adx));
        regw(REG_fdAdY, fbits(ady));
        regw(REG_fstartZ, fbits(sv[0]->z));
        regw(REG_fdZdX, fbits(zdx));
        regw(REG_fdZdY, fbits(zdy));
        if (flags & T_STWQ) {
            regw(REG_fstartS, fbits(sv[0]->s));
            regw(REG_fdSdX, fbits(sdx));
            regw(REG_fdSdY, fbits(sdy));
            regw(REG_fstartT, fbits(sv[0]->t));
            regw(REG_fdTdX, fbits(tdx));
            regw(REG_fdTdY, fbits(tdy));
            regw(REG_fstartW, fbits(sv[0]->q));
            regw(REG_fdWdX, fbits(qdx));
            regw(REG_fdWdY, fbits(qdy));
        }
        regw(REG_ftriangleCMD, sign << 31);
    }
}

/* flat-shaded helper */
static tvtx_t fv(double x, double y, double r, double g, double b, double a, double z)
{
    tvtx_t v;
    memset(&v, 0, sizeof(v));
    v.x = x; v.y = y; v.r = r; v.g = g; v.b = b; v.a = a; v.z = z;
    return v;
}

/* ---------------- worked-vector self-check (raster-algorithm.md §6) ---- */

static int chk_fail;
static void expect(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "tracegen: SELF-CHECK FAILED: %s\n", what);
        chk_fail++;
    }
}

static void vw(vgold_t *v, uint32_t regnum, uint32_t val)
{
    vgold_bar_write(v, regnum << 2, val, 0xffffffffu);
}

/* draw a flat-red triangle from raw 12.4 vertex values; returns the fb */
static const uint16_t *chk_tri(vgold_t *v, int ax, int ay, int bx, int by,
                               int cx, int cy, uint32_t sign)
{
    vw(v, REG_fbzMode, 1u << 9);              /* rgb mask only; no clip/dither */
    vw(v, REG_fbzColorPath, 1u << 28);        /* iterated color, saturate */
    vw(v, REG_alphaMode, 0);
    vw(v, REG_vertexAx, (uint32_t)(uint16_t)(int16_t)ax);
    vw(v, REG_vertexAy, (uint32_t)(uint16_t)(int16_t)ay);
    vw(v, REG_vertexBx, (uint32_t)(uint16_t)(int16_t)bx);
    vw(v, REG_vertexBy, (uint32_t)(uint16_t)(int16_t)by);
    vw(v, REG_vertexCx, (uint32_t)(uint16_t)(int16_t)cx);
    vw(v, REG_vertexCy, (uint32_t)(uint16_t)(int16_t)cy);
    vw(v, REG_startR, 0x100000);              /* 256.0 at pA, sloping down in -x */
    vw(v, REG_dRdX, 0x1000);
    vw(v, REG_dRdY, 0);
    vw(v, REG_startG, 0); vw(v, REG_dGdX, 0); vw(v, REG_dGdY, 0);
    vw(v, REG_startB, 0); vw(v, REG_dBdX, 0); vw(v, REG_dBdY, 0);
    vw(v, REG_startA, 0); vw(v, REG_dAdX, 0); vw(v, REG_dAdY, 0);
    vw(v, REG_startZ, 0); vw(v, REG_dZdX, 0); vw(v, REG_dZdY, 0);
    vw(v, REG_triangleCMD, sign << 31);
    return vgold_fb(v);
}

static void row_extent(const uint16_t *fb, int y, int *x0, int *x1, int *count)
{
    *x0 = -1; *x1 = -1; *count = 0;
    for (int x = 0; x < 640; x++) {
        if (fb[y * 640 + x] != 0) {
            if (*x0 < 0) *x0 = x;
            *x1 = x;
            (*count)++;
        }
    }
}

static void selfcheck(void)
{
    /* the §6 worked triangle: A=(160,16) B=(32,144) C=(288,144), sign=1 */
    vgold_t *v = vgold_create();
    const uint16_t *fb = chk_tri(v, 160, 16, 32, 144, 288, 144, 1);
    int x0, x1, n;
    row_extent(fb, 0, &x0, &x1, &n);
    expect(n == 0, "§6 row 0 must be empty");
    row_extent(fb, 1, &x0, &x1, &n);
    expect(n == 1 && x0 == 9 && x1 == 9, "§6 row 1 pixels == {9}");
    expect(fb[1 * 640 + 9] == 0xF800, "§6 iterator at (9,1): R==0xFF -> 0xF800");
    row_extent(fb, 8, &x0, &x1, &n);
    expect(n == 15 && x0 == 2 && x1 == 16, "§6 row 8 pixels == 2..16");
    row_extent(fb, 9, &x0, &x1, &n);
    expect(n == 0, "§6 row 9 must be empty");
    vgold_destroy(v);

    /* top tie IN: flat-top triangle with Ay=24 (center 1.5 == Ay) */
    v = vgold_create();
    fb = chk_tri(v, 160, 24, 32, 24, 288, 144, 1);
    row_extent(fb, 1, &x0, &x1, &n);
    expect(n > 0, "tie: Ay=24 row 1 IS drawn");
    row_extent(fb, 0, &x0, &x1, &n);
    expect(n == 0, "tie: Ay=24 row 0 empty");
    vgold_destroy(v);

    /* top tie shifted: Ay=25 -> ystart0=2, row 1 must be empty */
    v = vgold_create();
    fb = chk_tri(v, 160, 25, 32, 25, 288, 144, 1);
    row_extent(fb, 1, &x0, &x1, &n);
    expect(n == 0, "tie: Ay=25 row 1 NOT drawn");
    row_extent(fb, 2, &x0, &x1, &n);
    expect(n > 0, "tie: Ay=25 row 2 drawn");
    vgold_destroy(v);

    /* bottom tie OUT: Cy=136 (center 8.5 == Cy) -> row 8 NOT drawn */
    v = vgold_create();
    fb = chk_tri(v, 160, 16, 32, 136, 288, 136, 1);
    row_extent(fb, 8, &x0, &x1, &n);
    expect(n == 0, "tie: Cy=136 row 8 NOT drawn");
    row_extent(fb, 7, &x0, &x1, &n);
    expect(n > 0, "tie: Cy=136 row 7 drawn");
    vgold_destroy(v);

    if (chk_fail) {
        fprintf(stderr, "tracegen: %d self-check failure(s); aborting\n", chk_fail);
        exit(1);
    }
    printf("tracegen: raster-rule self-check OK\n");
}

/* ---------------- common register init -------------------------------- */

static void common_init(void)
{
    tinit(0x00000001);                      /* enable_hw_init */
    regw(REG_fbiInit2, 256u << 11);         /* buffer_pages=256 -> 1MB spacing */
    regw(REG_fbiInit1, 10u << 4);           /* x_video_tiles=10 -> rowpixels 640 */
    regw(REG_fbiInit3, 479u << 22);         /* yorigin = 479 */
    regw(REG_videoDimensions, (480u << 16) | 640u);
    regw(REG_clipLeftRight, (0u << 16) | 640u);
    regw(REG_clipLowYHighY, (0u << 16) | 480u);
}

/* base fbzMode: clip on, depth on (less), dither 4x4, rgb+aux, draw=back */
#define FBZ_BASE ((1u<<0)|(1u<<4)|(1u<<5)|(1u<<8)|(1u<<9)|(1u<<10)|(1u<<14))

/* ---------------- m1: fastfill + LFB ----------------------------------- */

static uint32_t prng_state = 0x12345678u;
static uint32_t prng(void)
{
    uint32_t x = prng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    prng_state = x;
    return x;
}

/* LFB dword addresses: two-pixel formats pack 2 pixels/dword */
static uint32_t lfb_addr2(int x, int y) { return 0x400000u + (((uint32_t)y * 512u + (uint32_t)x / 2u) << 2); }
static uint32_t lfb_addr1(int x, int y) { return 0x400000u + (((uint32_t)y * 1024u + (uint32_t)x) << 2); }

static void gen_m1(const char *dir)
{
    begin_trace();
    common_init();

    /* ---- fastfills ---- */
    mark(0x1100);
    regw(REG_fbzMode, FBZ_BASE & ~(1u << 4));      /* dither 4x4, no depth test */
    regw(REG_color1, 0x00102840);                  /* dark blue */
    regw(REG_zaColor, 0x0000ffff);
    regw(REG_fastfillCMD, 0);

    mark(0x1101);                                  /* clipped fill, 2x2 dither */
    regw(REG_clipLeftRight, (40u << 16) | 600u);
    regw(REG_clipLowYHighY, (300u << 16) | 460u);
    regw(REG_fbzMode, (FBZ_BASE & ~(1u << 4)) | (1u << 11));
    regw(REG_color1, 0x00d06030);
    regw(REG_zaColor, 0x00004e20);
    regw(REG_fastfillCMD, 0);

    mark(0x1102);                                  /* no-dither fill */
    regw(REG_clipLeftRight, (60u << 16) | 240u);
    regw(REG_clipLowYHighY, (320u << 16) | 440u);
    regw(REG_fbzMode, (1u << 9) | (1u << 10) | (1u << 14));
    regw(REG_color1, 0x004080c0);
    regw(REG_zaColor, 0x00003333);
    regw(REG_fastfillCMD, 0);

    mark(0x1103);                                  /* aux-only fill (rgb mask off) */
    regw(REG_clipLeftRight, (300u << 16) | 400u);
    regw(REG_clipLowYHighY, (330u << 16) | 430u);
    regw(REG_fbzMode, (1u << 10) | (1u << 14));
    regw(REG_zaColor, 0x00001234);
    regw(REG_fastfillCMD, 0);

    mark(0x1104);                                  /* rgb-only fill (aux mask off) */
    regw(REG_clipLeftRight, (420u << 16) | 560u);
    regw(REG_clipLowYHighY, (330u << 16) | 430u);
    regw(REG_fbzMode, (1u << 8) | (1u << 9) | (1u << 14));
    regw(REG_color1, 0x00c0c030);
    regw(REG_fastfillCMD, 0);

    /* restore full clip + dithered mode for the LFB sections */
    regw(REG_clipLeftRight, (0u << 16) | 640u);
    regw(REG_clipLowYHighY, (0u << 16) | 480u);
    regw(REG_fbzMode, FBZ_BASE & ~(1u << 4));
    regw(REG_zaColor, 0x5a000f0fu);                /* default LFB alpha/depth */

    /* ---- LFB writes: formats 0/1/2/4/5 x lanes 0..3 ---- */
    mark(0x1200);
    static const int fmts2[3] = { 0, 1, 2 };       /* two-pixel formats */
    for (int fi = 0; fi < 3; fi++) {
        for (int lanes = 0; lanes < 4; lanes++) {
            regw(REG_lfbMode, (uint32_t)fmts2[fi] | (1u << 4) | ((uint32_t)lanes << 9));
            int x0 = 32 + lanes * 48, y0 = 30 + fi * 20;
            for (int row = 0; row < 4; row++)
                for (int i = 0; i < 8; i++)
                    wr(lfb_addr2(x0 + 2 * i, y0 + row), prng(), 0xffffffffu);
        }
    }
    static const int fmts1[2] = { 4, 5 };          /* one-pixel formats */
    for (int fi = 0; fi < 2; fi++) {
        for (int lanes = 0; lanes < 4; lanes++) {
            regw(REG_lfbMode, (uint32_t)fmts1[fi] | (1u << 4) | ((uint32_t)lanes << 9));
            int x0 = 32 + lanes * 48, y0 = 100 + fi * 20;
            for (int row = 0; row < 4; row++)
                for (int i = 0; i < 16; i++)
                    wr(lfb_addr1(x0 + i, y0 + row), prng(), 0xffffffffu);
        }
    }

    /* ---- word swap / byte swizzle writes ---- */
    mark(0x1201);
    regw(REG_lfbMode, 0u | (1u << 4) | (1u << 11));               /* fmt0 + word swap */
    for (int i = 0; i < 16; i++)
        wr(lfb_addr2(240 + 2 * i, 30), prng(), 0xffffffffu);
    regw(REG_lfbMode, 0u | (1u << 4) | (1u << 12));               /* fmt0 + byte swizzle */
    for (int i = 0; i < 16; i++)
        wr(lfb_addr2(240 + 2 * i, 34), prng(), 0xffffffffu);
    regw(REG_lfbMode, 5u | (1u << 4) | (1u << 11) | (1u << 12));  /* fmt5 + both */
    for (int i = 0; i < 16; i++)
        wr(lfb_addr1(240 + i, 38), prng(), 0xffffffffu);

    /* ---- partial mem_mask writes ---- */
    mark(0x1202);
    regw(REG_lfbMode, 0u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr2(320 + 2 * i, 30), prng(), 0x0000ffffu);      /* pixel 0 only */
    for (int i = 0; i < 8; i++)
        wr(lfb_addr2(320 + 2 * i, 32), prng(), 0xffff0000u);      /* pixel 1 only */
    regw(REG_lfbMode, 5u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr1(320 + i, 34), prng(), 0x0000ffffu);
    for (int i = 0; i < 8; i++)
        wr(lfb_addr1(320 + i, 36), prng(), 0xffff0000u);          /* dropped */
    regw(REG_lfbMode, 12u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr1(320 + i, 38), prng(), 0xffff0000u);          /* depth MSW only */
    regw(REG_lfbMode, 15u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr2(320 + 2 * i, 40), prng(), 0x0000ffffu);      /* depth pix 0 only */

    /* ---- depth-bearing formats 12/13/14/15 ---- */
    mark(0x1203);
    for (int fmt = 12; fmt <= 14; fmt++) {
        for (int lanes = 0; lanes < 4; lanes++) {
            regw(REG_lfbMode, (uint32_t)fmt | (1u << 4) | ((uint32_t)lanes << 9));
            int x0 = 32 + lanes * 48, y0 = 150 + (fmt - 12) * 10;
            for (int i = 0; i < 12; i++)
                wr(lfb_addr1(x0 + i, y0), prng(), 0xffffffffu);
        }
    }
    regw(REG_lfbMode, 15u | (1u << 4));
    for (int i = 0; i < 16; i++)
        wr(lfb_addr2(32 + 2 * i, 184), prng(), 0xffffffffu);

    /* ---- reserved formats: must be no-ops ---- */
    mark(0x1204);
    static const int resfmt[4] = { 3, 6, 9, 11 };
    for (int fi = 0; fi < 4; fi++) {
        regw(REG_lfbMode, (uint32_t)resfmt[fi] | (1u << 4));
        for (int i = 0; i < 4; i++)
            wr(lfb_addr1(400 + i, 150 + fi), prng(), 0xffffffffu);
    }

    /* ---- alpha planes (fbzMode bit18): ALPHA-present writes go to aux ---- */
    mark(0x1205);
    regw(REG_fbzMode, (FBZ_BASE & ~(1u << 4)) | (1u << 18));
    regw(REG_lfbMode, 2u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr2(440 + 2 * i, 150), prng(), 0xffffffffu);
    regw(REG_lfbMode, 5u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr1(440 + i, 152), prng(), 0xffffffffu);
    regw(REG_lfbMode, 14u | (1u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr1(440 + i, 154), prng(), 0xffffffffu);
    regw(REG_fbzMode, FBZ_BASE & ~(1u << 4));

    /* ---- y-origin flipped writes ---- */
    mark(0x1206);
    regw(REG_lfbMode, 0u | (1u << 4) | (1u << 13));
    for (int row = 0; row < 4; row++)
        for (int i = 0; i < 8; i++)
            wr(lfb_addr2(540 + 2 * i, 250 + row), prng(), 0xffffffffu);

    /* ---- writes to front buffer and to absent buffer (sel=2 dropped) ---- */
    mark(0x1207);
    regw(REG_lfbMode, 0u | (0u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr2(100 + 2 * i, 470), prng(), 0xffffffffu);
    regw(REG_lfbMode, 0u | (2u << 4));
    for (int i = 0; i < 8; i++)
        wr(lfb_addr2(100 + 2 * i, 472), prng(), 0xffffffffu);     /* dropped */

    /* ---- LFB reads (compare) ---- */
    mark(0x1300);
    regw(REG_lfbMode, 0u | (1u << 4) | (1u << 6));                /* read back buffer */
    for (int i = 0; i < 16; i++)
        rd_cmp(lfb_addr2(32 + 2 * i, 31));
    regw(REG_lfbMode, 0u | (1u << 6) | (1u << 15));               /* + word swap reads */
    for (int i = 0; i < 8; i++)
        rd_cmp(lfb_addr2(32 + 2 * i, 51));
    regw(REG_lfbMode, 0u | (1u << 6) | (1u << 16));               /* + byte swizzle reads */
    for (int i = 0; i < 8; i++)
        rd_cmp(lfb_addr2(64 + 2 * i, 102));
    regw(REG_lfbMode, 0u | (2u << 6));                            /* read aux */
    for (int i = 0; i < 8; i++)
        rd_cmp(lfb_addr2(320 + 2 * i, 350));
    regw(REG_lfbMode, 0u | (0u << 6));                            /* read front */
    for (int i = 0; i < 8; i++)
        rd_cmp(lfb_addr2(100 + 2 * i, 470));
    regw(REG_lfbMode, 0u | (1u << 6) | (1u << 13));               /* y-origin reads */
    for (int i = 0; i < 8; i++)
        rd_cmp(lfb_addr2(540 + 2 * i, 250));

    /* ---- dacData FSM + fbiInit2 read remap ---- */
    mark(0x1400);
    regw(REG_dacData, (7u << 8) | 0x01u);          /* write dac reg 7 = 0x01 */
    regw(REG_dacData, (7u << 8) | (1u << 11));     /* read dac reg 7 */
    tinit(0x00000005);                             /* remap fbiInit2 -> dac result */
    rd_cmp(REG_fbiInit2 << 2);                     /* = 0x55 */
    tinit(0x00000001);
    rd_cmp(REG_fbiInit2 << 2);                     /* = the real register */

    /* ---- register swizzle + alias decode ---- */
    mark(0x1401);
    regw(REG_fbiInit0, 1u << 3);                   /* swizzle on (addr bit20) */
    wr(((1u << 18) | REG_color0) << 2, 0x44332211u, 0xffffffffu);
    regw(REG_fbiInit0, 0);
    rd_cmp(REG_color0 << 2);                       /* = 0x11223344 */
    regw(REG_fbiInit3, (479u << 22) | 1u);         /* alias on (addr bit21) */
    wr(((1u << 19) | 0x09u) << 2, 0x00345678u, 0xffffffffu);   /* -> dRdX (0x10) */
    rd_cmp(((1u << 19) | 0x09u) << 2);             /* aliased read -> dRdX */
    regw(REG_fbiInit3, 479u << 22);                /* alias off */
    rd_cmp(REG_dRdX << 2);                         /* = 0x00345678 */

    /* ---- nop + swap + status ---- */
    mark(0x1500);
    regw(REG_nopCMD, 0);
    regw(REG_swapbufferCMD, 0);
    rd_nocmp(0);                                   /* status (never compared) */

    end_trace(dir, "m1_fill_lfb");
}

/* ---------------- m2: triangles ---------------------------------------- */

static void gen_m2(const char *dir)
{
    begin_trace();
    common_init();

    regw(REG_fbzMode, FBZ_BASE);
    regw(REG_alphaMode, 0);
    regw(REG_fbzColorPath, 0);
    regw(REG_textureMode, 0);

    /* clear back buffer to dark blue, depth = far */
    regw(REG_color1, 0x00203060);
    regw(REG_zaColor, 0x0000ffff);
    regw(REG_fastfillCMD, 0);

    /* ---- the three self-test Gouraud/depth triangles (integer path) ---- */
    mark(0x2100);
    {
        tvtx_t a = fv(320.0, 38.4, 255, 0, 0, 255, 0x8000);
        tvtx_t b = fv(51.2, 374.4, 0, 255, 0, 255, 0x8000);
        tvtx_t c = fv(588.8, 374.4, 0, 0, 255, 255, 0x8000);
        tri_submit(&a, &b, &c, 0);
    }
    {
        tvtx_t a = fv(320.0, 134.4, 255, 255, 255, 255, 0x3000);
        tvtx_t b = fv(192.0, 316.8, 200, 200, 200, 255, 0x3000);
        tvtx_t c = fv(448.0, 316.8, 255, 255, 255, 255, 0x3000);
        tri_submit(&a, &b, &c, 0);
    }
    {
        tvtx_t a = fv(320.0, 216.0, 255, 0, 255, 255, 0xE000);
        tvtx_t b = fv(96.0, 456.0, 255, 0, 255, 255, 0xE000);
        tvtx_t c = fv(544.0, 456.0, 255, 0, 255, 255, 0xE000);
        tri_submit(&a, &b, &c, 0);
    }

    /* ---- float register path ---- */
    mark(0x2200);
    {
        tvtx_t a = fv(70.0, 30.0, 255, 220, 40, 255, 0x4000);
        tvtx_t b = fv(150.0, 95.0, 40, 220, 255, 255, 0x4000);
        tvtx_t c = fv(35.0, 120.0, 220, 40, 255, 255, 0x4000);
        tri_submit(&a, &b, &c, T_FLOAT);
    }

    /* ---- sign=0 and sign=1 majors (mirrored right triangles) ---- */
    mark(0x2300);
    {
        /* long edge A->C on the LEFT (sign=0) */
        tvtx_t a = fv(500.0, 30.0, 80, 255, 80, 255, 0x2000);
        tvtx_t b = fv(560.0, 80.0, 80, 255, 80, 255, 0x2000);
        tvtx_t c = fv(500.0, 130.0, 80, 255, 80, 255, 0x2000);
        tri_submit(&a, &b, &c, 0);
    }
    {
        /* long edge A->C on the RIGHT (sign=1) */
        tvtx_t a = fv(620.0, 30.0, 255, 160, 40, 255, 0x2000);
        tvtx_t b = fv(560.0, 80.0, 255, 160, 40, 255, 0x2000);
        tvtx_t c = fv(620.0, 130.0, 255, 160, 40, 255, 0x2000);
        tri_submit(&a, &b, &c, 0);
    }

    /* ---- thin sliver ---- */
    mark(0x2301);
    {
        tvtx_t a = fv(200.0, 40.0, 255, 255, 255, 255, 0x1000);
        tvtx_t b = fv(200.5, 40.25, 255, 255, 255, 255, 0x1000);
        tvtx_t c = fv(201.0, 110.0, 255, 255, 255, 255, 0x1000);
        tri_submit(&a, &b, &c, 0);
    }

    /* ---- shared-edge quad (two triangles sharing a diagonal) ---- */
    mark(0x2302);
    {
        tvtx_t p00 = fv(250.0, 30.0, 40, 200, 200, 255, 0x1800);
        tvtx_t p10 = fv(340.0, 30.0, 40, 200, 200, 255, 0x1800);
        tvtx_t p11 = fv(340.0, 100.0, 40, 200, 200, 255, 0x1800);
        tvtx_t p01 = fv(250.0, 100.0, 230, 140, 30, 255, 0x1800);
        tvtx_t q11 = p11, q01 = p01;
        q11.r = q01.r = 230; q11.g = q01.g = 140; q11.b = q01.b = 30;
        tri_submit(&p00, &p10, &p11, 0);          /* upper-right half (cyan) */
        tri_submit(&p00, &q11, &q01, 0);          /* lower-left half (orange) */
    }

    /* ---- Ax&15 > 8 and Ay&15 > 8; subpixel adjust on/off ---- */
    mark(0x2303);
    regw(REG_fbzColorPath, 1u << 26);             /* subpixel adjust ON */
    {
        tvtx_t a = fv(30.0 + 13.0 / 16.0, 200.0 + 11.0 / 16.0, 255, 60, 60, 255, 0x1000);
        tvtx_t b = fv(95.0 + 9.0 / 16.0, 245.0 + 13.0 / 16.0, 60, 60, 255, 255, 0x1000);
        tvtx_t c = fv(25.0 + 5.0 / 16.0, 280.0 + 15.0 / 16.0, 60, 255, 60, 255, 0x1000);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzColorPath, 0);                    /* subpixel adjust OFF */
    {
        tvtx_t a = fv(30.0 + 13.0 / 16.0, 300.0 + 11.0 / 16.0, 255, 60, 60, 255, 0x1000);
        tvtx_t b = fv(95.0 + 9.0 / 16.0, 345.0 + 13.0 / 16.0, 60, 60, 255, 255, 0x1000);
        tvtx_t c = fv(25.0 + 5.0 / 16.0, 380.0 + 15.0 / 16.0, 60, 255, 60, 255, 0x1000);
        tri_submit(&a, &b, &c, 0);
    }

    /* ---- depth functions ---- */
    mark(0x2400);
    regw(REG_fbzMode, (FBZ_BASE & ~(7u << 5)) | (7u << 5));   /* always */
    {
        tvtx_t a = fv(580.0, 150.0, 150, 150, 255, 255, 0x9000);
        tvtx_t b = fv(630.0, 200.0, 150, 150, 255, 255, 0x9000);
        tvtx_t c = fv(580.0, 250.0, 150, 150, 255, 255, 0x9000);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzMode, (FBZ_BASE & ~(7u << 5)) | (4u << 5));   /* greater */
    {
        tvtx_t a = fv(560.0, 170.0, 255, 255, 120, 255, 0xA000);
        tvtx_t b = fv(635.0, 220.0, 255, 255, 120, 255, 0xA000);
        tvtx_t c = fv(560.0, 270.0, 255, 255, 120, 255, 0xA000);
        tri_submit(&a, &b, &c, 0);
    }
    /* depth bias: -256 bias makes it beat the 0x8000 gradient region */
    regw(REG_fbzMode, FBZ_BASE | (1u << 16));
    regw(REG_zaColor, 0x0000ff00u);               /* sext16 = -256 */
    {
        tvtx_t a = fv(290.0, 150.0, 30, 30, 30, 255, 0x8000);
        tvtx_t b = fv(350.0, 180.0, 230, 230, 230, 255, 0x8000);
        tvtx_t c = fv(290.0, 210.0, 30, 30, 30, 255, 0x8000);
        tri_submit(&a, &b, &c, 0);
    }
    /* depth_source_compare: compare value = u16(zaColor), write = depthval */
    regw(REG_fbzMode, FBZ_BASE | (1u << 20));
    regw(REG_zaColor, 0x00002000u);
    {
        tvtx_t a = fv(390.0, 150.0, 255, 120, 255, 255, 0x6000);
        tvtx_t b = fv(450.0, 180.0, 255, 120, 255, 255, 0x6000);
        tvtx_t c = fv(390.0, 210.0, 255, 120, 255, 255, 0x6000);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzMode, FBZ_BASE);
    regw(REG_zaColor, 0x0000ffff);

    /* ---- W-buffer triangle with a real W gradient ---- */
    mark(0x2500);
    regw(REG_fbzMode, FBZ_BASE | (1u << 3));
    {
        tvtx_t a = fv(60.0, 390.0, 120, 255, 255, 255, 0);
        tvtx_t b = fv(170.0, 420.0, 255, 255, 120, 255, 0);
        tvtx_t c = fv(60.0, 460.0, 255, 120, 255, 255, 0);
        a.w = 1.75; b.w = 0.05; c.w = 0.60;
        tri_submit(&a, &b, &c, T_W);
    }
    regw(REG_fbzMode, FBZ_BASE);

    /* ---- alpha test (iterated-alpha gradient, func=greater) ---- */
    mark(0x2600);
    regw(REG_fbzColorPath, 1u << 28);
    regw(REG_alphaMode, 1u | (4u << 1) | (0x80u << 24));
    {
        tvtx_t a = fv(240.0, 380.0, 255, 255, 255, 0, 0x0800);
        tvtx_t b = fv(420.0, 380.0, 255, 255, 255, 255, 0x0800);
        tvtx_t c = fv(330.0, 460.0, 255, 255, 255, 128, 0x0800);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_alphaMode, 0);

    /* ---- alpha blends over earlier content ---- */
    mark(0x2700);
    regw(REG_fbzColorPath, 1u << 28);
    /* 50%: src=ASRC_ALPHA, dst=AOMSRC_ALPHA */
    regw(REG_alphaMode, (1u << 4) | (1u << 8) | (5u << 12));
    {
        tvtx_t a = fv(200.0, 170.0, 255, 255, 0, 128, 0x0700);
        tvtx_t b = fv(260.0, 230.0, 255, 255, 0, 128, 0x0700);
        tvtx_t c = fv(170.0, 250.0, 255, 255, 0, 128, 0x0700);
        tri_submit(&a, &b, &c, 0);
    }
    /* additive: src=AONE, dst=AONE */
    regw(REG_alphaMode, (1u << 4) | (4u << 8) | (4u << 12));
    {
        tvtx_t a = fv(430.0, 240.0, 60, 60, 120, 255, 0x0700);
        tvtx_t b = fv(500.0, 300.0, 60, 60, 120, 255, 0x0700);
        tvtx_t c = fv(400.0, 310.0, 60, 60, 120, 255, 0x0700);
        tri_submit(&a, &b, &c, 0);
    }
    /* factor 15 both sides: ASATURATE / A_COLORBEFOREFOG */
    regw(REG_alphaMode, (1u << 4) | (15u << 8) | (15u << 12));
    {
        tvtx_t a = fv(280.0, 280.0, 200, 255, 200, 200, 0x0700);
        tvtx_t b = fv(360.0, 330.0, 200, 255, 200, 200, 0x0700);
        tvtx_t c = fv(250.0, 350.0, 200, 255, 200, 200, 0x0700);
        tri_submit(&a, &b, &c, 0);
    }
    /* src=A_COLOR, dst=AOM_COLOR (screen-like) */
    regw(REG_alphaMode, (1u << 4) | (2u << 8) | (6u << 12));
    {
        tvtx_t a = fv(120.0, 300.0, 180, 120, 255, 255, 0x0700);
        tvtx_t b = fv(190.0, 350.0, 180, 120, 255, 255, 0x0700);
        tvtx_t c = fv(110.0, 380.0, 180, 120, 255, 255, 0x0700);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_alphaMode, 0);
    regw(REG_fbzColorPath, 0);

    /* ---- 2x2 dither + rgbzw_clamp=1 ---- */
    mark(0x2800);
    regw(REG_fbzMode, FBZ_BASE | (1u << 11));
    regw(REG_fbzColorPath, 1u << 28);
    {
        tvtx_t a = fv(470.0, 350.0, 255, 0, 0, 255, 0x0600);
        tvtx_t b = fv(580.0, 390.0, 0, 255, 0, 255, 0x0600);
        tvtx_t c = fv(460.0, 450.0, 0, 0, 255, 255, 0x0600);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzMode, FBZ_BASE);
    regw(REG_fbzColorPath, 0);

    /* ---- rgb mask off (depth-only ghost), then reveal; aux mask off ---- */
    mark(0x2900);
    regw(REG_fbzMode, (FBZ_BASE & ~(1u << 9) & ~(7u << 5)) | (7u << 5));
    {
        tvtx_t a = fv(520.0, 300.0, 0, 0, 0, 255, 0x0100);
        tvtx_t b = fv(570.0, 330.0, 0, 0, 0, 255, 0x0100);
        tvtx_t c = fv(515.0, 345.0, 0, 0, 0, 255, 0x0100);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzMode, FBZ_BASE);
    {
        /* func=less vs the ghost depth: hole where the ghost was written */
        tvtx_t a = fv(500.0, 290.0, 255, 200, 60, 255, 0x0400);
        tvtx_t b = fv(590.0, 340.0, 255, 200, 60, 255, 0x0400);
        tvtx_t c = fv(495.0, 360.0, 255, 200, 60, 255, 0x0400);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzMode, FBZ_BASE & ~(1u << 10));    /* aux mask off */
    {
        tvtx_t a = fv(50.0, 130.0, 120, 230, 230, 255, 0x0300);
        tvtx_t b = fv(110.0, 160.0, 120, 230, 230, 255, 0x0300);
        tvtx_t c = fv(45.0, 185.0, 120, 230, 230, 255, 0x0300);
        tri_submit(&a, &b, &c, 0);
    }
    regw(REG_fbzMode, FBZ_BASE);

    /* ---- degenerates: total function, no pixels expected ---- */
    mark(0x2a00);
    {   /* zero area (colinear) */
        tvtx_t a = fv(100.0, 400.0, 255, 255, 255, 255, 0x100);
        tvtx_t b = fv(150.0, 400.0, 255, 255, 255, 255, 0x100);
        tvtx_t c = fv(200.0, 400.0, 255, 255, 255, 255, 0x100);
        tri_submit(&a, &b, &c, 0);
    }
    {   /* fully clipped by the clip rect */
        regw(REG_clipLeftRight, (0u << 16) | 64u);
        regw(REG_clipLowYHighY, (0u << 16) | 32u);
        tvtx_t a = fv(300.0, 200.0, 255, 255, 255, 255, 0x100);
        tvtx_t b = fv(360.0, 260.0, 255, 255, 255, 255, 0x100);
        tvtx_t c = fv(290.0, 280.0, 255, 255, 255, 255, 0x100);
        tri_submit(&a, &b, &c, 0);
        regw(REG_clipLeftRight, (0u << 16) | 640u);
        regw(REG_clipLowYHighY, (0u << 16) | 480u);
    }
    {   /* fully offscreen (negative y) */
        tvtx_t a = fv(100.0, -80.0, 255, 255, 255, 255, 0x100);
        tvtx_t b = fv(160.0, -40.0, 255, 255, 255, 255, 0x100);
        tvtx_t c = fv(90.0, -10.0, 255, 255, 255, 255, 0x100);
        tri_submit(&a, &b, &c, 0);
    }
    /* deliberately unsorted vertices + arbitrary sign (raw register writes;
     * both models must still agree — the algorithm is a total function) */
    regw(REG_vertexAx, (uint32_t)(uint16_t)(int16_t)(150 * 16));
    regw(REG_vertexAy, (uint32_t)(uint16_t)(int16_t)(430 * 16));
    regw(REG_vertexBx, (uint32_t)(uint16_t)(int16_t)(120 * 16));
    regw(REG_vertexBy, (uint32_t)(uint16_t)(int16_t)(395 * 16));
    regw(REG_vertexCx, (uint32_t)(uint16_t)(int16_t)(180 * 16));
    regw(REG_vertexCy, (uint32_t)(uint16_t)(int16_t)(405 * 16));
    regw(REG_startR, c1212(255));
    regw(REG_dRdX, 0); regw(REG_dRdY, 0);
    regw(REG_startG, c1212(80));
    regw(REG_dGdX, 0); regw(REG_dGdY, 0);
    regw(REG_startB, c1212(80));
    regw(REG_dBdX, 0); regw(REG_dBdY, 0);
    regw(REG_startA, c1212(255));
    regw(REG_dAdX, 0); regw(REG_dAdY, 0);
    regw(REG_startZ, z2012(0x0200));
    regw(REG_dZdX, 0); regw(REG_dZdY, 0);
    regw(REG_triangleCMD, 0x80000000u);

    /* ---- done ---- */
    mark(0x2f00);
    regw(REG_swapbufferCMD, 0);
    rd_nocmp(0);

    end_trace(dir, "m2_tri_gouraud");
}

/* ---------------- m3: full self-test port (textures) ------------------- */

static uint16_t to565(int r, int g, int b)
{
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

/* one checkerboard texel (RGB565) at texel (s,t) of a `dim`-wide level */
static uint16_t checker_texel(int s, int t, int dim)
{
    int cw = dim / 8;
    if (cw < 1) cw = 1;
    int cell = ((s / cw) ^ (t / cw)) & 1;
    int r = cell ? 230 : 30;
    int g = cell ? 140 : 180;
    int b = cell ? 30 : 120;
    return to565(r, g, b);
}

static void gen_m3(const char *dir)
{
    const double W = 640.0, H = 480.0;

    begin_trace();
    common_init();

    regw(REG_fbzMode, FBZ_BASE);
    regw(REG_alphaMode, 0);
    regw(REG_fbzColorPath, 0);
    regw(REG_textureMode, 0);

    regw(REG_color1, 0x00203060);
    regw(REG_zaColor, 0x0000ffff);
    regw(REG_fastfillCMD, 0);

    /* the three Gouraud/depth triangles (voodoo_soft_selftest geometry) */
    mark(0x3100);
    {
        tvtx_t a = fv(W * 0.50, H * 0.08, 255, 0, 0, 255, 0x8000);
        tvtx_t b = fv(W * 0.08, H * 0.78, 0, 255, 0, 255, 0x8000);
        tvtx_t c = fv(W * 0.92, H * 0.78, 0, 0, 255, 255, 0x8000);
        tri_submit(&a, &b, &c, 0);
    }
    {
        tvtx_t a = fv(W * 0.50, H * 0.28, 255, 255, 255, 255, 0x3000);
        tvtx_t b = fv(W * 0.30, H * 0.66, 200, 200, 200, 255, 0x3000);
        tvtx_t c = fv(W * 0.70, H * 0.66, 255, 255, 255, 255, 0x3000);
        tri_submit(&a, &b, &c, 0);
    }
    {
        tvtx_t a = fv(W * 0.50, H * 0.45, 255, 0, 255, 255, 0xE000);
        tvtx_t b = fv(W * 0.15, H * 0.95, 255, 0, 255, 255, 0xE000);
        tvtx_t c = fv(W * 0.85, H * 0.95, 255, 0, 255, 255, 0xE000);
        tri_submit(&a, &b, &c, 0);
    }

    /* texture download: 64x64 RGB565 checkerboard mip chain at LOD2..8 */
    mark(0x3200);
    regw(REG_textureMode, 10u << 8);               /* format 10 = RGB565 */
    regw(REG_tLOD, (8u << 0) | (32u << 6));        /* lod_min=LOD2, lod_max=LOD8 */
    regw(REG_texBaseAddr, 0);
    for (int lod = 2; lod <= 8; lod++) {
        int dim = (0xff >> lod) + 1;               /* 64,32,16,8,4,2,1 */
        for (int tt = 0; tt < dim; tt++) {
            for (int col = 0; col < (dim + 1) / 2; col++) {
                uint32_t lo = checker_texel(2 * col + 0, tt, dim);
                uint32_t hi = checker_texel(2 * col + 1, tt, dim);
                uint32_t dwoff = ((uint32_t)lod << 15) | ((uint32_t)tt << 7) | (uint32_t)col;
                wr(0x800000u + (dwoff << 2), lo | (hi << 16), 0xffffffffu);
            }
        }
    }

    /* textured checkerboard quad (affine, integer S/T path) */
    mark(0x3300);
    regw(REG_fbzColorPath, (1u << 0) | (1u << 2) | (1u << 27));
    regw(REG_textureMode, (10u << 8) | (1u << 12) | (1u << 18) | (1u << 21) | (1u << 27));
    {
        double x0 = W * 0.04, y0 = H * 0.04, x1 = W * 0.34, y1 = H * 0.34;
        tvtx_t a = fv(x0, y0, 255, 255, 255, 255, 0x4000);
        tvtx_t b = fv(x1, y0, 255, 255, 255, 255, 0x4000);
        tvtx_t c = fv(x0, y1, 255, 255, 255, 255, 0x4000);
        a.s = 0;   a.t = 0;
        b.s = 256; b.t = 0;
        c.s = 0;   c.t = 256;
        tri_submit(&a, &b, &c, T_ST);
        tvtx_t d = fv(x1, y0, 255, 255, 255, 255, 0x4000);
        tvtx_t e = fv(x1, y1, 255, 255, 255, 255, 0x4000);
        tvtx_t f = fv(x0, y1, 255, 255, 255, 255, 0x4000);
        d.s = 256; d.t = 0;
        e.s = 256; e.t = 256;
        f.s = 0;   f.t = 256;
        tri_submit(&d, &e, &f, T_ST);
    }

    /* perspective-correct textured floor (float regs + 256/iterw divide) */
    mark(0x3400);
    regw(REG_textureMode, (10u << 8) | (1u << 0) | (1u << 12) | (1u << 18) | (1u << 21) | (1u << 27));
    {
        double nl_x = W * 0.05, nr_x = W * 0.95, ny = H * 0.97;
        double fl_x = W * 0.38, fr_x = W * 0.62, fy = H * 0.52;
        double qn = 1.0, qf = 1.0 / 8.0;
        double uacross = 4.0 * 256.0, vdepth = 16.0 * 256.0;
        tvtx_t nl = fv(nl_x, ny, 255, 255, 255, 255, 0x4000);
        nl.s = 0;            nl.t = 0;           nl.q = qn;
        tvtx_t nr = fv(nr_x, ny, 255, 255, 255, 255, 0x4000);
        nr.s = uacross * qn; nr.t = 0;           nr.q = qn;
        tvtx_t fl = fv(fl_x, fy, 255, 255, 255, 255, 0x4000);
        fl.s = 0;            fl.t = vdepth * qf; fl.q = qf;
        tvtx_t fr = fv(fr_x, fy, 255, 255, 255, 255, 0x4000);
        fr.s = uacross * qf; fr.t = vdepth * qf; fr.q = qf;
        tri_submit(&nl, &nr, &fl, T_FLOAT | T_STWQ);
        tri_submit(&nr, &fr, &fl, T_FLOAT | T_STWQ);
    }

    mark(0x3f00);
    regw(REG_swapbufferCMD, 0);
    rd_nocmp(0);

    end_trace(dir, "m3_selftest_full");
}

/* ---------------- m4: full pixel pipeline ------------------------------ */
/* Stipple, chroma key, alpha mask, fog, and LFB-pixel-pipeline coverage.
 * All in its own trace so the frozen m1/m2/m3 CRCs are untouched. */

/* fbzMode bits used here: clip on, rgb+aux mask, draw=back, dither 4x4 */
#define M4_FBZ ((1u<<0)|(1u<<8)|(1u<<9)|(1u<<10)|(1u<<14))

static void gen_m4(const char *dir)
{
    begin_trace();
    common_init();

    regw(REG_fbzMode, M4_FBZ);
    regw(REG_alphaMode, 0);
    regw(REG_fogMode, 0);
    regw(REG_fbzColorPath, 1u << 28);          /* iterated color, saturate */
    regw(REG_textureMode, 0);

    /* clear back buffer to dark grey, depth = far */
    regw(REG_color1, 0x00303030);
    regw(REG_zaColor, 0x0000ffff);
    regw(REG_fastfillCMD, 0);

    /* ---- stipple, pattern mode (fbzMode bit2 + bit12) ---- */
    mark(0x4100);
    regw(REG_stipple, 0xaa55aa55u);            /* checker-ish pattern */
    regw(REG_fbzMode, M4_FBZ | (1u << 2) | (1u << 12));
    {
        tvtx_t a = fv(40.0,  30.0, 255, 80, 80, 255, 0x4000);
        tvtx_t b = fv(280.0, 30.0, 255, 80, 80, 255, 0x4000);
        tvtx_t c = fv(40.0,  150.0, 255, 80, 80, 255, 0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(280.0, 30.0, 255, 80, 80, 255, 0x4000);
        tvtx_t e = fv(280.0, 150.0, 255, 80, 80, 255, 0x4000);
        tvtx_t f = fv(40.0,  150.0, 255, 80, 80, 255, 0x4000);
        tri_submit(&d, &e, &f, 0);
    }

    /* ---- stipple, rotate mode (fbzMode bit2, bit12=0) ---- */
    mark(0x4101);
    regw(REG_stipple, 0xf0f0f0f0u);            /* run of set/clear top bits */
    regw(REG_fbzMode, M4_FBZ | (1u << 2));
    {
        tvtx_t a = fv(320.0, 30.0, 80, 255, 80, 255, 0x4000);
        tvtx_t b = fv(560.0, 30.0, 80, 255, 80, 255, 0x4000);
        tvtx_t c = fv(320.0, 150.0, 80, 255, 80, 255, 0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(560.0, 30.0, 80, 255, 80, 255, 0x4000);
        tvtx_t e = fv(560.0, 150.0, 80, 255, 80, 255, 0x4000);
        tvtx_t f = fv(320.0, 150.0, 80, 255, 80, 255, 0x4000);
        tri_submit(&d, &e, &f, 0);
    }
    regw(REG_fbzMode, M4_FBZ);

    /* ---- chroma key (fbzMode bit1): green pixels are punched out ---- */
    mark(0x4200);
    /* First lay down a flat YELLOW block (chroma off). Then draw a flat PURE
     * GREEN block over its left half with chroma-key=green: every green pixel
     * matches and is discarded, so the yellow shows through (a clean hole).
     * The right half is drawn green again but keyed to a non-matching colour
     * so it survives -> green block beside the keyed-out (yellow) region. */
    regw(REG_fbzColorPath, 1u << 28);
    regw(REG_fbzMode, M4_FBZ);                 /* chroma off: paint yellow base */
    {
        tvtx_t a = fv(40.0,  180.0, 255, 255, 0, 255, 0x4000);
        tvtx_t b = fv(280.0, 180.0, 255, 255, 0, 255, 0x4000);
        tvtx_t c = fv(40.0,  300.0, 255, 255, 0, 255, 0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(280.0, 180.0, 255, 255, 0, 255, 0x4000);
        tvtx_t e = fv(280.0, 300.0, 255, 255, 0, 255, 0x4000);
        tvtx_t f = fv(40.0,  300.0, 255, 255, 0, 255, 0x4000);
        tri_submit(&d, &e, &f, 0);
    }
    /* flat pure-green block over the left half, keyed to green -> all discarded */
    regw(REG_chromaKey, 0x0000ff00u);          /* match pure green (R0 G255 B0) */
    regw(REG_fbzMode, M4_FBZ | (1u << 1));
    {
        tvtx_t a = fv(40.0,  190.0, 0, 255, 0, 255, 0x4000);
        tvtx_t b = fv(160.0, 190.0, 0, 255, 0, 255, 0x4000);
        tvtx_t c = fv(40.0,  290.0, 0, 255, 0, 255, 0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(160.0, 190.0, 0, 255, 0, 255, 0x4000);
        tvtx_t e = fv(160.0, 290.0, 0, 255, 0, 255, 0x4000);
        tvtx_t f = fv(40.0,  290.0, 0, 255, 0, 255, 0x4000);
        tri_submit(&d, &e, &f, 0);            /* -> vanishes, yellow shows */
    }
    /* right half: green again but key to a colour it does NOT match -> survives */
    regw(REG_chromaKey, 0x00123456u);
    {
        tvtx_t a = fv(160.0, 190.0, 0, 255, 0, 255, 0x4000);
        tvtx_t b = fv(280.0, 190.0, 0, 255, 0, 255, 0x4000);
        tvtx_t c = fv(160.0, 290.0, 0, 255, 0, 255, 0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(280.0, 190.0, 0, 255, 0, 255, 0x4000);
        tvtx_t e = fv(280.0, 290.0, 0, 255, 0, 255, 0x4000);
        tvtx_t f = fv(160.0, 290.0, 0, 255, 0, 255, 0x4000);
        tri_submit(&d, &e, &f, 0);            /* -> green survives */
    }
    regw(REG_fbzMode, M4_FBZ);

    /* ---- alpha mask (fbzMode bit13): odd-alpha kept, even-alpha dropped ---- */
    mark(0x4300);
    /* a_other = iterated alpha; alpha ramps so LSB toggles -> stripes */
    regw(REG_fbzMode, M4_FBZ | (1u << 13));
    {
        tvtx_t a = fv(320.0, 180.0, 120, 120, 255, 0,   0x4000);
        tvtx_t b = fv(560.0, 180.0, 120, 120, 255, 255, 0x4000);
        tvtx_t c = fv(320.0, 300.0, 120, 120, 255, 0,   0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(560.0, 180.0, 120, 120, 255, 255, 0x4000);
        tvtx_t e = fv(560.0, 300.0, 120, 120, 255, 255, 0x4000);
        tvtx_t f = fv(320.0, 300.0, 120, 120, 255, 0,   0x4000);
        tri_submit(&d, &e, &f, 0);
    }
    regw(REG_fbzMode, M4_FBZ);

    /* ---- fog: program a fog table ramp, enable table-sourced fog ---- */
    mark(0x4400);
    regw(REG_fogColor, 0x00ffffffu);           /* fog toward white */
    /* fog table: 64 (blend,delta) entries, 2 per dword over 0x58..0x77.
     * Program a linear blend ramp 0..252 and a small constant delta. */
    for (uint32_t k = 0; k < 32; k++) {
        uint32_t b0 = (2 * k + 0) * 4;         /* blend for entry 2k   */
        uint32_t b1 = (2 * k + 1) * 4;         /* blend for entry 2k+1 */
        if (b0 > 255) b0 = 255;
        if (b1 > 255) b1 = 255;
        uint32_t d0 = 0x10, d1 = 0x10;         /* delta */
        uint32_t dword = (d0 & 0xff) | ((b0 & 0xff) << 8) |
                         ((d1 & 0xff) << 16) | ((b1 & 0xff) << 24);
        regw(REG_fogTable + k, dword);
    }
    /* fog enable, table source (fog_zalpha=0), fog_mult=0 (subtract incoming) */
    regw(REG_fogMode, 1u);
    /* W-buffer so wfloat (=fog depth) varies with the W gradient across the tri */
    regw(REG_fbzMode, M4_FBZ | (1u << 3));
    {
        tvtx_t a = fv(40.0,  320.0, 60, 200, 255, 255, 0);
        tvtx_t b = fv(280.0, 320.0, 60, 200, 255, 255, 0);
        tvtx_t c = fv(40.0,  450.0, 60, 200, 255, 255, 0);
        a.w = 1.75; b.w = 0.10; c.w = 0.90;
        tri_submit(&a, &b, &c, T_W);
        tvtx_t d = fv(280.0, 320.0, 60, 200, 255, 255, 0);
        tvtx_t e = fv(280.0, 450.0, 60, 200, 255, 255, 0);
        tvtx_t f = fv(40.0,  450.0, 60, 200, 255, 255, 0);
        d.w = 0.10; e.w = 0.55; f.w = 0.90;
        tri_submit(&d, &e, &f, T_W);
    }
    regw(REG_fbzMode, M4_FBZ);

    /* ---- fog: constant-fog case (fogMode bit5), fog_mult=0 -> add fogcolor */
    mark(0x4401);
    regw(REG_fogColor, 0x00400000u);           /* add dark red */
    regw(REG_fogMode, 1u | (1u << 5));         /* enable + fog_constant */
    {
        tvtx_t a = fv(320.0, 320.0, 40, 40, 200, 255, 0x4000);
        tvtx_t b = fv(560.0, 320.0, 40, 40, 200, 255, 0x4000);
        tvtx_t c = fv(320.0, 450.0, 40, 40, 200, 255, 0x4000);
        tri_submit(&a, &b, &c, 0);
        tvtx_t d = fv(560.0, 320.0, 40, 40, 200, 255, 0x4000);
        tvtx_t e = fv(560.0, 450.0, 40, 40, 200, 255, 0x4000);
        tvtx_t f = fv(320.0, 450.0, 40, 40, 200, 255, 0x4000);
        tri_submit(&d, &e, &f, 0);
    }
    regw(REG_fogMode, 0);

    /* ---- LFB pixel-pipeline writes (lfbMode bit8) ---- */
    mark(0x4500);
    /* write a block of ARGB8888 pixels routed through the pipeline with an
     * alpha test that drops low-alpha pixels, proving the pipe runs */
    regw(REG_fbzColorPath, 0);                 /* c_other = iterated... but for
                                                * LFB src color comes via combine
                                                * rgbselect=0 -> iterated = src */
    regw(REG_alphaMode, 1u | (4u << 1) | (0x40u << 24));  /* alphatest, func>, ref=0x40 */
    regw(REG_lfbMode, 5u | (1u << 4) | (1u << 8));        /* fmt5 ARGB8888 + pixpipe + draw=back */
    for (int row = 0; row < 16; row++) {
        for (int i = 0; i < 32; i++) {
            /* alpha sweeps 0..0xf8 across the row so the test punches a hole */
            uint32_t alpha = (uint32_t)(i * 8) & 0xff;
            uint32_t rgb = 0x0020a0u + ((uint32_t)(row * 8) << 16);
            uint32_t argb = (alpha << 24) | rgb;
            wr(lfb_addr1(60 + i, 60 + row), argb, 0xffffffffu);
        }
    }
    regw(REG_alphaMode, 0);
    regw(REG_lfbMode, 0);

    /* ---- done ---- */
    mark(0x4f00);
    regw(REG_swapbufferCMD, 0);
    rd_nocmp(0);

    end_trace(dir, "m4_pipeline");
}

/* ---------------- main -------------------------------------------------- */

int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1] : "tb/traces";

    selfcheck();

    char golden[1024];
    snprintf(golden, sizeof(golden), "%s/golden", dir);
    mkdir(dir, 0777);
    mkdir(golden, 0777);

    gen_m1(dir);
    gen_m2(dir);
    gen_m3(dir);
    gen_m4(dir);

    if (G)
        vgold_destroy(G);
    free(recs);
    return 0;
}
