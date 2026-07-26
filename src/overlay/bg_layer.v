`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

module bg_layer #(
	`SVO_DEFAULT_PARAMS,
	parameter BG_IMG_W = 40,
	parameter BG_IMG_H = 25,
	parameter BG_SLOT_DEPTH = 1024,              // entries reserved per stage slot
	parameter BG_STAGE_COUNT = 3,
	parameter BG_Y0 = 16,                        // top of the image band
	parameter BG_TILE_FILE = "src/assets/background.mem"
) (
	input clk,
	input resetn,
	input [1:0] stage,

	output reg out_axis_tvalid,
	input out_axis_tready,
	output reg [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output reg [0:0] out_axis_tuser
);
`SVO_DECLS

// One ROM holds every stage background as a fixed-size slot, so a stage switch
// is just a base-address change -- no extra block RAM per stage.
localparam BG_DEPTH = BG_SLOT_DEPTH * BG_STAGE_COUNT;
localparam BG_ADDR_WIDTH = 12;
localparam BG_Y1 = BG_Y0 + BG_IMG_H * 16;        // band bottom (exclusive) = 16 + 400 = 416
localparam [23:0] BG_MARGIN_RGB = 24'h181818;    // dark gray outside the band (matches UI)

reg [`SVO_XYBITS-1:0] hcursor, vcursor;
reg pipe_valid;
reg pipe_tuser;
reg pipe_in_band;

// One 40x25 image per stage shown 16x (pixel replication) in the band
// Y in [BG_Y0, BG_Y1), X in [0, 640). Address = slot base + src_y*40 + src_x.
wire in_band = (vcursor >= BG_Y0) && (vcursor < BG_Y1);
wire [5:0] bg_src_x = hcursor[9:4];              // hcursor / 16 -> 0..39
wire [`SVO_XYBITS-1:0] bg_rel_y = vcursor - BG_Y0;
wire [4:0] bg_src_y = bg_rel_y[8:4];             // (vcursor - 16) / 16 -> 0..24
wire [BG_ADDR_WIDTH-1:0] bg_slot_base = stage * BG_SLOT_DEPTH;
wire [BG_ADDR_WIDTH-1:0] bg_addr = bg_slot_base + bg_src_y * BG_IMG_W + bg_src_x;
wire [15:0] bg_rgb565;

function [23:0] rgb565_to_bgr888;
	input [15:0] rgb565;
	reg [7:0] r;
	reg [7:0] g;
	reg [7:0] b;
	begin
		r = {rgb565[15:11], rgb565[15:13]};
		g = {rgb565[10: 5], rgb565[10: 9]};
		b = {rgb565[ 4: 0], rgb565[ 4: 2]};
		rgb565_to_bgr888 = {b, g, r};
	end
endfunction

always @(posedge clk) begin
	if (!resetn) begin
		hcursor <= 0;
		vcursor <= 0;
		pipe_valid <= 0;
		pipe_tuser <= 0;
		pipe_in_band <= 0;
		out_axis_tvalid <= 0;
		out_axis_tdata <= 0;
		out_axis_tuser <= 0;
	end else if (!out_axis_tvalid || out_axis_tready) begin
		out_axis_tvalid   <= pipe_valid;
		out_axis_tdata    <= pipe_in_band ? rgb565_to_bgr888(bg_rgb565) : BG_MARGIN_RGB;
		out_axis_tuser[0] <= pipe_tuser;

		pipe_valid <= 1;
		pipe_tuser <= hcursor == 0 && vcursor == 0;
		pipe_in_band <= in_band;

		if (hcursor == SVO_HOR_PIXELS - 1) begin
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

rom #(
	.DATA_WIDTH(16),
	.ADDR_WIDTH(BG_ADDR_WIDTH),
	.DEPTH(BG_DEPTH),
	.INIT_FILE(BG_TILE_FILE)
) u_bg_rom (
	.clk(clk),
	.addr(bg_addr),
	.data(bg_rgb565)
);

endmodule
