// cosim_replay.cpp — RTL-C co-simulation harness.
//
// Replays a real Voodoo command stream (.vvt trace) through the Verilated
// RTL (the actual hardware model), scans out each rendered frame from the
// RTL framebuffer, and reports acceleration metrics: cycles per frame and the
// equivalent frame rate at the SST-1 target clock (50 MHz).
//
// This is the same "chip pin" boundary the QEMU co-sim backend uses; here it
// is driven from a captured trace so a real workload can be rendered by the
// RTL with no guest OS in the loop.
//
//   build/cosim_replay <trace.vvt> [out_prefix] [--clock-mhz N]
//
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include "verilated.h"
#include "Vvoodoo_top.h"
#include "Vvoodoo_top___024root.h"

// ---- trace format (CONTRACTS §1) ----
struct vvt_rec { uint8_t op, flags; uint16_t rsvd; uint32_t addr, data, mask; };
enum { OP_WR = 0, OP_RD = 1, OP_INIT = 2, OP_MARK = 3 };

static const uint32_t FB_WORDS = (4u << 20) / 2u;   // 2M 16-bit words

// ---- Verilated model wrapper ----
struct Sim {
    VerilatedContext ctx;
    Vvoodoo_top      top{&ctx};
    uint64_t         cyc = 0;

    void tick() {
        top.clk = 1; top.eval();
        top.clk = 0; top.eval();
        cyc++;
    }
    void reset() {
        auto *r = top.rootp;
        for (uint32_t i = 0; i < FB_WORDS; i++)
            r->voodoo_top__DOT__u_fb_ram__DOT__mem[i] = 0;
        for (uint32_t i = 0; i < (2u << 20) / 2u; i++)
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
    void drain() {
        tick(); tick();
        while (top.busy) tick();
        for (int i = 0; i < 8; i++) tick();
    }
    uint16_t fb(uint32_t word) {
        return top.rootp->voodoo_top__DOT__u_fb_ram__DOT__mem[word & (FB_WORDS - 1)];
    }
};

static void from565(uint16_t p, uint8_t rgb[3]) {
    int r = (p >> 11) & 0x1f, g = (p >> 5) & 0x3f, b = p & 0x1f;
    rgb[0] = (uint8_t)((r << 3) | (r >> 2));
    rgb[1] = (uint8_t)((g << 2) | (g >> 4));
    rgb[2] = (uint8_t)((b << 3) | (b >> 2));
}

static int write_ppm(Sim &s, const char *path) {
    uint32_t base = s.top.scan_front_base;
    uint32_t rp   = s.top.scan_rowpixels;
    int w = s.top.scan_width, h = s.top.scan_height;
    if (w <= 0) w = 640;
    if (h <= 0) h = 480;
    if (rp == 0) rp = (uint32_t)w;
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    std::vector<uint8_t> row((size_t)w * 3);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++)
            from565(s.fb(base + (uint32_t)y * rp + (uint32_t)x), &row[(size_t)x * 3]);
        fwrite(row.data(), 1, row.size(), f);
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <trace.vvt> [out_prefix] [--clock-mhz N]\n", argv[0]);
        return 2;
    }
    const char *trace_path = argv[1];
    const char *prefix = (argc >= 3 && argv[2][0] != '-') ? argv[2] : "cosim";
    double clock_mhz = 50.0;
    for (int i = 2; i < argc; i++)
        if (!strcmp(argv[i], "--clock-mhz") && i + 1 < argc) clock_mhz = atof(argv[++i]);

    FILE *tf = fopen(trace_path, "rb");
    if (!tf) { fprintf(stderr, "cannot open %s\n", trace_path); return 2; }
    char magic[4]; uint32_t nrec;
    if (fread(magic, 1, 4, tf) != 4 || memcmp(magic, "VVT1", 4) ||
        fread(&nrec, 4, 1, tf) != 1) { fprintf(stderr, "bad trace header\n"); return 2; }
    std::vector<vvt_rec> recs(nrec);
    if (fread(recs.data(), sizeof(vvt_rec), nrec, tf) != nrec) {
        fprintf(stderr, "truncated trace\n"); return 2;
    }
    fclose(tf);

    Sim sim;
    sim.reset();

    uint64_t cyc_render = 0;     // cycles spent from first draw to last swap
    uint64_t first_draw_cyc = 0;
    bool seen_draw = false;
    int frame = 0;
    uint64_t total_pixels = 0;   // pixels swapped to the display (w*h per frame)

    for (uint32_t i = 0; i < nrec; i++) {
        const vvt_rec &r = recs[i];
        switch (r.op) {
        case OP_WR: {
            uint32_t region = (r.addr >> 22) & 3;
            uint32_t regnum = (r.addr >> 2) & 0xff;
            bool is_draw = (region == 0) &&
                (regnum == 0x20 || regnum == 0x40 || regnum == 0x49); // (f)tri / fastfill
            if (is_draw && !seen_draw) { seen_draw = true; first_draw_cyc = sim.cyc; }
            sim.bar_write(r.addr, r.data, r.mask);
            // swapbufferCMD -> a frame boundary: drain + scanout
            if (region == 0 && regnum == 0x4a) {
                sim.drain();
                char path[256];
                snprintf(path, sizeof(path), "%s_f%03d.ppm", prefix, frame);
                write_ppm(sim, path);
                int w = sim.top.scan_width ? sim.top.scan_width : 640;
                int h = sim.top.scan_height ? sim.top.scan_height : 480;
                total_pixels += (uint64_t)w * h;
                frame++;
            }
            break;
        }
        case OP_RD:   (void)sim.bar_read(r.addr); break;
        case OP_INIT: sim.top.init_enable = r.data; sim.top.eval(); break;
        case OP_MARK: default: break;
        }
    }
    sim.drain();
    cyc_render = sim.cyc - (seen_draw ? first_draw_cyc : 0);

    // final scanout (covers traces without a trailing swap)
    char path[256];
    snprintf(path, sizeof(path), "%s_final.ppm", prefix);
    write_ppm(sim, path);

    double sec = (double)cyc_render / (clock_mhz * 1e6);
    printf("co-sim: %u records, %d frame(s) swapped\n", nrec, frame);
    printf("  total cycles            : %llu\n", (unsigned long long)sim.cyc);
    printf("  render cycles (1st draw->end): %llu\n", (unsigned long long)cyc_render);
    if (frame > 0) {
        printf("  cycles / frame          : %llu\n",
               (unsigned long long)(cyc_render / (uint64_t)frame));
        double fps = clock_mhz * 1e6 * frame / (double)cyc_render;
        printf("  @ %.0f MHz -> %.2f ms/frame, %.1f fps\n",
               clock_mhz, 1000.0 * sec / frame, fps);
    }
    if (total_pixels)
        printf("  fill rate               : %.1f Mpix/s @ %.0f MHz\n",
               (double)total_pixels / sec / 1e6, clock_mhz);
    printf("  wrote %s_*.ppm\n", prefix);
    return 0;
}
