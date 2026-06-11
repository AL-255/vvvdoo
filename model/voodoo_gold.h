#ifndef VOODOO_GOLD_H
#define VOODOO_GOLD_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

#define VGOLD_FB_BYTES   (4u << 20)
#define VGOLD_TEX_BYTES  (2u << 20)

typedef struct vgold vgold_t;

vgold_t  *vgold_create(void);                 /* defaults as in voodoo.c realize:
                                                 640x480, rowpixels 640,
                                                 rgboffs {0,1MB,~0}, aux 2MB,
                                                 frontbuf 0, backbuf 1 */
void      vgold_destroy(vgold_t *g);

/* Raw BAR access; addr = byte offset in the 16MB BAR (dword aligned). */
void      vgold_bar_write(vgold_t *g, uint32_t addr, uint32_t data, uint32_t mask);
uint32_t  vgold_bar_read (vgold_t *g, uint32_t addr);
void      vgold_set_init_enable(vgold_t *g, uint32_t val);

/* State inspection (for the TB differ) */
const uint16_t *vgold_fb(const vgold_t *g);        /* 2M 16-bit words */
const uint8_t  *vgold_texram(const vgold_t *g);    /* 2MB */
int       vgold_frontbuf(const vgold_t *g);
void      vgold_layout(const vgold_t *g, uint32_t rgboffs[3], uint32_t *auxoffs,
                       uint32_t *rowpixels, int *w, int *h);

/* Replay a .vvt trace file. Returns 0 on success, -1 on file/format error,
 * >0 = number of read-compare mismatches (logged to stderr). */
int       vgold_run_trace(vgold_t *g, const char *path);

/* Dump front buffer (w x h, rowpixels stride) as binary P6 PPM. 0 on success. */
int       vgold_dump_ppm(const vgold_t *g, const char *path);

#ifdef __cplusplus
}
#endif
#endif
