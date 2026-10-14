// Cursor on the grid, moved by four direction inputs. It only moves on `tick`
// (once per frame), SPEED cells at a time, and stops at the grid edges.
module cursor #(
    parameter int GRID_W = 640,
    parameter int GRID_H = 480,
    parameter int SPEED  = 3,
    // derived, do not override
    parameter int XW     = $clog2(GRID_W),
    parameter int YW     = $clog2(GRID_H)
) (
    input logic clk,
    input logic rst_n,

    input logic tick,  // pulse: take one move
    input logic up,
    input logic down,
    input logic left,
    input logic right,

    output logic [XW-1:0] x,
    output logic [YW-1:0] y
);

  localparam logic [XW-1:0] X_LAST = XW'(GRID_W - 1);
  localparam logic [YW-1:0] Y_LAST = YW'(GRID_H - 1);
  localparam logic [XW-1:0] X_STEP = XW'(SPEED);
  localparam logic [YW-1:0] Y_STEP = YW'(SPEED);

  always_ff @(posedge clk) begin
    if (tick) begin
      if (left && !right) x <= (x < X_STEP) ? '0 : x - X_STEP;
      if (right && !left) x <= (x > X_LAST - X_STEP) ? X_LAST : x + X_STEP;
      if (up && !down) y <= (y < Y_STEP) ? '0 : y - Y_STEP;
      if (down && !up) y <= (y > Y_LAST - Y_STEP) ? Y_LAST : y + Y_STEP;
    end

    if (!rst_n) begin
      x <= XW'(GRID_W / 2);
      y <= YW'(GRID_H / 2);
    end
  end

endmodule
