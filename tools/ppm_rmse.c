/* ppm_rmse — per-channel + overall RMSE/PSNR between two binary (P6) PPM images.
 *
 * Dependency-free C11 (links -lm only). Used to judge the VOODOO_INT fixed-point
 * datapath (INT=1) against the float datapath (INT=0) and/or the gold reference —
 * int-vs-float, int-vs-gold, rtl-vs-gold all share this one comparator. The gold
 * model is float-only, so INT=1 is *expected* to differ; `make test` stays pixel-exact
 * on INT=0 and never runs INT=1. See docs/INT-BACKEND-PLAN.md §4.
 *
 * Usage:  ppm_rmse <a.ppm> <b.ppm> [--max-rmse R] [--min-psnr P]
 * Exit:   0 = success / within thresholds
 *         1 = a threshold (--max-rmse / --min-psnr) was exceeded (pass/fail gate)
 *         2 = I/O error, non-P6, maxval!=255, dimension mismatch, or short read
 *
 * Parser: P6 only. Skips ASCII whitespace and '#'-comment lines between the magic,
 * width, height and maxval tokens; requires maxval==255; consumes exactly one
 * whitespace byte after maxval, then fread()s exactly W*H*3 bytes. Build CFLAGS use
 * -Werror -Wextra, so every fgetc/fscanf/fread return is checked.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define EXIT_OK    0   /* success / within thresholds */
#define EXIT_GATE  1   /* threshold exceeded */
#define EXIT_IO    2   /* I/O / format / dimension error */

typedef struct {
    int            w;
    int            h;
    unsigned char *px;   /* W*H*3 interleaved RGB bytes */
} Ppm;

/* Skip ASCII whitespace and whole '#' comment lines. Returns the next
 * non-whitespace, non-comment byte (already consumed), or EOF on error/end. */
static int skip_ws_comments(FILE *f) {
    int c = fgetc(f);
    for (;;) {
        if (c == EOF) {
            return EOF;
        }
        if (c == '#') {
            /* comment runs to end of line */
            do {
                c = fgetc(f);
            } while (c != '\n' && c != '\r' && c != EOF);
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v') {
            c = fgetc(f);
            continue;
        }
        return c;
    }
}

/* Read a non-negative decimal integer token, honoring leading ws/comments.
 * Returns 0 on success (value in *out), -1 on EOF/format error. */
static int read_uint_token(FILE *f, long *out) {
    int c = skip_ws_comments(f);
    if (c == EOF || c < '0' || c > '9') {
        return -1;
    }
    long v = 0;
    while (c >= '0' && c <= '9') {
        v = v * 10 + (c - '0');
        c = fgetc(f);
    }
    /* `c` is the single whitespace/EOF delimiter after the digits; the P6 spec
     * allows exactly one whitespace byte before the raster, so we have already
     * consumed it here for the maxval token. For W/H it is harmless because the
     * next read_uint_token re-skips whitespace. */
    (void)c;
    *out = v;
    return 0;
}

/* Load a binary P6 PPM with maxval==255. Returns EXIT_OK or EXIT_IO. */
static int load_ppm(const char *path, Ppm *img) {
    img->px = NULL;
    img->w = img->h = 0;

    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "ppm_rmse: cannot open %s\n", path);
        return EXIT_IO;
    }

    int m0 = fgetc(f);
    int m1 = fgetc(f);
    if (m0 != 'P' || m1 != '6') {
        fprintf(stderr, "ppm_rmse: %s is not a binary P6 PPM\n", path);
        fclose(f);
        return EXIT_IO;
    }

    long w = 0, h = 0, maxval = 0;
    if (read_uint_token(f, &w) != 0 ||
        read_uint_token(f, &h) != 0 ||
        read_uint_token(f, &maxval) != 0) {
        fprintf(stderr, "ppm_rmse: %s has a malformed P6 header\n", path);
        fclose(f);
        return EXIT_IO;
    }
    if (maxval != 255) {
        fprintf(stderr, "ppm_rmse: %s maxval=%ld (only 255 supported)\n", path, maxval);
        fclose(f);
        return EXIT_IO;
    }
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "ppm_rmse: %s has non-positive dimensions %ldx%ld\n", path, w, h);
        fclose(f);
        return EXIT_IO;
    }

    size_t npx = (size_t)w * (size_t)h;
    size_t nbytes = npx * 3u;
    /* overflow guard on the multiply (defensive; W/H are 10-bit in practice) */
    if (npx / (size_t)w != (size_t)h || nbytes / 3u != npx) {
        fprintf(stderr, "ppm_rmse: %s dimensions %ldx%ld overflow\n", path, w, h);
        fclose(f);
        return EXIT_IO;
    }

    unsigned char *buf = malloc(nbytes);
    if (!buf) {
        fprintf(stderr, "ppm_rmse: out of memory for %s (%zu bytes)\n", path, nbytes);
        fclose(f);
        return EXIT_IO;
    }

    size_t got = fread(buf, 1, nbytes, f);
    if (got != nbytes) {
        fprintf(stderr, "ppm_rmse: %s short read (%zu of %zu raster bytes)\n",
                path, got, nbytes);
        free(buf);
        fclose(f);
        return EXIT_IO;
    }

    fclose(f);
    img->w = (int)w;
    img->h = (int)h;
    img->px = buf;
    return EXIT_OK;
}

