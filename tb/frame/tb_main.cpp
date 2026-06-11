// tb_main.cpp — Verilator frame testbench (CONTRACTS §11).
//
//   vsim <trace.vvt> [--waves out.fst] [--max-cycles N]
//
// Streams a .vvt trace into BOTH the golden model (model/voodoo_gold.h) and
// the Verilated voodoo_top, then compares the full 4MB framebuffer word by
// word plus the frontbuf index.  Exit 0 = PIXEL-EXACT, 1 = mismatch,
// 2 = usage/operational error (bad file, timeout).
//
// RTL memories are reached through the Verilator public arrays
// (voodoo_top.u_fb_ram.mem / voodoo_top.u_tex_ram.mem) and zero-filled at
// t=0; gold's memories are calloc'd, so both start all-zero.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vvoodoo_top.h"
#include "Vvoodoo_top___024root.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif

#include "voodoo_gold.h"

// ------------------------------------------------------------------
// trace record (CONTRACTS §1)
// ------------------------------------------------------------------
typedef struct {
    uint8_t  op;
    uint8_t  flags;
    uint16_t _rsvd;
    uint32_t addr;
    uint32_t data;
    uint32_t mask;
} vvt_rec_t;

static_assert(sizeof(vvt_rec_t) == 16, "vvt_rec_t must be 16 bytes");

#define FB_WORDS (VGOLD_FB_BYTES / 2u)

// ------------------------------------------------------------------
// zlib-polynomial CRC32 (identical to tools/vgold_replay.c)
// ------------------------------------------------------------------
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
    const uint8_t *p = (const uint8_t *)buf;
    for (size_t i = 0; i < len; i++)
        c = table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xffffffffu;
}

// ------------------------------------------------------------------
// simulation driver
// ------------------------------------------------------------------
struct Sim {
    std::unique_ptr<VerilatedContext> ctx;
    std::unique_ptr<Vvoodoo_top>      top;
#if VM_TRACE
    std::unique_ptr<VerilatedFstC>    tfp;
#endif
    uint64_t cycles     = 0;
    uint64_t max_cycles = 200000000ull;

    void dump()
    {
#if VM_TRACE
        if (tfp)
            tfp->dump(ctx->time());
#endif
    }

    // one full clock: posedge then negedge (inputs are set while clk==0)
    void tick()
    {
        top->clk = 1;
        ctx->timeInc(1);
        top->eval();
        dump();
        top->clk = 0;
        ctx->timeInc(1);
        top->eval();
        dump();
        if (++cycles > max_cycles) {
            fprintf(stderr, "tb: TIMEOUT after %llu cycles (--max-cycles)\n",
                    (unsigned long long)max_cycles);
            finish();
            exit(2);
        }
    }

    void finish()
    {
#if VM_TRACE
        if (tfp) {
            tfp->close();
            tfp.reset();
        }
#endif
        top->final();
    }
};

static Sim sim;

// drive one BAR write into the RTL (be = nonzero bytes of mask)
static void rtl_bar_write(uint32_t addr, uint32_t data, uint32_t mask)
{
    uint8_t be = 0;
    for (int b = 0; b < 4; b++)
        if ((mask >> (8 * b)) & 0xffu)
            be |= (uint8_t)(1u << b);

    sim.top->host_wr_valid = 1;
    sim.top->host_wr_addr  = (addr >> 2) & 0x3fffffu;
    sim.top->host_wr_data  = data;
    sim.top->host_wr_be    = be;
    for (;;) {
        sim.top->eval();
        bool acc = sim.top->host_wr_ready != 0;
        sim.tick();
        if (acc)
            break;
    }
    sim.top->host_wr_valid = 0;
}

// drive one BAR read, wait for the response pulse
static uint32_t rtl_bar_read(uint32_t addr)
{
    sim.top->host_rd_valid = 1;
    sim.top->host_rd_addr  = (addr >> 2) & 0x3fffffu;
    for (;;) {
        sim.top->eval();
        bool acc = sim.top->host_rd_ready != 0;
        sim.tick();
        if (acc)
            break;
    }
    sim.top->host_rd_valid = 0;
    for (;;) {
        if (sim.top->host_rd_resp_valid) {
            uint32_t v = sim.top->host_rd_data;
            sim.tick();             // let the pulse retire
            return v;
        }
        sim.tick();
    }
}

