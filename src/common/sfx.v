`timescale 1ns / 1ps

// One-voice square wave sound effects.
//
// The board has no audio codec and the HDMI path here is video only, so sound
// leaves the FPGA as a single toggling pin meant to drive a passive buzzer.
// A new sfx_id retriggers immediately, so the newest action always wins.
module sfx #(
	// Pixel clock divided by 2^PRESCALE_BITS feeds the tone counter, which keeps
	// the divider values (and therefore the comparator) 10 bits wide.
	parameter PRESCALE_BITS = 6
)(
	input clk,
	input resetn,
	input frame_tick,
	input [2:0] sfx_id,
	output snd
);
localparam SFX_NONE  = 3'd0;
localparam SFX_CATCH = 3'd1;
localparam SFX_JUMP  = 3'd2;
localparam SFX_CLONE = 3'd3;
localparam SFX_SKILL = 3'd4;
localparam SFX_STAGE = 3'd5;
localparam SFX_OVER  = 3'd6;

// Half-period counts at 25.175MHz / 64 = 393kHz.
// Duration is counted in frames, so it is already tied to the 60Hz game tick.
reg [9:0] tone_div;
reg [7:0] tone_dur;

always @(*) begin
	case (sfx_id)
		SFX_CATCH: begin tone_div = 10'd111; tone_dur = 8'd3;  end   // 1760Hz blip
		SFX_JUMP:  begin tone_div = 10'd223; tone_dur = 8'd6;  end   //  880Hz
		SFX_CLONE: begin tone_div = 10'd298; tone_dur = 8'd10; end   //  660Hz
		SFX_SKILL: begin tone_div = 10'd894; tone_dur = 8'd18; end   //  220Hz boom
		SFX_STAGE: begin tone_div = 10'd149; tone_dur = 8'd24; end   // 1320Hz chime
		SFX_OVER:  begin tone_div = 10'd596; tone_dur = 8'd45; end   //  330Hz fall
		default:   begin tone_div = 10'd447; tone_dur = 8'd0;  end
	endcase
end

reg [PRESCALE_BITS-1:0] pre;
reg [9:0] div;
reg [9:0] cnt;
reg [7:0] dur;
reg sq;

always @(posedge clk) begin
	if (!resetn) begin
		pre <= 0;
		div <= 0;
		cnt <= 0;
		dur <= 0;
		sq <= 0;
	end else if (sfx_id != SFX_NONE) begin
		div <= tone_div;
		dur <= tone_dur;
		cnt <= 0;
		pre <= 0;
	end else if (dur != 0) begin
		if (frame_tick)
			dur <= dur - 1'b1;

		pre <= pre + 1'b1;
		if (&pre) begin
			if (cnt >= div) begin
				cnt <= 0;
				sq <= ~sq;
			end else begin
				cnt <= cnt + 1'b1;
			end
		end
	end else begin
		sq <= 0;
	end
end

assign snd = sq;

endmodule
