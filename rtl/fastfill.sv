// fastfill.sv — CONTRACTS §8 M1 + §9.3/§9.6: clip-rect fill; color = color1
// dithered through the shared pkg dither565 (fbzMode bit8 enable, bit11 type),
// aux fill = zaColor[15:0]; honors rgb/aux write masks; NO y-flip; OOB drop.
module fastfill
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // launch (parameters latched at go; done pulses on completion)
    input  logic        go,
    output logic        done,

    input  logic [9:0]  clip_left,    // inclusive
    input  logic [9:0]  clip_right,   // exclusive
    input  logic [9:0]  clip_top,     // inclusive
    input  logic [9:0]  clip_bottom,  // exclusive
    input  logic [31:0] color1,
    input  logic [15:0] zfill,        // zaColor[15:0]
    input  logic        dith_en,      // fbzMode bit 8
    input  logic        dith_2x2,     // fbzMode bit 11
    input  logic        rgb_en,       // fbzMode bit 9
    input  logic        aux_en,       // fbzMode bit 10
    input  logic [FB_AW-1:0] dest_base,
    input  logic             dest_valid,
    input  logic [FB_AW-1:0] aux_base,
    input  logic             aux_valid,
    input  logic [10:0] rowpixels,

    // fb_arb client 1 port (§7.3)
    output logic              req_valid,
    input  logic              req_ready,
    output logic              req_we,
    output logic [FB_AW-1:0]  req_addr,
    output logic [15:0]       req_wdata,
    input  logic              rsp_valid,
    input  logic [15:0]       rsp_rdata
);

  // latched parameters (top is consumed immediately as the starting y)
  logic [9:0]       l_q, r_q, b_q;
  logic [23:0]      c1_q;          // {r,g,b}
  logic [15:0]      zfill_q;
  logic             den_q, d2_q, rgb_q, aux_q, dv_q, av_q;
  logic [FB_AW-1:0] dbase_q, abase_q;
  logic [10:0]      rp_q;

  // walk state
  logic [9:0]  x_q, y_q;
  logic [20:0] rowbase_q;

  typedef enum logic [2:0] {F_IDLE, F_ROW, F_PC, F_PA, F_DONE} fstate_e;
  fstate_e state_q;

  // per-pixel values
  logic [21:0] idx, addr_c, addr_a;
  logic        wc, wa;
  logic [15:0] fill565;
  always_comb begin
    idx     = {1'b0, rowbase_q} + {12'b0, x_q};
    addr_c  = {1'b0, dbase_q} + idx;
    addr_a  = {1'b0, abase_q} + idx;
    // OOB drop per CONTRACTS §9.6 (sy = y, never negative, <= 1023)
    wc      = rgb_q & dv_q & ~addr_c[21];
    wa      = aux_q & av_q & ~addr_a[21];
    fill565 = dither565(c1_q[23:16], c1_q[15:8], c1_q[7:0],
                        den_q, d2_q, x_q[1:0], y_q[1:0]);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q   <= F_IDLE;
      l_q <= '0; r_q <= '0; b_q <= '0;
      c1_q      <= '0;
      zfill_q   <= '0;
      den_q <= 1'b0; d2_q <= 1'b0; rgb_q <= 1'b0; aux_q <= 1'b0;
      dv_q <= 1'b0; av_q <= 1'b0;
      dbase_q   <= '0;
      abase_q   <= '0;
      rp_q      <= '0;
      x_q <= '0; y_q <= '0;
      rowbase_q <= '0;
    end else begin
      unique case (state_q)
        F_IDLE: begin
          if (go) begin
            l_q     <= clip_left;
            r_q     <= clip_right;
            b_q     <= clip_bottom;
            c1_q    <= color1[23:0];
            zfill_q <= zfill;
            den_q   <= dith_en;
            d2_q    <= dith_2x2;
            rgb_q   <= rgb_en;
            aux_q   <= aux_en;
            dv_q    <= dest_valid;
            av_q    <= aux_valid;
            dbase_q <= dest_base;
            abase_q <= aux_base;
            rp_q    <= rowpixels;
            y_q     <= clip_top;
            // !dest_valid drops the WHOLE fill incl. aux (MAME reg_fastfill_w
            // returns before any write when draw_buffer_indirect is null)
            state_q <= (!dest_valid || (clip_top >= clip_bottom)
                        || (clip_left >= clip_right))
                     ? F_DONE : F_ROW;
          end
        end
        F_ROW: begin
          rowbase_q <= 21'(y_q) * 21'(rp_q);
          x_q       <= l_q;
          state_q   <= F_PC;
        end
        F_PC: if (!wc || req_ready) state_q <= F_PA;
        F_PA: begin
          if (!wa || req_ready) begin
            if ({1'b0, x_q} + 11'd1 < {1'b0, r_q}) begin
              x_q     <= x_q + 10'd1;
              state_q <= F_PC;
            end else if ({1'b0, y_q} + 11'd1 < {1'b0, b_q}) begin
              y_q     <= y_q + 10'd1;
              state_q <= F_ROW;
            end else begin
              state_q <= F_DONE;
            end
          end
        end
        F_DONE: state_q <= F_IDLE;
        default: state_q <= F_IDLE;
      endcase
    end
  end

  always_comb begin
    req_valid = 1'b0;
    req_we    = 1'b0;
    req_addr  = '0;
    req_wdata = '0;
    done      = 1'b0;
    unique case (state_q)
      F_PC: begin
        req_valid = wc; req_we = 1'b1;
        req_addr = addr_c[FB_AW-1:0]; req_wdata = fill565;
      end
      F_PA: begin
        req_valid = wa; req_we = 1'b1;
        req_addr = addr_a[FB_AW-1:0]; req_wdata = zfill_q;
      end
      F_DONE: done = 1'b1;
      default: ;
    endcase
  end

  // fastfill never reads from the framebuffer; color1 alpha is not filled
  logic unused_rsp;
  assign unused_rsp = &{1'b0, rsp_valid, rsp_rdata, color1[31:24]};

endmodule