/* PSNR for a given MSE (8-bit peak). Identical images (MSE==0) -> +inf. */
static double psnr_db(double mse) {
    if (mse <= 0.0) {
        return INFINITY;
    }
    return 10.0 * log10((255.0 * 255.0) / mse);
}

/* Render a PSNR value as a machine-greppable token: "inf" when infinite,
 * else two-decimal dB. */
static void fmt_psnr(double v, char *buf, size_t n) {
    if (v == INFINITY) {
        snprintf(buf, n, "inf");
    } else {
        snprintf(buf, n, "%.2f", v);
    }
}

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s <a.ppm> <b.ppm> [--max-rmse R] [--min-psnr P]\n"
        "  exit 0=within-threshold  1=threshold-exceeded  2=io/format/dim error\n",
        argv0);
}

int main(int argc, char **argv) {
    const char *path_a = NULL;
    const char *path_b = NULL;
    int    have_max_rmse = 0;
    int    have_min_psnr = 0;
    double max_rmse = 0.0;
    double min_psnr = 0.0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--max-rmse") == 0) {
            if (i + 1 >= argc) { usage(argv[0]); return EXIT_IO; }
            max_rmse = strtod(argv[++i], NULL);
            have_max_rmse = 1;
        } else if (strcmp(argv[i], "--min-psnr") == 0) {
            if (i + 1 >= argc) { usage(argv[0]); return EXIT_IO; }
            min_psnr = strtod(argv[++i], NULL);
            have_min_psnr = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return EXIT_OK;
        } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
            fprintf(stderr, "ppm_rmse: unknown option %s\n", argv[i]);
            usage(argv[0]);
            return EXIT_IO;
        } else if (!path_a) {
            path_a = argv[i];
        } else if (!path_b) {
            path_b = argv[i];
        } else {
            fprintf(stderr, "ppm_rmse: unexpected argument %s\n", argv[i]);
            usage(argv[0]);
            return EXIT_IO;
        }
    }

    if (!path_a || !path_b) {
        usage(argv[0]);
        return EXIT_IO;
    }

    Ppm a, b;
    int rc = load_ppm(path_a, &a);
    if (rc != EXIT_OK) {
        return rc;
    }
    rc = load_ppm(path_b, &b);
    if (rc != EXIT_OK) {
        free(a.px);
        return rc;
    }

    if (a.w != b.w || a.h != b.h) {
        fprintf(stderr, "ppm_rmse: dimension mismatch %dx%d vs %dx%d\n",
                a.w, a.h, b.w, b.h);
        free(a.px);
        free(b.px);
        return EXIT_IO;
    }

    const size_t npx = (size_t)a.w * (size_t)a.h;

    /* Per-channel sum of squared error in double; cast bytes to int first so the
     * difference is signed (avoids unsigned wrap). */
    double sse[3] = { 0.0, 0.0, 0.0 };
    int    max_abs = 0;
    size_t diffpix = 0;

    for (size_t p = 0; p < npx; p++) {
        const unsigned char *pa = &a.px[p * 3u];
        const unsigned char *pb = &b.px[p * 3u];
        int pixel_differs = 0;
        for (int c = 0; c < 3; c++) {
            int d = (int)pa[c] - (int)pb[c];
            sse[c] += (double)d * (double)d;
            int ad = d < 0 ? -d : d;
            if (ad > max_abs) {
                max_abs = ad;
            }
            if (ad != 0) {
                pixel_differs = 1;
            }
        }
        if (pixel_differs) {
            diffpix++;
        }
    }

    const double N = (double)npx;
    double rmse_c[3], psnr_c[3];
    for (int c = 0; c < 3; c++) {
        double mse_c = sse[c] / N;
        rmse_c[c] = sqrt(mse_c);
        psnr_c[c] = psnr_db(mse_c);
    }

    double mse_all  = (sse[0] + sse[1] + sse[2]) / (3.0 * N);
    double rmse_all = sqrt(mse_all);
    double psnr_all = psnr_db(mse_all);

    static const char *CH = "RGB";
    char psnr_str[32];
    printf("ppm_rmse %s %s : %dx%d\n", path_a, path_b, a.w, a.h);
    for (int c = 0; c < 3; c++) {
        fmt_psnr(psnr_c[c], psnr_str, sizeof(psnr_str));
        printf("  %c: rmse=%.3f psnr=%s dB\n", CH[c], rmse_c[c], psnr_str);
    }
    fmt_psnr(psnr_all, psnr_str, sizeof(psnr_str));
    printf("  overall: rmse=%.3f psnr=%s dB  (max_abs=%d diffpix=%zu/%zu)\n",
           rmse_all, psnr_str, max_abs, diffpix, npx);

    free(a.px);
    free(b.px);

    /* Gate: exit 1 if a requested threshold is exceeded. */
    int fail = 0;
    if (have_max_rmse && rmse_all > max_rmse) {
        fail = 1;
    }
    if (have_min_psnr && psnr_all < min_psnr) {
        fail = 1;
    }
    return fail ? EXIT_GATE : EXIT_OK;
}
