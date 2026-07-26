`timescale 1ns / 1ps

module spawn_postprocess #(
	parameter LANE_BITS = 4,
	parameter XOFF_BITS = 4,
	parameter OBJ_TYPE_BITS = 3
)(
	input clk,
	input resetn,
	input fire,
	input skill_on,
	input [1:0] stage,

	input [LANE_BITS-1:0] raw_lane,
	input [XOFF_BITS-1:0] raw_xoff,
	input [OBJ_TYPE_BITS-1:0] raw_type,

	output [LANE_BITS-1:0] out_lane,
	output [XOFF_BITS-1:0] out_xoff,
	output reg [OBJ_TYPE_BITS-1:0] out_type
);
// Base branch is pass-through; skill branches can remap type or position here.
localparam TYPE_COIN_1 = 0;
localparam TYPE_COIN_3 = 1;
localparam TYPE_COIN_5 = 2;
localparam TYPE_MINUS_TIME = 7;

assign out_lane = raw_lane;
assign out_xoff = raw_xoff;

always @(*) begin
	out_type = raw_type;
	// Stage 1 has no time-draining drop; fold it back into a plain coin.
	if (stage == 0 && raw_type == TYPE_MINUS_TIME)
		out_type = TYPE_COIN_1;
	// Skill window turns the whole field into bonus coins.
	if (skill_on) begin
		case (raw_xoff[1:0])
			0: out_type = TYPE_COIN_1;
			1: out_type = TYPE_COIN_3;
			default: out_type = TYPE_COIN_5;
		endcase
	end
end

endmodule
