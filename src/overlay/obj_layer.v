`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"
`include "game/game_defs.vh"

module obj_layer #(
	`SVO_DEFAULT_PARAMS,
	parameter MAX_OBJ       = 16,
	parameter LANE_BITS     = 4,
	parameter XOFF_BITS     = 4,
	parameter OBJ_TYPE_BITS = 3,
	parameter OBJ_Y_BITS    = 10
) (
	input clk,
	input resetn,

	// object state from game controller
	input [9:0] player_x,
	input       player_dir,
	input [9:0] player_y,
	input       skill_on,
	input       clone_on,
	input [`FLY_CLONES*10-1:0] fly_x_bus,
	input [`FLY_CLONES*10-1:0] fly_y_bus,
	input [`FLY_CLONES-1:0] fly_active,

	input [MAX_OBJ              -1:0] obj_valid_bus,
	input [MAX_OBJ*LANE_BITS    -1:0] obj_lane_bus,
	input [MAX_OBJ*XOFF_BITS    -1:0] obj_xoff_bus,
	input [MAX_OBJ*OBJ_Y_BITS   -1:0] obj_ypos_bus,
	input [MAX_OBJ*OBJ_TYPE_BITS-1:0] obj_type_bus,

	// input stream from previous layer
	input in_axis_tvalid,
	output in_axis_tready,
	input [SVO_BITS_PER_PIXEL-1:0] in_axis_tdata,
	input [0:0] in_axis_tuser,

	// output stream to next layer
	output out_axis_tvalid,
	input out_axis_tready,
	output [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output [0:0] out_axis_tuser
);
`SVO_DECLS

localparam PLAYER_SRC_BITS = 5;
localparam PLAYER_SRC_ADDR_WIDTH = 11;         // {frame(1), src_y(5), src_x(5)} -> 2-frame walk sheet

localparam OBJ_ATLAS_ADDR_WIDTH = 11;      // {type(3), src_y(4), src_x(4)}
localparam OBJ_ATLAS_DEPTH = 2048;         // 8 type slots x 256, 7 used
localparam [7:0] TRANSPARENT_VAL = 8'h00;

reg [`SVO_XYBITS-1:0] hcursor;
reg [`SVO_XYBITS-1:0] vcursor;

reg obj_hit_d;
reg hit_player_d;
reg skill_on_d;
reg [SVO_BITS_PER_PIXEL-1:0] bg_rgb_d;
reg [0:0] tuser_d;
reg tvalid_d;

wire fire = in_axis_tvalid && in_axis_tready;
wire [`SVO_XYBITS-1:0] pixel_x = in_axis_tuser[0] ? 0 : hcursor;
wire [`SVO_XYBITS-1:0] pixel_y = in_axis_tuser[0] ? 0 : vcursor;

// Narrowed copies for the per-pixel hit tests. The cursors only ever reach
// 639 x 479, so 11 bits is exact -- and every comparator below gets 3 bits
// cheaper, which matters a lot when they are replicated per object per clone.
wire [10:0] px = pixel_x[10:0];
wire [10:0] py = pixel_y[10:0];

integer obj_i;
reg obj_hit;
reg [OBJ_TYPE_BITS-1:0] obj_type_now;
reg [4:0] obj_local_x;
reg [4:0] obj_local_y;
reg [9:0] scan_obj_x;
reg [9:0] scan_obj_ypos;
reg [9:0] scan_local_x;
reg [9:0] scan_local_y;

function [9:0] obj_x;
	input [LANE_BITS-1:0] lane;
	input [XOFF_BITS-1:0] xoff;
	begin obj_x = `GAME_X0 + ({6'd0, lane} << 5) + {6'd0, xoff}; end
endfunction

always @(*) begin
	obj_hit = 0;
	obj_type_now = 0;
	obj_local_x = 0;
	obj_local_y = 0;
	scan_obj_x = 0;
	scan_obj_ypos = 0;
	scan_local_x = 0;
	scan_local_y = 0;

	for (obj_i = 0; obj_i < MAX_OBJ; obj_i = obj_i + 1) begin
		scan_obj_x = obj_x(
			obj_lane_bus[obj_i*LANE_BITS +: LANE_BITS],
			obj_xoff_bus[obj_i*XOFF_BITS +: XOFF_BITS]
		);
		scan_obj_ypos = obj_ypos_bus[obj_i*OBJ_Y_BITS +: OBJ_Y_BITS];

		// AABB hit test
		if (!obj_hit && obj_valid_bus[obj_i] &&
			px >= scan_obj_x && px < scan_obj_x + `OBJ_W &&
			py >= scan_obj_ypos && py < scan_obj_ypos + `OBJ_H) begin
			scan_local_x = px - scan_obj_x;
			scan_local_y = py - scan_obj_ypos;
			obj_hit = 1;
			obj_type_now = obj_type_bus[obj_i*OBJ_TYPE_BITS +: OBJ_TYPE_BITS];
			obj_local_x = scan_local_x[4:0];
			obj_local_y = scan_local_y[4:0];
		end
	end
end

// 16x16 -> 32x32 scaling by replicating pixels
wire [3:0] obj_src_x = obj_local_x[4:1];
wire [3:0] obj_src_y = obj_local_y[4:1];
// One atlas ROM holds every object sprite; the type picks its 256-entry slot, so
// no output mux is needed -- the registered read is already the selected pixel.
wire [OBJ_ATLAS_ADDR_WIDTH-1:0] obj_atlas_addr = {obj_type_now, obj_src_y, obj_src_x};
wire [7:0] obj_rgb;

// During the clone skill the body is flanked by CLONE_SIDE copies per side,
// butted edge to edge. Every copy is one PLAYER_W-wide cell of a single span
// anchored to player_x, so they all track the body for free.
//
// The span origin goes negative when the body is near the left edge, so the
// arithmetic carries a CLONE_BIAS offset and stays unsigned throughout: a pixel
// left of the span wraps to a large value and simply fails the width test.
localparam CLONE_BIAS = `PLAYER_W * `CLONE_SIDE;   // >= any clone_pad_px

wire [11:0] clone_pad_px = clone_on ? (`PLAYER_W * `CLONE_SIDE) : 12'd0;
wire [11:0] clone_span_l = player_x + CLONE_BIAS - clone_pad_px;
wire [11:0] clone_rel_x = pixel_x + CLONE_BIAS - clone_span_l;
wire [11:0] clone_span_w = clone_on ? `CLONE_SPAN : `PLAYER_W;

wire in_player_band = clone_rel_x < clone_span_w;
wire in_body = in_player_band &&
			   py >= player_y && py < player_y + `PLAYER_H;

// Stage 3 escort clones, each at its own free-flying position. Stage 2 clones
// and stage 3 flyers never overlap in time, so one priority-selected sprite
// source covers both; the body always wins where they overlap.
integer gi;
reg in_fly;
reg [9:0] fly_rel_x;
reg [9:0] fly_rel_y;
reg [9:0] fly_cx;
reg [9:0] fly_cy;

always @(*) begin
	in_fly = 0;
	fly_rel_x = 0;
	fly_rel_y = 0;
	fly_cx = 0;
	fly_cy = 0;

	for (gi = 0; gi < `FLY_CLONES; gi = gi + 1) begin
		fly_cx = fly_x_bus[gi*10 +: 10];
		fly_cy = fly_y_bus[gi*10 +: 10];

		if (!in_fly && fly_active[gi] &&
			px >= fly_cx && px < fly_cx + `PLAYER_W &&
			py >= fly_cy && py < fly_cy + `PLAYER_H) begin
			in_fly = 1;
			fly_rel_x = px - fly_cx;
			fly_rel_y = py - fly_cy;
		end
	end
end

wire hit_player = in_body || in_fly;

// 32x32 -> 64x64 scaling by replicating pixels; clone_rel_x[5:0] is the offset
// inside whichever copy this pixel lands in.
wire [9:0] player_rel_x = in_body ? {4'd0, clone_rel_x[5:0]} : fly_rel_x;
wire [9:0] player_rel_y = in_body ? (py - player_y) : fly_rel_y;
wire [PLAYER_SRC_BITS-1:0] player_src_x = player_rel_x[5:1];
wire [PLAYER_SRC_BITS-1:0] player_src_y = player_rel_y[5:1];
wire [PLAYER_SRC_BITS-1:0] player_addr_x = player_dir ? player_src_x : (5'd31 - player_src_x);
// walk animation: alternate between 2 frames, flipping every 16px of travel
wire player_frame = player_x[6];
wire [PLAYER_SRC_ADDR_WIDTH-1:0] player_addr = {player_frame, player_src_y, player_addr_x};

wire [7:0] player_normal_rgb;
wire [7:0] player_skill_rgb;
wire [7:0] player_rgb = skill_on_d ? player_skill_rgb : player_normal_rgb;

function [23:0] rgb323_to_bgr888;
	input [7:0] c;                 // [7:5]=R3 [4:3]=G2 [2:0]=B3
	reg [7:0] r;
	reg [7:0] g;
	reg [7:0] b;
	begin
		r = {c[7:5], c[7:5], c[7:6]};
		g = {c[4:3], c[4:3], c[4:3], c[4:3]};
		b = {c[2:0], c[2:0], c[2:1]};
		rgb323_to_bgr888 = {b, g, r};
	end
endfunction

// If there is an object then just show it, otherwise show the background pixel
wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_obj =
	obj_hit_d && obj_rgb != TRANSPARENT_VAL ?
	rgb323_to_bgr888(obj_rgb) : bg_rgb_d;

// If the player sprite is hit then show it, otherwise show whatever comes from obj layer
wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_player =
	hit_player_d && player_rgb != 8'h00 ?
	rgb323_to_bgr888(player_rgb) : pxl_after_obj;

assign in_axis_tready  = out_axis_tready;
assign out_axis_tvalid = tvalid_d;
assign out_axis_tdata  = pxl_after_player;
assign out_axis_tuser  = tuser_d;

always @(posedge clk) begin
	if (!resetn) begin
		obj_hit_d <= 0;
		hit_player_d <= 0;
		skill_on_d <= 0;
		bg_rgb_d <= 0;
		tuser_d <= 0;
		tvalid_d <= 0;
	end else if (out_axis_tready) begin
		tvalid_d <= in_axis_tvalid;
		if (fire) begin
			obj_hit_d <= obj_hit;
			hit_player_d <= hit_player;
			skill_on_d <= skill_on;
			bg_rgb_d <= in_axis_tdata;
			tuser_d <= in_axis_tuser;
		end
	end
end

always @(posedge clk) begin
	if (!resetn) begin
		hcursor <= 0;
		vcursor <= 0;
	end else if (fire) begin
		if (in_axis_tuser[0]) begin
			hcursor <= 1;
			vcursor <= 0;
		end else if (hcursor == SVO_HOR_PIXELS - 1) begin
			hcursor <= 0;
			if (vcursor == SVO_VER_PIXELS - 1)
				vcursor <= 0;
			else
				vcursor <= vcursor + 1;
		end else begin
			hcursor <= hcursor + 1;
		end
	end
end

// Single object atlas ROM (RGB323): 8 type slots x 256 entries, addressed by
// {type, src_y, src_x}. Only slots 0-6 are populated by obj_atlas.mem.
rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(OBJ_ATLAS_ADDR_WIDTH),
	.DEPTH(OBJ_ATLAS_DEPTH),
	.INIT_FILE("src/assets/obj_atlas.mem")
) u_obj_atlas_rom (
	.clk(clk),
	.addr(obj_atlas_addr),
	.data(obj_rgb)
);

rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(PLAYER_SRC_ADDR_WIDTH),
	.DEPTH(2048),
	.INIT_FILE("src/assets/player_right_32.mem")
) u_player_right_rom (
	.clk(clk),
	.addr(player_addr),
	.data(player_normal_rgb)
);

rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(PLAYER_SRC_ADDR_WIDTH),
	.DEPTH(2048),
	.INIT_FILE("src/assets/player_skill_32.mem")
) u_player_skill_rom (
	.clk(clk),
	.addr(player_addr),
	.data(player_skill_rgb)
);

endmodule
