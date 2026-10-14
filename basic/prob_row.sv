// Random row for the row-parallel engine: every bit of `row` is 1 with chance p
// (unsigned Q1.PROB_W: 0 = never, 1 << PROB_W = always), independent per bit.
//
// A row is pre-generated right after reset and after every `next`, so it is
// normally waiting (ready = 1) by the time the engine wants it. Building one
// takes PROB_W clocks: starting from 0, each bit of p (LSB first) folds a fresh
// 50/50 word u into the row
//   bit = 1: row | u  -> chance (1 + c) / 2
//   bit = 0: row & u  -> chance      c  / 2
// which shifts that bit into the binary fraction of the chance c.
module prob_row #(
    parameter int          W      = 640,
    parameter int          PROB_W = 8,
    parameter logic [31:0] SEED   = 32'h5A17_D00D
) (
    input logic clk,
    input logic rst_n,

    input  logic [PROB_W:0] p,
    input  logic            next,   // row consumed, start the next one
    output logic            ready,  // row is valid, holds until `next`
    output logic [   W-1:0] row
);

  localparam int NGEN = (W + 31) / 32;
  localparam int IW = (PROB_W > 1) ? $clog2(PROB_W) : 1;
  localparam logic [IW-1:0] I_LAST = IW'(PROB_W - 1);

  // ------------------------------------------------------------ 50/50 word
  // one xorshift32 per 32 bits of row, each with its own seed, only clocked
  // while a row is being built
  function automatic logic [31:0] seed_of(input int k);
    logic [31:0] s;
    s = SEED ^ (32'h9E37_79B9 * 32'(k + 1));
    return (s == '0) ? 32'd1 : s;
  endfunction

  // verilator lint_off UNUSEDSIGNAL
  logic [NGEN*32-1:0] u;  // top bits spare when W is not a multiple of 32
  // verilator lint_on UNUSEDSIGNAL

  for (genvar k = 0; k < NGEN; k++) begin : g_rng
    logic [31:0] rng, rng_a, rng_b;
    assign rng_a = rng ^ (rng << 13);
    assign rng_b = rng_a ^ (rng_a >> 17);

    always_ff @(posedge clk) begin
      if (!rst_n) rng <= seed_of(k);
      else if (!ready) rng <= rng_b ^ (rng_b << 5);
    end

    assign u[k*32+:32] = rng;
  end

  // ------------------------------------------------------------- generator
  logic [    IW-1:0] i;     // bit of p being folded in
  logic [PROB_W-1:0] frac;  // p below 1.0
  assign frac = p[PROB_W-1:0];

  always_ff @(posedge clk) begin
    if (!ready) begin
      if (p[PROB_W]) row <= '1;
      else row <= frac[i] ? (row | u[W-1:0]) : (row & u[W-1:0]);
      i <= i + 1'b1;
      if (i == I_LAST) ready <= 1'b1;
    end else if (next) begin
      ready <= 1'b0;
      row   <= '0;
      i     <= '0;
    end

    if (!rst_n) begin
      ready <= 1'b0;
      row   <= '0;
      i     <= '0;
    end
  end

endmodule
