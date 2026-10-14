// sandy: cell-based sand sim engine, row-parallel version
//
// Same interface, storage and rules as engine.sv, but a whole row is moved in
// one clock with bitwise ops instead of one cell per clock. The dice for a row
// come from prob_row as pre-generated random rows, one per kind of roll.
//
// One step walks the rows from the one gravity points at (bottom) to the
// opposite one (top), or alternates between the two orders when g_y is 0. A row takes 3 clocks, plus the wait for its random rows
// (PROB_W clocks to generate), so a step is roughly H * (PROB_W + 3) clocks.
//
// Bit x of a row is cell x: +x is `<< 1`, -x is `>> 1`. Bits shifted out of a
// row are dropped, which is what makes the side walls solid.
module engine_row #(
    parameter int          GRID_W = 640,
    parameter int          GRID_H = 480,
    parameter int          PROB_W = 8,
    parameter int          STEP_W = 4,
    parameter int          SPAWN_R = 4,  // spawn square is 2 * SPAWN_R + 1 wide
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

    // sand source: while `spawn` is high every step fills the square around
    // the cursor. All three are sampled once, at the start of a step.
    input logic [XW-1:0] cursor_x,
    input logic [YW-1:0] cursor_y,
    input logic          spawn,

    // async read of the front buffer (display)
    input  logic [XW-1:0] rd_x,
    input  logic [YW-1:0] rd_y,
    output logic          rd_cell
);

  localparam logic [XW-1:0] X_LAST = XW'(GRID_W - 1);
  localparam logic [YW-1:0] Y_LAST = YW'(GRID_H - 1);
  localparam logic [XW-1:0] X_R = XW'(SPAWN_R);
  localparam logic [YW-1:0] Y_R = YW'(SPAWN_R);
  localparam logic [YW-1:0] Y_FILL = YW'(GRID_H / 8);  // rows of sand at load
  localparam logic [PROB_W:0] P_HALF = (PROB_W + 1)'(1 << (PROB_W - 1));

  typedef logic [GRID_W-1:0] row_t;

  // ---------------------------------------------------------------- buffers
  (* ram_style = "distributed" *) row_t grid0[GRID_H];
  (* ram_style = "distributed" *) row_t grid1[GRID_H];

  logic          we;
  logic          w_sel;  // buffer to write
  logic [YW-1:0] w_y;
  row_t          w_row;

  always_ff @(posedge clk) if (we && !w_sel) grid0[w_y] <= w_row;
  always_ff @(posedge clk) if (we && w_sel) grid1[w_y] <= w_row;

  logic [YW-1:0] y;  // row being moved
  row_t front_row, rd_row;
  assign front_row = buf_sel ? grid1[y] : grid0[y];
  assign rd_row    = buf_sel ? grid1[rd_y] : grid0[rd_y];
  assign rd_cell   = rd_row[rd_x];

  // ------------------------------------------------------------ random rows
  // one roll per cell and kind: fall, gravity sideways, slide, slide direction
  row_t q_y, q_x, q_s, q_d;
  logic q_y_ready, q_x_ready, q_s_ready, q_d_ready, q_ready;
  logic q_next;  // rows used, roll the next set

  prob_row #(
      .W(GRID_W), .PROB_W(PROB_W), .SEED(SEED)
  ) q_y_inst (
      .clk, .rst_n, .p(g_y), .next(q_next), .ready(q_y_ready), .row(q_y)
  );
  prob_row #(
      .W(GRID_W), .PROB_W(PROB_W), .SEED(SEED ^ 32'h1111_1111)
  ) q_x_inst (
      .clk, .rst_n, .p(g_x), .next(q_next), .ready(q_x_ready), .row(q_x)
  );
  prob_row #(
      .W(GRID_W), .PROB_W(PROB_W), .SEED(SEED ^ 32'h2222_2222)
  ) q_s_inst (
      .clk, .rst_n, .p(slide), .next(q_next), .ready(q_s_ready), .row(q_s)
  );
  prob_row #(
      .W(GRID_W), .PROB_W(PROB_W), .SEED(SEED ^ 32'h3333_3333)
  ) q_d_inst (
      .clk, .rst_n, .p(P_HALF), .next(q_next), .ready(q_d_ready), .row(q_d)
  );

  assign q_ready = q_y_ready && q_x_ready && q_s_ready && q_d_ready;

  // ------------------------------------------------------------------ state
  typedef enum logic [2:0] {
    S_INIT,   // first load: sand in the top 1/8 of the front buffer
    S_IDLE,
    S_LOAD,   // fetch row y of the front buffer, wait for the random rows
    S_MOVE,   // move the whole row
    S_STORE,  // row y_ahead is final, write it to the back buffer
    S_LAST,   // write the last row
    S_SWAP    // wait for the display to finish its frame, then swap buffers
  } state_t;

  state_t          state;
  logic   [YW-1:0] y_ahead;   // row index of `ahead`
  logic            up;        // scan top to bottom, set at the start of the step
  logic            up_nxt;
  logic            at_floor;  // y is the first row, nothing ahead of it

  row_t src;    // row y, old generation
  row_t cur;    // row y, new generation
  row_t ahead;  // row gravity pulls row y into, new generation

  assign busy   = (state != S_IDLE);

  // swaps still allowed in this vblank, reloaded when vblank starts
  logic              vblank_q;
  logic [STEP_W-1:0] swaps_left;
  assign q_next = (state == S_MOVE);

  // rows go the way gravity pulls: d_gy, or alternating when it has no y part
  assign up_nxt = (g_y == '0) ? ~up : d_gy;

  // ------------------------------------------------------ rule for row src
  typedef struct packed {
    row_t cur;    // row y after the move
    row_t ahead;  // row ahead of it with the arrivals added
  } moved_t;

  // Called from the S_MOVE branch only, so the simulator does not evaluate
  // these wide ops on every clock. Not automatic on purpose: Verilator would
  // zero every local on every clock.
  function moved_t move_row();
    row_t below;                    // cells straight ahead that are taken
    row_t want_down, do_slide, want_side, neg;
    row_t diag_n, diag_p;           // want (x -/+ 1, ahead)
    row_t side_n, side_p;           // want (x -/+ 1, y)
    row_t stuck_n, stuck_p;         // side_n / side_p that slide instead
    row_t diag_n_to, diag_p_to, side_n_to, side_p_to;  // landings
    row_t fall;                     // leave straight down
    row_t ahead_1, ahead_2;
    row_t cur_1, cur_2;

    below     = at_floor ? '1 : ahead;
    want_down = src & q_y;

    // slide: gravity wants us down but we can't, go diagonal, 50/50 each way.
    // This overrides the horizontal move of gravity.
    do_slide  = want_down & below & q_s;
    want_side = (src & q_x) | do_slide;
    neg       = (do_slide & q_d) | (~do_slide & {GRID_W{d_gx}});

    diag_n = want_side & want_down & neg;
    diag_p = want_side & want_down & ~neg;
    side_n = want_side & ~want_down & neg;
    side_p = want_side & ~want_down & ~neg;

    // The same slide for sideways gravity: the cell beside us is taken (or is
    // the wall), go diagonal into the row ahead. With no pull along y the row
    // scan flips every step, so "ahead" is the row above and below in turn.
    stuck_n = side_n & {src[GRID_W-2:0], 1'b1} & q_s;
    stuck_p = side_p & {1'b1, src[GRID_W-1:1]} & q_s;
    diag_n  = diag_n | stuck_n;
    diag_p  = diag_p | stuck_p;
    side_n  = side_n & ~stuck_n;
    side_p  = side_p & ~stuck_p;

    // Each group lands only on cells nobody holds yet, groups go one after
    // the other so two cells never land on the same place.
    diag_n_to = (diag_n >> 1) & ~below;
    ahead_1   = below | diag_n_to;
    diag_p_to = (diag_p << 1) & ~ahead_1;
    ahead_2   = ahead_1 | diag_p_to;

    // sideways blocked: drop it, but still fall if the cell ahead is free
    fall           = want_down & ~(diag_n_to << 1) & ~(diag_p_to >> 1) & ~ahead_2;
    move_row.ahead = ahead_2 | fall;

    // what stays in row y, then the moves inside it
    cur_1        = src & ~(diag_n_to << 1) & ~(diag_p_to >> 1) & ~fall;
    side_n_to    = (side_n >> 1) & ~cur_1;
    cur_2        = (cur_1 & ~(side_n_to << 1)) | side_n_to;
    side_p_to    = (side_p << 1) & ~cur_2;
    move_row.cur = (cur_2 & ~(side_p_to >> 1)) | side_p_to;
  endfunction

  // ------------------------------------------------------------------ spawn
  // frozen at the start of the step: the columns of the square as a row mask,
  // and the rows it covers
  logic          spawn_q;
  row_t          spawn_mask;
  logic [YW-1:0] spawn_y_lo, spawn_y_hi;
  logic          spawn_row;  // row y is inside the square

  assign spawn_row = spawn_q && (y >= spawn_y_lo) && (y <= spawn_y_hi);

  // ones in columns lo..hi
  function row_t col_mask(input logic [XW-1:0] lo, input logic [XW-1:0] hi);
    col_mask = ({GRID_W{1'b1}} << lo) & ~(({GRID_W{1'b1}} << hi) << 1);
  endfunction

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
          up       <= up_nxt;
          y        <= up_nxt ? '0 : Y_LAST;
          at_floor <= 1'b1;
          state    <= S_LOAD;

          spawn_q    <= spawn;
          spawn_mask <= col_mask(
              (cursor_x < X_R) ? '0 : cursor_x - X_R,
              (cursor_x > X_LAST - X_R) ? X_LAST : cursor_x + X_R
          );
          spawn_y_lo <= (cursor_y < Y_R) ? '0 : cursor_y - Y_R;
          spawn_y_hi <= (cursor_y > Y_LAST - Y_R) ? Y_LAST : cursor_y + Y_R;
        end
      end

      S_LOAD: begin
        src <= front_row;
        if (q_ready) state <= S_MOVE;
      end

      S_MOVE: begin
        automatic moved_t m = move_row();
        cur <= spawn_row ? (m.cur | spawn_mask) : m.cur;
        if (!at_floor) ahead <= m.ahead;
        state <= S_STORE;
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
      spawn_q    <= 1'b0;
      up         <= 1'b0;
      vblank_q   <= 1'b0;
      swaps_left <= '0;
    end
  end

endmodule
