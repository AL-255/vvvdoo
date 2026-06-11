// ut_trace.cpp — round-trip test of the .vvt trace format through
// vgold_run_trace (CONTRACTS §1 / §10 "make unit" test (c)).
//
// Builds small traces in memory (header + records including op=2
// INIT_ENABLE, a flagged compare-read, op=3 MARK), writes them to temp
// files, replays them on gold and asserts framebuffer contents + return
// codes.  Also asserts the error paths: malformed magic, truncated file,
// unknown op -> -1; a failing flagged read -> mismatch count > 0.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <stdlib.h>     // mkstemp
#include <unistd.h>     // close, unlink

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

// trace record (CONTRACTS §1)
typedef struct {
    uint8_t  op;
    uint8_t  flags;
    uint16_t _rsvd;
    uint32_t addr;
    uint32_t data;
    uint32_t mask;
} vvt_rec_t;

static_assert(sizeof(vvt_rec_t) == 16, "vvt_rec_t must be 16 bytes");

static vvt_rec_t rec(uint8_t op, uint8_t flags, uint32_t addr, uint32_t data,
                     uint32_t mask)
{
    vvt_rec_t r;
    r.op = op;
    r.flags = flags;
    r._rsvd = 0;
    r.addr = addr;
    r.data = data;
    r.mask = mask;
    return r;
}

// write a raw buffer to a fresh temp file; returns the path
static std::string write_tmp(const void *buf, size_t len)
{
    char path[] = "/tmp/ut_trace_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        perror("mkstemp");
        exit(2);
    }
    FILE *f = fdopen(fd, "wb");
    if (!f || fwrite(buf, 1, len, f) != len) {
        perror("fwrite");
        exit(2);
    }
    fclose(f);
    return std::string(path);
}

static std::string write_trace(const std::vector<vvt_rec_t> &recs,
                               const char magic[4], uint32_t count_override,
                               bool use_override)
{
    std::vector<uint8_t> buf;
    buf.insert(buf.end(), magic, magic + 4);
    uint32_t count = use_override ? count_override : (uint32_t)recs.size();
    const uint8_t *cp = (const uint8_t *)&count;
    buf.insert(buf.end(), cp, cp + 4);
    const uint8_t *rp = (const uint8_t *)recs.data();
    buf.insert(buf.end(), rp, rp + recs.size() * sizeof(vvt_rec_t));
    return write_tmp(buf.data(), buf.size());
}

// register byte addresses
static const uint32_t A_lfbMode  = 0x45u << 2;
static const uint32_t A_fbzMode  = 0x44u << 2;
static const uint32_t A_dacData  = 0x8bu << 2;
static const uint32_t A_fbiInit2 = 0x86u << 2;
static const uint32_t FULL = 0xffffffffu;