static void rtl_drain(void)
{
    // a couple of settle cycles, then wait for !busy
    sim.tick();
    sim.tick();
    while (sim.top->busy)
        sim.tick();
    for (int i = 0; i < 8; i++)     // let the last RAM write land
        sim.tick();
}

// ------------------------------------------------------------------
// PPM output (565 -> 888 bit replication, identical to gold from565)
// ------------------------------------------------------------------
static void from565(uint16_t p, uint8_t rgb[3])
{
    unsigned r = (p >> 11) & 0x1f, g = (p >> 5) & 0x3f, b = p & 0x1f;
    rgb[0] = (uint8_t)((r << 3) | (r >> 2));
    rgb[1] = (uint8_t)((g << 2) | (g >> 4));
    rgb[2] = (uint8_t)((b << 3) | (b >> 2));
}

typedef uint16_t (*fb_getter_t)(uint32_t word, const void *u);

static int write_ppm(const char *path, fb_getter_t get, const void *u,
                     uint32_t base_words, uint32_t rowpixels, int w, int h)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "tb: cannot write %s\n", path);
        return -1;
    }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t word = base_words + (uint32_t)y * rowpixels + (uint32_t)x;
            uint16_t p = (word < FB_WORDS) ? get(word, u) : 0;
            uint8_t rgb[3];
            from565(p, rgb);
            fwrite(rgb, 1, 3, f);
        }
    }
    fclose(f);
    return 0;
}

static uint16_t gold_getter(uint32_t word, const void *u)
{
    return ((const uint16_t *)u)[word];
}

struct DiffCtx {
    const uint16_t *gold;
    const uint16_t *rtl;
};

// ------------------------------------------------------------------
// main
// ------------------------------------------------------------------
int main(int argc, char **argv)
{
    const char *trace_path = nullptr;
    const char *waves_path = nullptr;
    uint64_t max_cycles = 200000000ull;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--waves") && i + 1 < argc) {
            waves_path = argv[++i];
        } else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) {
            max_cycles = strtoull(argv[++i], nullptr, 0);
        } else if (argv[i][0] != '-' && !trace_path) {
            trace_path = argv[i];
        } else {
            fprintf(stderr,
                    "usage: vsim <trace.vvt> [--waves out.fst] [--max-cycles N]\n");
            return 2;
        }
    }
    if (!trace_path) {
        fprintf(stderr,
                "usage: vsim <trace.vvt> [--waves out.fst] [--max-cycles N]\n");
        return 2;
    }

    // ---- load the trace ----
    FILE *tf = fopen(trace_path, "rb");
    if (!tf) {
        fprintf(stderr, "tb: cannot open %s\n", trace_path);
        return 2;
    }
    char magic[4];
    uint32_t count = 0;
    if (fread(magic, 1, 4, tf) != 4 || memcmp(magic, "VVT1", 4) != 0 ||
        fread(&count, 4, 1, tf) != 1) {
        fprintf(stderr, "tb: %s: bad header\n", trace_path);
        fclose(tf);
        return 2;
    }
    std::vector<vvt_rec_t> recs(count);
    if (count && fread(recs.data(), sizeof(vvt_rec_t), count, tf) != count) {
        fprintf(stderr, "tb: %s: truncated (%u records expected)\n",
                trace_path, count);
        fclose(tf);
        return 2;
    }
    fclose(tf);

    // ---- instantiate gold + RTL ----
    vgold_t *gold = vgold_create();
    if (!gold) {
        fprintf(stderr, "tb: vgold_create failed\n");
        return 2;
    }

    sim.ctx = std::make_unique<VerilatedContext>();
    sim.ctx->commandArgs(argc, argv);
    sim.top = std::make_unique<Vvoodoo_top>(sim.ctx.get());
    sim.max_cycles = max_cycles;

#if VM_TRACE
    if (waves_path) {
        Verilated::traceEverOn(true);
        sim.tfp = std::make_unique<VerilatedFstC>();
        sim.top->trace(sim.tfp.get(), 99);
        sim.tfp->open(waves_path);
        if (!sim.tfp->isOpen()) {
            fprintf(stderr, "tb: cannot open %s\n", waves_path);
            return 2;
        }
    }
