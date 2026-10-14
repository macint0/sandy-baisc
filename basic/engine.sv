// sandy: cell-based sand sim engine
//
// Two cell types, 1 bit per cell: 0 = air, 1 = sand.
// The grid is kept in two distributed RAMs (ping-pong), one GRID_W-bit word per
// row. buf_sel picks the front buffer: a step reads rows from the front buffer,
// builds the next generation in the back buffer, then flips buf_sel.
// The display always reads the front buffer, so the flip waits for vblank.
//
// One step walks the rows from the one gravity points at (bottom) to the
// opposite one (top), and each row left to right, one cell per clock:
//   H * (W + 2) + 1 clocks per step, plus the wait for vblank.
//
// Probabilities are unsigned Q1.PROB_W: 0 = never, 1 << PROB_W = always.
module engine #(
    parameter int          GRID_W = 640,
    parameter int          GRID_H = 480,
    parameter int          PROB_W = 8,
    parameter int          STEP_W = 4,
    parameter logic [31:0] SEED   = 32'h5A17_D00D,
    // derived, do not override
    parameter int          XW     = $clog2(GRID_W),
    parameter int          YW     = $clog2(GRID_H)
) (
    input logic clk,
    input logic rst_n,

    // gravity: (g_x, g_y) is the chance of moving one cell along each axis,
    // (d_gx, d_gy) is the direction: 0 = +x (right) / +y (down), 1 = -x / -y
    input logic [PROB_W:0] g_x,
    input logic [PROB_W:0] g_y,
    input logic            d_gx,
    input logic            d_gy,
    // chance of sliding sideways when the cell gravity pulls us into is taken
    input logic [PROB_W:0] slide,

    input  logic run,      // keep stepping while high
    input  logic vblank,   // display is not reading, safe to swap buffers
    // steps shown per display frame. All swaps happen in vblank, so every step
    // after the first has to fit in what is left of it, the rest is dropped.
    input  logic [STEP_W-1:0] steps_per_frame,
    output logic busy,     // initialising or stepping
    output logic done,     // one clock pulse, buffers have just been swapped
    output logic buf_sel,  // front buffer

    // async read of the front buffer (display)
    input  logic [XW-1:0] rd_x,
    input  logic [YW-1:0] rd_y,
    output logic          rd_cell
);

  localparam logic [XW-1:0] X_LAST = XW'(GRID_W - 1);
  localparam logic [YW-1:0] Y_LAST = YW'(GRID_H - 1);
  localparam logic [YW-1:0] Y_FILL = YW'(GRID_H / 8);  // rows of sand at load

  // ---------------------------------------------------------------- buffers
  (* ram_style = "distributed" *) logic [GRID_W-1:0] grid0[GRID_H];
  (* ram_style = "distributed" *) logic [GRID_W-1:0] grid1[GRID_H];

  logic              we;
  logic              w_sel;  // buffer to write
  logic [    YW-1:0] w_y;
  logic [GRID_W-1:0] w_row;

  always_ff @(posedge clk) if (we && !w_sel) grid0[w_y] <= w_row;
  always_ff @(posedge clk) if (we && w_sel) grid1[w_y] <= w_row;

  logic [YW-1:0] y;  // row being moved
  logic [GRID_W-1:0] front_row, rd_row;
  assign front_row = buf_sel ? grid1[y] : grid0[y];
  assign rd_row    = buf_sel ? grid1[rd_y] : grid0[rd_y];
  assign rd_cell   = rd_row[rd_x];

  // ----------------------------------------------------------------- random
  // xorshift32, a fresh word every clock
  logic [31:0] rng, rng_a, rng_b;
  assign rng_a = rng ^ (rng << 13);
  assign rng_b = rng_a ^ (rng_a >> 17);

  always_ff @(posedge clk) begin
    if (!rst_n) rng <= (SEED == '0) ? 32'd1 : SEED;
    else rng <= rng_b ^ (rng_b << 5);
  end

  // ------------------------------------------------------------------ state
  typedef enum logic [2:0] {
    S_INIT,   // first load: sand in the top 1/8 of the front buffer
    S_IDLE,
    S_LOAD,   // fetch row y of the front buffer
    S_CELL,   // move cell x of that row
    S_STORE,  // row y_ahead is final, write it to the back buffer
    S_LAST,   // write the last row
    S_SWAP    // wait for the display to finish its frame, then swap buffers
  } state_t;

  state_t            state;
  logic   [  XW-1:0] x;
  logic   [  YW-1:0] y_ahead;   // row index of `ahead`
  logic              up;        // d_gy sampled at the start of the step
  logic              at_floor;  // y is the first row, nothing ahead of it

  logic   [GRID_W-1:0] src;    // row y, old generation
  logic   [GRID_W-1:0] cur;    // row y, new generation
  logic   [GRID_W-1:0] ahead;  // row gravity pulls row y into, new generation

  assign busy = (state != S_IDLE);

  // swaps still allowed in this vblank, reloaded when vblank starts
  logic              vblank_q;
  logic [STEP_W-1:0] swaps_left;

  // ------------------------------------------------------- rule for cell x
  logic want_down, grav_side, do_slide, want_side;
  logic blocked_down;  // cell straight ahead is taken (or is the floor)
  logic left;          // sideways direction, 1 = -x
  logic at_wall;
  logic [XW-1:0] xs;   // x of the sideways cell
  logic side_free, move_side, move_down;

  always_comb begin
    want_down    = {1'b0, rng[PROB_W-1:0]} < g_y;
    grav_side    = {1'b0, rng[PROB_W+:PROB_W]} < g_x;
    blocked_down = at_floor || ahead[x];

    // slide: gravity wants us down but we can't, go diagonal, 50/50 each way.
    // This overrides the horizontal move of gravity.
    do_slide  = want_down && blocked_down && ({1'b0, rng[2*PROB_W+:PROB_W]} < slide);
    want_side = grav_side || do_slide;
    left      = do_slide ? rng[31] : d_gx;

    at_wall = left ? (x == '0) : (x == X_LAST);
    xs      = at_wall ? x : (left ? x - 1'b1 : x + 1'b1);

    // Target is (xs, ahead) with a down move, (xs, y) without. In row y the
    // cells left of x are already moved (cur), the ones right of it are not
    // (src), a cell that has not moved yet still owns its place.
    if (at_wall) side_free = 1'b0;
    else if (want_down) side_free = !at_floor && !ahead[xs];
    else side_free = !cur[xs] && (left || !src[xs]);

    // sideways blocked: drop it, but still fall if the cell ahead is free
    move_side = want_side && side_free;
    move_down = want_down && !blocked_down;
  end

  // -------------------------------------------------------------- sequencer
  always_comb begin
    we    = 1'b0;
    w_sel = ~buf_sel;
    w_y   = y_ahead;
    w_row = ahead;
    unique case (state)
      S_INIT: begin
        we    = 1'b1;
        w_sel = buf_sel;
        w_y   = y;
        w_row = (y < Y_FILL) ? '1 : '0;
      end
      S_STORE: we = !at_floor;
      S_LAST:  we = 1'b1;
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    done <= 1'b0;

    unique case (state)
      S_INIT: begin
        y <= y + 1'b1;
        if (y == Y_LAST) state <= S_IDLE;
      end

      S_IDLE: begin
        if (run) begin
          up       <= d_gy;
          y        <= d_gy ? '0 : Y_LAST;
          at_floor <= 1'b1;
          state    <= S_LOAD;
        end
      end

      S_LOAD: begin
        src   <= front_row;
        cur   <= '0;
        x     <= '0;
        state <= S_CELL;
      end

      S_CELL: begin
        if (src[x]) begin
          if (move_side) begin
            if (want_down) ahead[xs] <= 1'b1;
            else cur[xs] <= 1'b1;
          end else if (move_down) ahead[x] <= 1'b1;
          else cur[x] <= 1'b1;
        end
        x <= x + 1'b1;
        if (x == X_LAST) state <= S_STORE;
      end

      S_STORE: begin
        ahead    <= cur;
        y_ahead  <= y;
        at_floor <= 1'b0;
        if (y == (up ? Y_LAST : '0)) state <= S_LAST;
        else begin
          y     <= up ? y + 1'b1 : y - 1'b1;
          state <= S_LOAD;
        end
      end

      S_LAST: state <= S_SWAP;

      S_SWAP: begin
        if (vblank && swaps_left != '0) begin
          buf_sel    <= ~buf_sel;
          done       <= 1'b1;
          swaps_left <= swaps_left - 1'b1;
          state      <= S_IDLE;
        end
      end

      default: state <= S_IDLE;
    endcase

    vblank_q <= vblank;
    if (vblank && !vblank_q) swaps_left <= steps_per_frame;

    if (!rst_n) begin
      state      <= S_INIT;
      buf_sel    <= 1'b0;
      y          <= '0;
      done       <= 1'b0;
      vblank_q   <= 1'b0;
      swaps_left <= '0;
    end
  end

endmodule
