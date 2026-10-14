module top_sandy #(
    parameter CORDW = 10,  // coordinate width
    parameter STEPS_PER_FRAME = 1  // sim steps per display frame
) (
    input  wire logic             clk_pix,    // pixel clock
    input  wire logic             sim_rst,    // sim reset
    input  wire logic             btn_up,     // move cursor
    input  wire logic             btn_down,
    input  wire logic             btn_left,
    input  wire logic             btn_right,
    input  wire logic             btn_spawn,  // spawn sand at cursor
    input  wire logic [      3:0] btn_grav,   // set gravity: [0] down [1] up [2] left [3] right
    output logic      [CORDW-1:0] sdl_sx,     // horizontal SDL position
    output logic      [CORDW-1:0] sdl_sy,     // vertical SDL position
    output logic                  sdl_de,     // data enable (low in blanking interval)
    output logic      [      7:0] sdl_r,      // 8-bit red
    output logic      [      7:0] sdl_g,      // 8-bit green
    output logic      [      7:0] sdl_b       // 8-bit blue
);

  localparam GRID_W  = 640;  // one cell per pixel
  localparam GRID_H  = 480;
  localparam SPAWN_R = 4;    // spawn square is 2 * SPAWN_R + 1 wide

  // display sync signals and coordinates
  logic [CORDW-1:0] sx, sy;
  logic de;
  simple_480p display_inst (
      .clk_pix(clk_pix),
      .rst_pix(sim_rst),
      .sx,
      .sy,
      .hsync  (),
      .vsync  (),
      .de
  );

  // lines below the active area: the display is done with the front buffer
  logic vblank, frame;
  always_comb begin
    vblank = (sy >= GRID_H);
    frame  = (sy == GRID_H && sx == 0);  // one pulse per frame, start of vblank
  end

  // cursor: moves once per frame, so it holds still while a frame is drawn
  logic [9:0] cur_x;
  logic [8:0] cur_y;
  cursor #(
      .GRID_W(GRID_W),
      .GRID_H(GRID_H)
  ) cursor_inst (
      .clk  (clk_pix),
      .rst_n(!sim_rst),
      .tick (frame),
      .up   (btn_up),
      .down (btn_down),
      .left (btn_left),
      .right(btn_right),
      .x    (cur_x),
      .y    (cur_y)
  );

  // gravity: one of four directions, kept until another button is pressed
  localparam logic [8:0] G = 9'd128;  // 0.5
  typedef enum logic [1:0] {
    G_DOWN,
    G_UP,
    G_LEFT,
    G_RIGHT
  } grav_t;

  grav_t grav;
  always_ff @(posedge clk_pix) begin
    if (btn_grav[0]) grav <= G_DOWN;
    else if (btn_grav[1]) grav <= G_UP;
    else if (btn_grav[2]) grav <= G_LEFT;
    else if (btn_grav[3]) grav <= G_RIGHT;
    if (sim_rst) grav <= G_DOWN;
  end

  logic [8:0] g_x, g_y;
  logic d_gx, d_gy;
  always_comb begin
    g_x  = (grav == G_LEFT || grav == G_RIGHT) ? G : '0;
    g_y  = (grav == G_DOWN || grav == G_UP) ? G : '0;
    d_gx = (grav == G_LEFT);
    d_gy = (grav == G_UP);
  end

  // sand sim: steps freely, swaps buffers in vblank
  logic sand;
  engine_row #(
      .GRID_W (GRID_W),
      .GRID_H (GRID_H),
      .SPAWN_R(SPAWN_R)
  ) engine_inst (
      .clk            (clk_pix),
      .rst_n          (!sim_rst),
      .g_x,
      .g_y,
      .d_gx,
      .d_gy,
      .slide          (9'd200),               // 0.5
      .run            (1'b1),
      .vblank,
      .steps_per_frame(4'(STEPS_PER_FRAME)),
      .cursor_x       (cur_x),
      .cursor_y       (cur_y),
      .spawn          (btn_spawn),
      .busy           (),
      .done           (),
      .buf_sel        (),
      .rd_x           (de ? sx : '0),
      .rd_y           (de ? sy[8:0] : '0),
      .rd_cell        (sand)
  );

  // cursor box: outline of the spawn square. Its edges are frozen in vblank,
  // one clock after the cursor took its move, and hold for the whole frame.
  logic frame_q;
  logic [CORDW-1:0] box_x0, box_x1, box_y0, box_y1;
  always_ff @(posedge clk_pix) begin
    frame_q <= frame;
    if (frame_q) begin
      box_x0 <= (cur_x < SPAWN_R) ? '0 : cur_x - SPAWN_R;
      box_x1 <= (cur_x > GRID_W - 1 - SPAWN_R) ? GRID_W - 1 : cur_x + SPAWN_R;
      box_y0 <= (cur_y < SPAWN_R) ? '0 : {1'b0, cur_y} - SPAWN_R;
      box_y1 <= (cur_y > GRID_H - 1 - SPAWN_R) ? GRID_H - 1 : {1'b0, cur_y} + SPAWN_R;
    end
  end

  logic box;
  always_comb begin
    box = (sx >= box_x0 && sx <= box_x1) && (sy >= box_y0 && sy <= box_y1) &&
          (sx == box_x0 || sx == box_x1 || sy == box_y0 || sy == box_y1);
  end

  // paint colours: white cursor box, yellow sand, dark blue air
  logic [3:0] paint_r, paint_g, paint_b;
  always_comb begin
    paint_r = (box) ? 4'hF : (sand) ? 4'hE : 4'h1;
    paint_g = (box) ? 4'hF : (sand) ? 4'hC : 4'h3;
    paint_b = (box) ? 4'hF : (sand) ? 4'h5 : 4'h7;
  end

  // SDL output (8 bits per colour channel)
  always_ff @(posedge clk_pix) begin
    sdl_sx <= sx;
    sdl_sy <= sy;
    sdl_de <= de;
    sdl_r  <= {2{paint_r}};  // double signal width from 4 to 8 bits
    sdl_g  <= {2{paint_g}};
    sdl_b  <= {2{paint_b}};
  end
endmodule