#else
    if (waves_path)
        fprintf(stderr, "tb: built without --trace-fst (WAVES=1); "
                        "--waves ignored\n");
#endif

    // ---- zero both RTL memories at t=0 (gold's are calloc'd) ----
    auto *rootp = sim.top->rootp;
    for (uint32_t i = 0; i < FB_WORDS; i++)
        rootp->voodoo_top__DOT__u_fb_ram__DOT__mem[i] = 0;
    for (uint32_t i = 0; i < (VGOLD_TEX_BYTES / 2u); i++)
        rootp->voodoo_top__DOT__u_tex_ram__DOT__mem[i] = 0;

    // ---- reset ----
    sim.top->clk           = 0;
    sim.top->rst_n         = 0;
    sim.top->host_wr_valid = 0;
    sim.top->host_wr_addr  = 0;
    sim.top->host_wr_data  = 0;
    sim.top->host_wr_be    = 0;
    sim.top->host_rd_valid = 0;
    sim.top->host_rd_addr  = 0;
    sim.top->init_enable   = 0;
    sim.top->eval();
    for (int i = 0; i < 8; i++)
        sim.tick();
    sim.top->rst_n = 1;
    for (int i = 0; i < 4; i++)
        sim.tick();

    // ---- stream the trace into both models ----
    int read_mismatches = 0;
    for (uint32_t i = 0; i < count; i++) {
        const vvt_rec_t &r = recs[i];
        switch (r.op) {
        case 0:                                         // BAR write
            vgold_bar_write(gold, r.addr, r.data, r.mask);
            rtl_bar_write(r.addr, r.data, r.mask);
            break;
        case 1: {                                       // BAR read
            uint32_t gv = vgold_bar_read(gold, r.addr);
            uint32_t rv = rtl_bar_read(r.addr);
            bool is_status = (((r.addr >> 22) & 3u) == 0) &&
                             (((r.addr >> 2) & 0xffu) == 0);
            if ((r.flags & 1) && !is_status) {          // status never compared
                if (rv != r.data) {
                    fprintf(stderr,
                            "tb: rec %u: READ 0x%06x rtl=0x%08x expected=0x%08x"
                            " (gold=0x%08x)\n",
                            i, r.addr, rv, r.data, gv);
                    read_mismatches++;
                } else if (gv != r.data) {
                    // trace/gold drift — informational, RTL matched the trace
                    fprintf(stderr,
                            "tb: rec %u: NOTE gold read 0x%06x = 0x%08x, "
                            "trace expected 0x%08x\n",
                            i, r.addr, gv, r.data);
                }
            }
            break;
        }
        case 2:                                         // INIT_ENABLE
            rtl_drain();                                // keep in-order semantics
            vgold_set_init_enable(gold, r.data);
            sim.top->init_enable = r.data;
            break;
        case 3:                                         // MARK
            break;
        default:
            fprintf(stderr, "tb: %s: rec %u unknown op %u\n",
                    trace_path, i, r.op);
            sim.finish();
            return 2;
        }
    }

    // ---- drain ----
    rtl_drain();

    // ---- compare ----
    const uint16_t *gfb = vgold_fb(gold);
    std::vector<uint16_t> rfb(FB_WORDS);
    for (uint32_t i = 0; i < FB_WORDS; i++)
        rfb[i] = (uint16_t)rootp->voodoo_top__DOT__u_fb_ram__DOT__mem[i];

    uint32_t rgboffs[3], auxoffs, rowpixels;
    int w, h;
    vgold_layout(gold, rgboffs, &auxoffs, &rowpixels, &w, &h);

    struct Region {
        const char *name;
        uint32_t    base;
        bool        valid;
    } regions[4];
    char n0[16], n1[16], n2[16];
    int gold_front = vgold_frontbuf(gold);
    snprintf(n0, sizeof(n0), "rgb0%s", gold_front == 0 ? "(front)" : "");
    snprintf(n1, sizeof(n1), "rgb1%s", gold_front == 1 ? "(front)" : "");
    snprintf(n2, sizeof(n2), "rgb2%s", gold_front == 2 ? "(front)" : "");
    regions[0] = { n0, (rgboffs[0] & (VGOLD_FB_BYTES - 1)) >> 1, rgboffs[0] != ~0u };
    regions[1] = { n1, (rgboffs[1] & (VGOLD_FB_BYTES - 1)) >> 1, rgboffs[1] != ~0u };
    regions[2] = { n2, (rgboffs[2] & (VGOLD_FB_BYTES - 1)) >> 1, rgboffs[2] != ~0u };
    regions[3] = { "aux", (auxoffs & (VGOLD_FB_BYTES - 1)) >> 1, auxoffs != ~0u };

    uint64_t mismatches = 0;
    for (uint32_t widx = 0; widx < FB_WORDS; widx++) {
        if (rfb[widx] == gfb[widx])
            continue;
        if (mismatches < 32) {
            // pick the valid region with the largest base <= widx
            int best = -1;
            for (int rg = 0; rg < 4; rg++)
                if (regions[rg].valid && regions[rg].base <= widx &&
                    (best < 0 || regions[rg].base >= regions[best].base))
                    best = rg;
            uint32_t rel = (best >= 0) ? widx - regions[best].base : widx;
            uint32_t x = rowpixels ? rel % rowpixels : 0;
            uint32_t y = rowpixels ? rel / rowpixels : 0;
            fprintf(stderr,
                    "tb: MISMATCH word 0x%06x x=%u y=%u %s rtl=0x%04x gold=0x%04x\n",
                    widx, x, y, best >= 0 ? regions[best].name : "?",
                    rfb[widx], gfb[widx]);
        }
        mismatches++;
    }

    // optional debug aid: TB_DUMP_FB=<path> dumps the raw 4MB RTL FB
    if (const char *dump = getenv("TB_DUMP_FB")) {
        FILE *df = fopen(dump, "wb");
        if (df) {
            fwrite(rfb.data(), 2, FB_WORDS, df);
            fclose(df);
        }
    }

    int rtl_front = (int)sim.top->dbg_frontbuf;
    bool front_ok = (rtl_front == gold_front);
    if (!front_ok)
        fprintf(stderr, "tb: FRONTBUF mismatch rtl=%d gold=%d\n",
                rtl_front, gold_front);

    sim.finish();

    if (mismatches == 0 && front_ok && read_mismatches == 0) {
        printf("PIXEL-EXACT %u records, %llu cycles, frontbuf=%d, "
               "fb_crc32=%08x\n",
               count, (unsigned long long)sim.cycles, gold_front,
               crc32_buf(rfb.data(), VGOLD_FB_BYTES));
        vgold_destroy(gold);
        return 0;
    }

    fprintf(stderr,
            "tb: FAIL %llu fb word mismatches, %d read mismatches%s "
            "(rtl_crc=%08x gold_crc=%08x)\n",
            (unsigned long long)mismatches, read_mismatches,
            front_ok ? "" : ", frontbuf mismatch",
            crc32_buf(rfb.data(), VGOLD_FB_BYTES),
            crc32_buf(gfb, VGOLD_FB_BYTES));

    // dump PPMs of the front buffer (gold's frontbuf index used for all
    // three images so they show the same region)
    uint32_t fb_off = rgboffs[gold_front];
    uint32_t base_words = (fb_off == ~0u) ? 0
                          : (fb_off & (VGOLD_FB_BYTES - 1)) >> 1;
    write_ppm("out_gold.ppm", gold_getter, gfb, base_words, rowpixels, w, h);
    write_ppm("out_rtl.ppm", gold_getter, rfb.data(), base_words, rowpixels, w, h);

    DiffCtx dc = { gfb, rfb.data() };
    auto diff_getter = [](uint32_t word, const void *u) -> uint16_t {
        const DiffCtx *d = (const DiffCtx *)u;
        if (d->gold[word] != d->rtl[word])
            return 0xf800;                      // red where mismatched
        // matching pixels: gold value at 1/4 brightness for context
        uint16_t p = d->gold[word];
        return (uint16_t)((((p >> 11) & 0x1f) >> 2) << 11 |
                          ((((p >> 5) & 0x3f) >> 2) << 5) |
                          ((p & 0x1f) >> 2));
    };
    write_ppm("out_diff.ppm", diff_getter, &dc, base_words, rowpixels, w, h);
    fprintf(stderr, "tb: wrote out_rtl.ppm out_gold.ppm out_diff.ppm\n");

    vgold_destroy(gold);
    return 1;
}
