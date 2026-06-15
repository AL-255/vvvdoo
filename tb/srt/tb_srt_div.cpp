// tb_srt_div.cpp — self-checking Verilator harness for rtl/srt_div.sv.
//
// Drives the radix-4 SRT divider with directed + randomized signed 64-bit
// operands and asserts q == a/b and r == a%b BIT-FOR-BIT against C's truncating
// integer divide (the same semantics the RTL `/` had). Exercises the iterative
// build by default; -DSRT_PIPE selects the pipelined variant (streams operands).
//
//   build: verilator --cc --exe --build -Mdir <obj> --top-module srt_div \
//          [-GPIPELINED=1] rtl/srt_div.sv tb/unit/tb_srt_div.cpp
//   (see `make srt-test`)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include <vector>
#include "Vsrt_div.h"
#include "verilated.h"

static Vsrt_div* dut;
static vluint64_t main_time = 0;

static void tick() {
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  main_time++;
}

static long g_checks = 0, g_fail = 0;

static void check(int64_t a, int64_t b, int64_t gotq, int64_t gotr) {
  if (b == 0) return;                 // divide-by-zero handled via derr, not here
  int64_t expq = a / b, expr = a % b;
  g_checks++;
  if (gotq != expq || gotr != expr) {
    if (g_fail < 30)
      printf("  MISMATCH a=%lld b=%lld : q=%lld(exp %lld) r=%lld(exp %lld)\n",
             (long long)a, (long long)b, (long long)gotq, (long long)expq,
             (long long)gotr, (long long)expr);
    g_fail++;
  }
}

// Iterative: one op at a time (in_ready handshake).
static void do_one_iter(int64_t a, int64_t b) {
  while (!dut->in_ready) tick();
  dut->a = a; dut->b = b; dut->in_valid = 1; tick();
  dut->in_valid = 0;
  int guard = 0;
  while (!dut->out_valid && guard++ < 200) tick();
  check(a, b, (int64_t)dut->q, (int64_t)dut->r);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vsrt_div;
  dut->clk = 0; dut->rst_n = 0; dut->in_valid = 0; dut->a = 0; dut->b = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();

  std::vector<std::pair<int64_t,int64_t>> directed = {
    {0,1},{1,1},{7,3},{-7,3},{7,-3},{-7,-3},{100,10},{99,10},{-99,10},
    {1,1000},{-1,1000},{123456789,7},{-123456789,7},
    {(int64_t)1<<40, 1},{(int64_t)1<<40, 256},{((int64_t)1<<40)+255,256},
    {(int64_t)0x7fffffffffffffffLL, 3},{(int64_t)0x7fffffffffffffffLL, 0x123456},
    {(int64_t)-0x7fffffffffffffffLL, 7},{(int64_t)1<<62, (int64_t)1<<30},
    {12345678901234LL, 98765}, {-12345678901234LL, 98765},
    {255, 256}, {256, 256}, {257, 256}, {(int64_t)1<<33, (int64_t)1<<8},
  };
  for (auto& p : directed) do_one_iter(p.first, p.second);

  // randomized, biased toward the operand profiles the raster/TMU divides see
  std::mt19937_64 rng(0xC0FFEE);
  auto rnd_bits = [&](int hi){ // value in roughly [-2^hi, 2^hi]
    uint64_t m = (hi >= 63) ? ~0ull : ((1ull<<(hi+1))-1);
    int64_t v = (int64_t)(rng() & m);
    return (rng() & 1) ? -v : v;
  };
  const int N = 200000;
  for (int i = 0; i < N; i++) {
    int ha = 1 + (rng() % 62), hb = 1 + (rng() % 40);
    int64_t a = rnd_bits(ha), b = rnd_bits(hb);
    if (b == 0) b = 1;
    if (a == INT64_MIN) a++;            // avoid /-1 overflow (UB in C too)
    do_one_iter(a, b);
  }

  printf("srt_div: %ld checks, %ld mismatches\n", g_checks, g_fail);
  delete dut;
  return g_fail ? 1 : 0;
}
