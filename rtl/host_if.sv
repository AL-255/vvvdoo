// host_if.sv — CONTRACTS §5/§6: host handshake, 64-deep command FIFO of
// {is_write, addr[23:2], data, be}, read gating (status reads immediate, all
// other reads drain FIFO + engines first), one outstanding read, resp pulse.
module host_if
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // host BAR ports (CONTRACTS §6)
    input  logic        host_wr_valid,
    output logic        host_wr_ready,      // registered: no valid->ready path
    input  logic [23:2] host_wr_addr,
    input  logic [31:0] host_wr_data,
    input  logic [3:0]  host_wr_be,

    input  logic        host_rd_valid,
    output logic        host_rd_ready,
    input  logic [23:2] host_rd_addr,
    output logic        host_rd_resp_valid, // 1-cycle pulse with data
    output logic [31:0] host_rd_data,

    // FIFO head (popped by cmd_dispatch)
    output logic        cmd_valid,
    input  logic        cmd_pop,
    output logic        cmd_is_write,
    output logic [23:2] cmd_addr,
    output logic [31:0] cmd_data,
    output logic [3:0]  cmd_be,

    // read execution response from cmd_dispatch (non-status reads)
    input  logic        rd_resp_valid,
    input  logic [31:0] rd_resp_data,

    // status value from regfile (sampled at acceptance)
    input  logic [31:0] status_value,

    // any engine active (dispatch busy) — gates non-status reads
    input  logic        engines_busy,

    output logic [6:0]  fifo_free,          // 64 - level (for status[5:0])
    output logic        fifo_nonempty
);

  // ----------------------------------------------------------------
  // command FIFO: 64 x {is_write, addr, data, be} = 59 bits
  // ----------------------------------------------------------------
  typedef struct packed {
    logic        is_write;
    logic [23:2] addr;
    logic [31:0] data;
    logic [3:0]  be;
  } fent_t;

  fent_t      fifo_mem [0:63];
  logic [5:0] wptr_q, rptr_q;
  logic [6:0] count_q, count_next;
  logic       rd_busy_q;

  logic wpush, rd_accept, rpush, pop, is_status;

  always_comb begin
    wpush     = host_wr_valid & host_wr_ready;
    // status read = register window, decoded regnum 0 (the alias map fixes 0)
    is_status = (host_rd_addr[23:22] == 2'b00) && (host_rd_addr[9:2] == 8'h00);
    // status reads immediate; everything else drains FIFO + engines first
    host_rd_ready = ~rd_busy_q &
                    (is_status | ((count_q == 7'd0) & ~engines_busy));
    rd_accept = host_rd_valid & host_rd_ready;
    rpush     = rd_accept & ~is_status;
    pop       = cmd_pop & (count_q != 7'd0);

    count_next = count_q;
    if (wpush) count_next = count_next + 7'd1;
    if (rpush) count_next = count_next + 7'd1;
    if (pop)   count_next = count_next - 7'd1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr_q             <= 6'd0;
      rptr_q             <= 6'd0;
      count_q            <= 7'd0;
      host_wr_ready      <= 1'b0;
      rd_busy_q          <= 1'b0;
      host_rd_resp_valid <= 1'b0;
      host_rd_data       <= 32'h0;
    end else begin
      count_q       <= count_next;
      host_wr_ready <= (count_next < 7'd64);

      // wpush and rpush can coincide only when count==0 (read gating);
      // the write is queued first to preserve trace order
      if (wpush)
        fifo_mem[wptr_q] <= '{is_write: 1'b1, addr: host_wr_addr,
                              data: host_wr_data, be: host_wr_be};
      if (rpush)
        fifo_mem[wptr_q + (wpush ? 6'd1 : 6'd0)]
            <= '{is_write: 1'b0, addr: host_rd_addr, data: 32'h0, be: 4'h0};
      wptr_q <= wptr_q + (wpush ? 6'd1 : 6'd0) + (rpush ? 6'd1 : 6'd0);
      if (pop)
        rptr_q <= rptr_q + 6'd1;

      // read response handling: resp pulses 1+ cycles after acceptance
      if (host_rd_resp_valid) begin
        host_rd_resp_valid <= 1'b0;
        rd_busy_q          <= 1'b0;
      end
      if (rd_accept) begin
        rd_busy_q <= 1'b1;
        if (is_status) begin
          host_rd_resp_valid <= 1'b1;
          host_rd_data       <= status_value;
        end
      end
      if (rd_resp_valid) begin
        host_rd_resp_valid <= 1'b1;
        host_rd_data       <= rd_resp_data;
      end
    end
  end

  // FIFO head
  fent_t head;
  always_comb begin
    head         = fifo_mem[rptr_q];
    cmd_valid    = (count_q != 7'd0);
    cmd_is_write = head.is_write;
    cmd_addr     = head.addr;
    cmd_data     = head.data;
    cmd_be       = head.be;
    fifo_free    = 7'd64 - count_q;
    fifo_nonempty = (count_q != 7'd0);
  end

endmodule
