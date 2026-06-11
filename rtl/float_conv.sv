// float_conv.sv — CONTRACTS §5: float_to_int32/float_to_int64, combinational,
// ported bit-exact from voodoo_soft.c lines 56-80 (MAME float_to_int32).
module float_conv (
    input  logic [31:0] data,       // IEEE-754 single bit pattern
    input  logic [5:0]  fixedbits,  // 4 (vertices), 12 (colors/Z), 32 (S/T/W)
    output logic [31:0] out32,
    output logic [63:0] out64
);

  // exponent = ((data>>23)&0xff) - 127 - 23 + fixedbits   (range -150..+137)
  logic signed [9:0] exponent;
  logic [23:0]       mant;       // (data & 0x7fffff) | 0x800000
  logic [5:0]        rsh;        // -exponent (mod 64); only used when the
                                 // in-range branch is taken, so 6 bits suffice

  always_comb begin
    exponent = $signed({2'b00, data[30:23]}) - 10'sd150
             + $signed({4'b0000, fixedbits});
    mant     = {1'b1, data[22:0]};
    rsh      = 6'(-exponent);
  end

  // 32-bit conversion
  always_comb begin
    logic [31:0] r;
    if (exponent < 0) begin
      // (exponent > -32) ? (result >> -exponent) : 0
      r = (exponent > -10'sd32) ? ({8'b0, mant} >> rsh[4:0]) : 32'h0;
    end else begin
      // (exponent < 32) ? (result << exponent) : 0x7fffffff  (truncates mod 2^32)
      r = (exponent < 10'sd32) ? 32'({8'b0, mant} << exponent[4:0]) : 32'h7fffffff;
    end
    out32 = data[31] ? (~r + 32'd1) : r;
  end

  // 64-bit conversion
  always_comb begin
    logic [63:0] r;
    if (exponent < 0) begin
      r = (exponent > -10'sd64) ? ({40'b0, mant} >> rsh) : 64'h0;
    end else begin
      r = (exponent < 10'sd64) ? 64'({40'b0, mant} << exponent[5:0])
                               : 64'h7fffffffffffffff;
    end
    out64 = data[31] ? (~r + 64'd1) : r;
  end

endmodule
