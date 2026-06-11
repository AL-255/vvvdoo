// tex_dl.sv — CONTRACTS §5/§8 M1: texture download decode, ported from
// voodoo_soft.c tex_recompute (lodoffset[0..8] incl. min-4-texel clamp for
// LOD>=4) + soft_tex_write (tLOD swizzle/swap, seq8, (bpt*offs)&~3, bpt1 =
// four byte writes, bpt2 = two 16-bit writes at base and base+2).
module tex_dl
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // download command from cmd_dispatch (held until wr_done pulses)
    input  logic        wr_valid,
    input  logic [20:0] wr_dwoff,
    input  logic [31:0] wr_data,
    output logic        wr_done,

    // live TMU register state
    input  logic [31:0] texmode,
    input  logic [31:0] tlod,
    input  logic [31:0] texbaseaddr,

    // tex_ram client port (§7.3 shape; single client, write-only in M1)
    output logic               req_valid,
    input  logic               req_ready,
    output logic               req_we,
    output logic [TEX_AW-1:0]  req_addr,    // 16-bit word address
    output logic [15:0]        req_wdata,
    output logic [1:0]         req_be
);

  // ----------------------------------------------------------------
  // tex_recompute (combinational part): format/bpt/masks
  // ----------------------------------------------------------------
  logic [3:0] fmt;
  logic       bpt2;          // bytes-per-texel == 2
  logic       bppscale;      // format >> 3
  logic [8:0] lodmask;
  logic [7:0] wmask, hmask;
  logic       seq8;

  always_comb begin
    fmt      = texmode[11:8];
    bpt2     = fmt[3];
    bppscale = fmt[3];
    seq8     = texmode[31];
    lodmask  = tlod[19] ? (tlod[18] ? 9'h0aa : 9'h155) : 9'h1ff;
    if (tlod[20]) begin
      wmask = 8'hff;
      hmask = 8'hff >> tlod[22:21];
    end else begin
      wmask = 8'hff >> tlod[22:21];
      hmask = 8'hff;
    end
  end

  // ----------------------------------------------------------------
  // latched download request
  // ----------------------------------------------------------------
  logic [31:0] d_q;       // post tLOD swizzle/swap
  logic [3:0]  lod_q;
  logic [7:0]  tt_q, ts_q;

  // tLOD bit25 = byte swizzle, then bit26 = 16-bit word swap (gold order)
  logic [31:0] dl_data;
  always_comb begin
    logic [31:0] t;
    t = tlod[25] ? {wr_data[7:0], wr_data[15:8], wr_data[23:16], wr_data[31:24]}
                 : wr_data;
    dl_data = tlod[26] ? {t[15:0], t[31:16]} : t;
  end

  // ----------------------------------------------------------------
  // sequential lodoffset accumulation (tex_recompute):
  // base = (texBaseAddr & 0x7ffff) << 3; each enabled LOD k-1 adds its
  // footprint ((wmask>>(k-1))+1)*((hmask>>(k-1))+1) << bppscale, with the
  // min-4-texel clamp for k >= 4. lodoffset[lod] = base & texmask.
  // ----------------------------------------------------------------
  logic [25:0] acc_q;
  logic [3:0]  li_q;

  logic [8:0]  wsz, hsz;
  logic [17:0] fp;
  logic [18:0] fp_sc;
  always_comb begin
    logic [2:0] k;
    k   = li_q[2:0] - 3'd1;          // li_q is 1..8 while iterating
    wsz = {1'b0, wmask >> k} + 9'd1;
    hsz = {1'b0, hmask >> k} + 9'd1;
    fp  = 18'(wsz) * 18'(hsz);
    if ((li_q >= 4'd4) && (fp < 18'd4))
      fp = 18'd4;
    fp_sc = bppscale ? {fp, 1'b0} : {1'b0, fp};
  end

  // write address generation (after the LOD walk): byte offsets
  logic [20:0] lodoff;
  logic [8:0]  sw1;
  logic [16:0] offs;
  logic [17:0] boff;
  logic [21:0] base_sum;
  logic [20:0] base_b;
  always_comb begin
    lodoff   = acc_q[20:0];                          // & texmask (2MB-1)
    sw1      = {1'b0, wmask >> lod_q[2:0]} + 9'd1;   // smax+1 at this LOD
    offs     = 17'(tt_q) * 17'(sw1) + 17'(ts_q);
    boff     = bpt2 ? {offs[16:1], 2'b00}            // (2*offs) & ~3
                    : {1'b0, offs[16:2], 2'b00};     // offs & ~3
    base_sum = {1'b0, lodoff} + {4'b0, boff};
    base_b   = base_sum[20:0];                       // & texmask
  end

  // ----------------------------------------------------------------
  // FSM
  // ----------------------------------------------------------------
  typedef enum logic [2:0] {T_IDLE, T_LOD, T_WR, T_FIN} tstate_e;
  tstate_e    state_q;
  logic [1:0] wi_q;        // write beat: bpt1 -> 0..3 bytes, bpt2 -> 0..1 words

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q <= T_IDLE;
      d_q     <= '0;
      lod_q   <= '0;
      tt_q    <= '0;
      ts_q    <= '0;
      acc_q   <= '0;
      li_q    <= '0;
      wi_q    <= '0;
    end else begin
      unique case (state_q)
        T_IDLE: begin
          if (wr_valid) begin
            d_q   <= dl_data;
            lod_q <= wr_dwoff[18:15];
            tt_q  <= wr_dwoff[14:7];
            ts_q  <= (seq8 && !bpt2) ? {wr_dwoff[5:0], 2'b00}
                                     : {wr_dwoff[6:0], 1'b0};
            acc_q <= {4'b0, texbaseaddr[18:0], 3'b000};  // (base & 0x7ffff) << 3
            li_q  <= 4'd1;
            wi_q  <= 2'd0;
            // lod > 8: no write at all (gold early return)
            state_q <= (wr_dwoff[18:15] > 4'd8) ? T_FIN : T_LOD;
          end
        end
        T_LOD: begin
          if (li_q > lod_q) begin
            state_q <= T_WR;
          end else begin
            if (lodmask[li_q - 4'd1])
              acc_q <= acc_q + {7'b0, fp_sc};
            li_q <= li_q + 4'd1;
          end
        end
        T_WR: begin
          if (req_ready) begin
            if (wi_q == (bpt2 ? 2'd1 : 2'd3))
              state_q <= T_FIN;
            else
              wi_q <= wi_q + 2'd1;
          end
        end
        T_FIN: state_q <= T_IDLE;
        default: state_q <= T_IDLE;
      endcase
    end
  end

  // write beats: bpt1 = four byte writes at base_b+i; bpt2 = two 16-bit
  // writes at base_b and base_b+2 (byte address rounded down to the word)
  logic [20:0] wb_addr;
  logic [7:0]  wb_byte;
  always_comb begin
    req_valid = 1'b0;
    req_we    = 1'b0;
    req_addr  = '0;
    req_wdata = '0;
    req_be    = 2'b00;
    wr_done   = 1'b0;
    wb_addr   = base_b + {19'b0, wi_q};              // 21-bit wrap == & texmask
    wb_byte   = d_q[{wi_q, 3'b000} +: 8];
    if (state_q == T_WR) begin
      req_valid = 1'b1;
      req_we    = 1'b1;
      if (!bpt2) begin
        req_addr  = wb_addr[20:1];
        req_be    = wb_addr[0] ? 2'b10 : 2'b01;
        req_wdata = {wb_byte, wb_byte};
      end else begin
        req_addr  = (wi_q == 2'd0) ? base_b[20:1]
                                   : (base_b[20:1] + 20'd1); // (base+2)>>1
        req_be    = 2'b11;
        req_wdata = (wi_q == 2'd0) ? d_q[15:0] : d_q[31:16];
      end
    end
    if (state_q == T_FIN)
      wr_done = 1'b1;
  end

  // intentionally unused: dwoff bits above the lod field; non-download
  // texmode/tLOD fields (sampling config, M3); texBaseAddr above the
  // TEX_ADDR_MASK; fmt low bits (only bpt = fmt>=8 matters here).
  logic unused_in;
  assign unused_in = &{1'b0, wr_dwoff[20:19], texmode[30:12], texmode[7:0],
                       tlod[31:27], tlod[24:23], tlod[17:0],
                       texbaseaddr[31:19], fmt[2:0],
                       offs[0], base_sum[21]};   // dropped by &~3 / &texmask

endmodule
