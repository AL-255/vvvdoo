// reg_decode.sv — CONTRACTS §2: BAR register-window decode (swizzle/alias/chipmask),
// evaluated combinationally at FIFO pop time on current fbiInit0/fbiInit3 state.
module reg_decode
  import voodoo_pkg::*;
(
    input  logic [23:2] addr,        // BAR dword address
    input  logic [31:0] wdata,       // raw write data
    input  logic        swizzle_en,  // fbiInit0 bit 3
    input  logic        alias_en,    // fbiInit3 bit 0
    output logic [1:0]  region,      // addr[23:22]: 00=registers 01=LFB 1x=texture
    output logic [7:0]  regnum,      // post-alias register number
    output logic [3:0]  chipmask,    // 0 -> 0xf (kept for debug; consumers ignore)
    output logic [31:0] reg_wdata,   // post-swizzle write data (writes only)
    output logic [19:0] lfb_dwoff,   // (addr - 0x400000) >> 2
    output logic [20:0] tex_dwoff    // (addr - 0x800000) >> 2
);

  always_comb begin
    region   = addr[23:22];
    chipmask = (addr[13:10] == 4'h0) ? 4'hf : addr[13:10];

    // alias: (dwoff & (1<<19)) -> byte addr bit 21; only for regnum < 0x40
    regnum = addr[9:2];
    if (alias_en && addr[21] && (addr[9:8] == 2'b00))
      regnum = alias_remap(addr[7:2]);

    // swizzle: (dwoff & (1<<18)) -> byte addr bit 20; writes only
    reg_wdata = (swizzle_en && addr[20])
              ? {wdata[7:0], wdata[15:8], wdata[23:16], wdata[31:24]}
              : wdata;

    lfb_dwoff = addr[21:2];
    tex_dwoff = addr[22:2];
  end

endmodule
