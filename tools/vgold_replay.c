/*
 * vgold_replay — replay a .vvt trace on the golden model (CONTRACTS §4).
 *
 *   vgold_replay trace.vvt out_fb.bin out.ppm
 *
 * Replays the trace, writes the full 4MB framebuffer to out_fb.bin, the
 * front buffer to out.ppm, and prints layout + frontbuf + CRC32 of the FB.
 */
#include "voodoo_gold.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* zlib-polynomial CRC32: init 0xffffffff, reflected, final xor 0xffffffff */
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

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s trace.vvt out_fb.bin out.ppm\n", argv[0]);
        return 2;
    }

    vgold_t *g = vgold_create();
    if (!g) {
        fprintf(stderr, "vgold_replay: out of memory\n");
        return 2;
    }

    int rc = vgold_run_trace(g, argv[1]);
    if (rc < 0) {
        fprintf(stderr, "vgold_replay: trace error\n");
        vgold_destroy(g);
        return 2;
    }
    if (rc > 0)
        fprintf(stderr, "vgold_replay: %d read-compare mismatches\n", rc);

    /* full 4MB framebuffer dump */
    FILE *f = fopen(argv[2], "wb");
    if (!f || fwrite(vgold_fb(g), 1, VGOLD_FB_BYTES, f) != VGOLD_FB_BYTES) {
        fprintf(stderr, "vgold_replay: cannot write %s\n", argv[2]);
        if (f)
            fclose(f);
        vgold_destroy(g);
        return 2;
    }
    fclose(f);

    if (vgold_dump_ppm(g, argv[3]) != 0) {
        fprintf(stderr, "vgold_replay: cannot write %s\n", argv[3]);
        vgold_destroy(g);
        return 2;
    }

    uint32_t rgboffs[3], auxoffs, rowpixels;
    int w, h;
    vgold_layout(g, rgboffs, &auxoffs, &rowpixels, &w, &h);
    printf("layout: rgboffs={0x%08x,0x%08x,0x%08x} auxoffs=0x%08x rowpixels=%u %dx%d\n",
           rgboffs[0], rgboffs[1], rgboffs[2], auxoffs, rowpixels, w, h);
    printf("frontbuf: %d\n", vgold_frontbuf(g));
    printf("fb_crc32: %08x\n", crc32_buf(vgold_fb(g), VGOLD_FB_BYTES));

    vgold_destroy(g);
    return rc > 0 ? 1 : 0;
}