int main(void)
{
    // ---- A: good trace — op=2, reg writes, LFB write, flagged reads, MARK
    {
        std::vector<vvt_rec_t> t;
        // initEnable: bit0 hw-init, bit2 remap fbiInit2 read -> dacRead
        t.push_back(rec(2, 0, 0, 0x00000005u, 0));
        t.push_back(rec(0, 0, A_fbzMode, 0, FULL));
        t.push_back(rec(0, 0, A_lfbMode, 0, FULL));          // fmt 0, front
        // LFB write: pixels (0,0)=0x1234 (1,0)=0xABCD
        t.push_back(rec(0, 0, 0x400000u, 0xABCD1234u, FULL));
        // flagged LFB read-compare (rbufsel=0 -> front)
        t.push_back(rec(1, 1, 0x400000u, 0xABCD1234u, 0));
        // dacData FSM: write 0x01 to DAC reg 7, then read-trigger -> 0x55
        t.push_back(rec(0, 0, A_dacData, 0x00000701u, FULL));
        t.push_back(rec(0, 0, A_dacData, 0x00000F01u, FULL));
        // fbiInit2 read remaps to dac_read_result under initEnable bit2
        t.push_back(rec(1, 1, A_fbiInit2, 0x00000055u, 0));
        t.push_back(rec(3, 0, 0, 42, 0));                    // MARK: no effect
        std::string p = write_trace(t, "VVT1", 0, false);

        vgold_t *g = vgold_create();
        int rc = vgold_run_trace(g, p.c_str());
        CHECK(rc == 0, "good trace: rc=%d want 0", rc);
        const uint16_t *fb = vgold_fb(g);
        CHECK(fb[0] == 0x1234, "fb[0]=0x%04x want 0x1234", fb[0]);
        CHECK(fb[1] == 0xABCD, "fb[1]=0x%04x want 0xABCD", fb[1]);
        CHECK(fb[2] == 0, "fb[2]=0x%04x want 0", fb[2]);
        CHECK(vgold_frontbuf(g) == 0, "frontbuf=%d want 0", vgold_frontbuf(g));
        vgold_destroy(g);
        unlink(p.c_str());
    }

    // ---- B: failing flagged read -> return = mismatch count (>0) ----
    {
        std::vector<vvt_rec_t> t;
        t.push_back(rec(0, 0, A_lfbMode, 0, FULL));
        t.push_back(rec(0, 0, 0x400000u, 0xABCD1234u, FULL));
        t.push_back(rec(1, 1, 0x400000u, 0xDEADBEEFu, 0));   // wrong expectation
        // unflagged read of the same address must NOT count
        t.push_back(rec(1, 0, 0x400000u, 0xDEADBEEFu, 0));
        std::string p = write_trace(t, "VVT1", 0, false);

        vgold_t *g = vgold_create();
        int rc = vgold_run_trace(g, p.c_str());
        CHECK(rc == 1, "mismatch trace: rc=%d want 1", rc);
        vgold_destroy(g);
        unlink(p.c_str());
    }

    // ---- C: malformed magic -> -1, device untouched ----
    {
        std::vector<vvt_rec_t> t;
        t.push_back(rec(0, 0, 0x400000u, 0xABCD1234u, FULL));
        std::string p = write_trace(t, "XVT1", 0, false);

        vgold_t *g = vgold_create();
        int rc = vgold_run_trace(g, p.c_str());
        CHECK(rc == -1, "bad magic: rc=%d want -1", rc);
        CHECK(vgold_fb(g)[0] == 0, "bad magic: device must be untouched");
        vgold_destroy(g);
        unlink(p.c_str());
    }

    // ---- D: truncated file (header claims more records) -> -1 ----
    {
        std::vector<vvt_rec_t> t;
        t.push_back(rec(0, 0, A_lfbMode, 0, FULL));
        std::string p = write_trace(t, "VVT1", 5, true);

        vgold_t *g = vgold_create();
        int rc = vgold_run_trace(g, p.c_str());
        CHECK(rc == -1, "truncated: rc=%d want -1", rc);
        vgold_destroy(g);
        unlink(p.c_str());
    }

    // ---- E: unknown op -> -1 ----
    {
        std::vector<vvt_rec_t> t;
        t.push_back(rec(9, 0, 0, 0, 0));
        std::string p = write_trace(t, "VVT1", 0, false);

        vgold_t *g = vgold_create();
        int rc = vgold_run_trace(g, p.c_str());
        CHECK(rc == -1, "unknown op: rc=%d want -1", rc);
        vgold_destroy(g);
        unlink(p.c_str());
    }

    // ---- F: nonexistent file -> -1 ----
    {
        vgold_t *g = vgold_create();
        int rc = vgold_run_trace(g, "/nonexistent/path/trace.vvt");
        CHECK(rc == -1, "missing file: rc=%d want -1", rc);
        vgold_destroy(g);
    }

    if (failures) {
        printf("ut_trace: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("ut_trace: PASS\n");
    return 0;
}
