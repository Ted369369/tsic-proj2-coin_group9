`timescale 1ns / 1ps
`include "game/game_defs.vh"

module game_ctrl #(
	parameter MAX_OBJ = 16,
	parameter LANE_BITS = 4,
	parameter XOFF_BITS = 4,
	parameter OBJ_TYPE_BITS = 3,
	parameter OBJ_Y_BITS = 10,
	parameter FALL_SPEED = 2,
	parameter SPAWN_PERIOD_FRAMES = 24,
	parameter PLAYER_HIT_TOP_PAD = 16,
	parameter PLAYER_START_X = 288,
	parameter PLAYER_SPEED_START = 8,
	parameter TIMER_START = 30,
	parameter TIME_BONUS = 3,
	parameter FPS = 60,
	parameter SKILL_CHARGE_MAX = `SKILL_CHARGE_MAX,
	parameter SKILL_ENABLE = 0,
	parameter SKILL_DURATION = 0,
	parameter TIME_PENALTY = 3,
	parameter STAGE_COUNT = 3
)(
	input clk,
	input resetn,
	input frame_tick,

	input btn_left,
	input btn_right,
	input btn_start,
	input btn_skill,

	output reg [9:0] player_x,
	output reg player_dir,
	output reg [9:0] player_y,

	output reg [MAX_OBJ              -1:0] obj_valid_bus,
	output reg [MAX_OBJ*LANE_BITS    -1:0] obj_lane_bus,
	output reg [MAX_OBJ*XOFF_BITS    -1:0] obj_xoff_bus,
	output reg [MAX_OBJ*OBJ_Y_BITS   -1:0] obj_ypos_bus,
	output reg [MAX_OBJ*OBJ_TYPE_BITS-1:0] obj_type_bus,

	output reg [7:0] timer,
	output reg [9:0] score,
	output [11:0] timer_bcd,
	output [11:0] score_bcd,
	output reg [11:0] high_score_bcd,
	output reg [2:0] skill_charge,
	output [7:0] skill_timer,
	output skill_on,
	output reg [1:0] stage,
	output clone_on,
	output reg [`FLY_CLONES*10-1:0] fly_x_bus,
	output reg [`FLY_CLONES*10-1:0] fly_y_bus,
	output reg [`FLY_CLONES-1:0] fly_active,
	output reg [2:0] sfx_id,
	output game_over
);
localparam S_PLAY = 1;
localparam S_OVER = 2;

localparam TYPE_COIN_1 = 0;
localparam TYPE_COIN_3 = 1;
localparam TYPE_COIN_5 = 2;
localparam TYPE_MINUS3 = 3;
localparam TYPE_MINUS5 = 4;
localparam TYPE_TIME = 5;
localparam TYPE_CHARGE = 6;
localparam TYPE_MINUS_TIME = 7;

localparam FALL_SPEED_BOOST = 4;
localparam TIME_SKILL_BONUS = 10;
localparam SPAWN_JITTER_BITS = 4;

localparam JUMP_VELOCITY = 12;
localparam GRAVITY = 1;
localparam MAX_JUMP_COUNT = 2;

// Stage 3 skill: hold for CRAZY_DELAY, then fly uncontrolled for CRAZY_RUN.
// Speed is re-rolled every other frame so the path covers every direction
// instead of settling into a fixed diagonal bounce.
localparam CRAZY_DELAY = 1 * FPS;
localparam CRAZY_RUN = 6 * FPS;
localparam CRAZY_SPEED_MIN = 48;
localparam GROUND_CLONE_SPEED = 6;
localparam C_IDLE = 0;
localparam C_WIND = 1;
localparam C_FLY = 2;

localparam [9:0] SCREEN_W = 640;
localparam [9:0] OBJ_GROUND_Y = `UI_TOP - `OBJ_H;
localparam [9:0] PLAYER_MAX_X = SCREEN_W - `PLAYER_W;

reg [LANE_BITS    -1:0] obj_lane [0:MAX_OBJ-1];
reg [XOFF_BITS    -1:0] obj_xoff [0:MAX_OBJ-1];
reg [OBJ_TYPE_BITS-1:0] obj_type [0:MAX_OBJ-1];
reg [OBJ_Y_BITS   -1:0] obj_ypos [0:MAX_OBJ-1];
reg [4:0] obj_count;
reg [1:0] state;

reg [7:0] frame_cnt;
reg [7:0] spawn_cnt;
reg btn_start_q;
reg btn_skill_q;
reg signed [10:0] player_vy;
reg [1:0] jump_count;
reg [1:0] crazy_state;
reg [8:0] crazy_cnt;
reg signed [7:0] crazy_vx;
reg signed [7:0] crazy_vy;

// Stage 3 flight escorts: visual-only clones, each on its own random heading.
// The body is the sixth flyer and still owns the catch box.
reg [9:0] fly_x [0:`FLY_CLONES-1];
reg [9:0] fly_y [0:`FLY_CLONES-1];
reg signed [7:0] fly_vx [0:`FLY_CLONES-1];
reg signed [7:0] fly_vy [0:`FLY_CLONES-1];

wire btn_start_rise = btn_start && !btn_start_q;
wire btn_skill_rise = btn_skill && !btn_skill_q && state == S_PLAY;
wire skill_start;
wire skill_btn_active = btn_skill && state == S_PLAY;
wire crazy_active = crazy_state == C_FLY;
wire can_left = player_x > PLAYER_SPEED_START;
wire can_right = player_x + PLAYER_SPEED_START < PLAYER_MAX_X;
wire signed [11:0] player_y_next = $signed({2'b0, player_y}) + player_vy;
wire signed [11:0] crazy_x_next = $signed({2'b0, player_x}) + crazy_vx;
wire signed [11:0] crazy_y_next = $signed({2'b0, player_y}) + crazy_vy;

// A third skill press while airborne (both jumps spent) drops two runners at
// ground level that walk out to the screen edges. They reuse the stage 3 flight
// slots: the flight takes away player control, so the two can never coexist.
wire airborne = player_y < `PLAYER_Y;
wire ground_clone_fire = btn_skill_rise && jump_count == MAX_JUMP_COUNT &&
						 airborne && !crazy_active;
wire jump_fire = btn_skill_rise && jump_count < MAX_JUMP_COUNT && !crazy_active;

// Free-running noise, so the flight can re-roll direction every frame rather
// than only when a spawn happens to advance the spawn LFSR. Two streams keep
// each clone's X and Y headings independent.
wire [31:0] crazy_rnd;
wire [31:0] crazy_rnd2;

lfsr32 #(
	.SEED(32'h1357_9BDF)
) u_crazy_lfsr (
	.clk(clk),
	.resetn(resetn),
	.en(1'b1),
	.rnd(crazy_rnd)
);

lfsr32 #(
	.SEED(32'h2468_ACE0)
) u_crazy_lfsr2 (
	.clk(clk),
	.resetn(resetn),
	.en(1'b1),
	.rnd(crazy_rnd2)
);

wire [6:0] crazy_mag_x = CRAZY_SPEED_MIN + {2'd0, crazy_rnd[4:0]};
wire [6:0] crazy_mag_y = CRAZY_SPEED_MIN + {2'd0, crazy_rnd[12:8]};
wire signed [7:0] crazy_new_vx =
	crazy_rnd[5] ? $signed({1'b0, crazy_mag_x}) : -$signed({1'b0, crazy_mag_x});
wire signed [7:0] crazy_new_vy =
	crazy_rnd[13] ? $signed({1'b0, crazy_mag_y}) : -$signed({1'b0, crazy_mag_y});

// Field pressure ramps per stage: more objects allowed on screen at once, a
// tighter spawn interval, and a faster fall.
wire [4:0] obj_cap = (stage == 0) ? 5'd3 : (stage == 1) ? 5'd5 : 5'd7;
wire [7:0] spawn_period_base = (stage == 0) ? 8'd24 : (stage == 1) ? 8'd14 : 8'd8;
wire [9:0] fall_base = FALL_SPEED + {8'd0, stage};
wire [9:0] fall_speed_eff = skill_on ? fall_base + 10'd2 : fall_base;

// Clones ride along with the body during the stage 2 skill, so they widen the
// catch box by CLONE_SIDE player widths on each side.
assign clone_on = SKILL_ENABLE && skill_on && stage == 1;

wire [10:0] spawn_data;
wire spawn_fifo_empty;
wire obj_has_room = obj_count < obj_cap;
wire remove_valid;
wire spawn_pop = frame_tick && state == S_PLAY &&
				  spawn_cnt == 0 && !spawn_fifo_empty &&
				  (obj_has_room || remove_valid);

wire [31:0] spawn_jitter_rnd;

lfsr32 #(
	.SEED(32'hCAFE_BABE)
) u_spawn_jitter_lfsr (
	.clk(clk),
	.resetn(resetn),
	.en(spawn_pop),
	.rnd(spawn_jitter_rnd)
);

// Skill-window spawn rate ramps up per stage: stage 1 every 2-5 frames,
// stage 2 every 1-2, stage 3 every frame.
wire [7:0] harvest_period =
	(stage == 0) ? 8'd2 + {6'd0, spawn_jitter_rnd[1:0]} :
	(stage == 1) ? 8'd1 + {7'd0, spawn_jitter_rnd[0]}   : 8'd1;

wire [7:0] spawn_period_eff = skill_on ? harvest_period :
	spawn_period_base + {4'd0, spawn_jitter_rnd[SPAWN_JITTER_BITS-1:0]};

wire game_step = frame_tick && state == S_PLAY;
wire timer_tick = frame_cnt == FPS - 1;
wire sec_tick = game_step && timer_tick;

assign game_over = state == S_OVER;

skill_slot #(
	.ENABLE(SKILL_ENABLE),
	.DURATION(SKILL_DURATION),
	.CHARGE_MAX(SKILL_CHARGE_MAX)
) u_skill_slot (
	.clk(clk),
	.resetn(resetn),
	.sec_tick(sec_tick),
	.restart(btn_start_rise),
	.btn_skill(skill_btn_active),
	.skill_charge(skill_charge),
	.skill_timer(skill_timer),
	.skill_on(skill_on),
	.skill_start(skill_start)
);

spawn_queue u_spawn_queue (
	.clk(clk),
	.resetn(resetn),
	.enable(state == S_PLAY),
	.pop(spawn_pop),
	.spawn_data(spawn_data),
	.empty(spawn_fifo_empty)
);

wire [LANE_BITS-1:0] spawn_lane_raw = spawn_data[10:7];
wire [XOFF_BITS-1:0] spawn_xoff_raw = spawn_data[6:3];
wire [OBJ_TYPE_BITS-1:0] spawn_type_raw = spawn_data[2:0];
wire [LANE_BITS-1:0] spawn_lane;
wire [XOFF_BITS-1:0] spawn_xoff;
wire [OBJ_TYPE_BITS-1:0] spawn_type;

spawn_postprocess #(
	.LANE_BITS(LANE_BITS),
	.XOFF_BITS(XOFF_BITS),
	.OBJ_TYPE_BITS(OBJ_TYPE_BITS)
) u_spawn_postprocess (
	.clk(clk),
	.resetn(resetn),
	.fire(spawn_pop),
	.skill_on(skill_on),
	.stage(stage),
	.raw_lane(spawn_lane_raw),
	.raw_xoff(spawn_xoff_raw),
	.raw_type(spawn_type_raw),
	.out_lane(spawn_lane),
	.out_xoff(spawn_xoff),
	.out_type(spawn_type)
);

integer hit_i;
reg hit_valid;
reg [4:0] hit_idx;
reg [9:0] hit_obj_x;
wire [10:0] clone_pad = clone_on ? (`PLAYER_W * `CLONE_SIDE) : 11'd0;
wire [10:0] hit_player_l = player_x > clone_pad ? player_x - clone_pad : 11'd0;
wire [10:0] hit_player_r = player_x + `PLAYER_W + clone_pad;
wire [10:0] hit_player_t = player_y + PLAYER_HIT_TOP_PAD;
wire [10:0] hit_player_b = player_y + `PLAYER_H;

function [9:0] obj_x;
	input [LANE_BITS-1:0] lane;
	input [XOFF_BITS-1:0] xoff;
	begin obj_x = `GAME_X0 + ({6'd0, lane} << 5) + {6'd0, xoff}; end
endfunction

always @(*) begin
	hit_valid = 0;
	hit_idx = 0;
	hit_obj_x = 0;

	for (hit_i = 0; hit_i < MAX_OBJ; hit_i = hit_i + 1) begin
		hit_obj_x = obj_x(obj_lane[hit_i], obj_xoff[hit_i]);
		if (!hit_valid && hit_i < obj_count &&
			hit_player_l < hit_obj_x + `OBJ_W &&
			hit_player_r > hit_obj_x &&
			hit_player_t < obj_ypos[hit_i] + `OBJ_H &&
			hit_player_b > obj_ypos[hit_i]) begin
			hit_valid = 1;
			hit_idx = hit_i[4:0];
		end
	end
end

wire ground_valid = (obj_count != 0) && (obj_ypos[0] >= OBJ_GROUND_Y);
assign remove_valid = hit_valid || ground_valid;
wire [4:0] remove_idx = hit_valid ? hit_idx : 0;

// Ground runners stand on the floor, so anything reaching the floor inside
// their span is theirs. Object 0 is always the lowest, which is exactly the
// one the ground check already retires -- no extra per-object test needed.
wire [9:0] ground_obj_x = obj_x(obj_lane[0], obj_xoff[0]);
wire ground_clone_hit =
	(fly_active[0] && fly_x[0] < ground_obj_x + `OBJ_W &&
					  fly_x[0] + `PLAYER_W > ground_obj_x) ||
	(fly_active[1] && fly_x[1] < ground_obj_x + `OBJ_W &&
					  fly_x[1] + `PLAYER_W > ground_obj_x);
wire clone_catch = ground_valid && !hit_valid && ground_clone_hit && !crazy_active;

wire catch_valid = hit_valid || clone_catch;
wire [4:0] catch_idx = hit_valid ? hit_idx : 5'd0;

reg [9:0] next_score;
reg [7:0] next_timer;
reg [2:0] next_charge;
reg signed [5:0] score_delta;
reg signed [6:0] score_delta_eff;
reg signed [10:0] score_sum;
wire [9:0] final_score = catch_valid ? next_score : score;
always @(*) begin
	next_score = score;
	next_timer = timer;
	next_charge = skill_charge;
	score_delta = 0;
	score_delta_eff = 0;
	score_sum = score;

	if (catch_valid) begin
		case (obj_type[catch_idx])
			TYPE_COIN_1: score_delta = 1;
			TYPE_COIN_3: score_delta = 3;
			TYPE_COIN_5: score_delta = 5;
			TYPE_MINUS3: score_delta = -3;
			TYPE_MINUS5: score_delta = -5;
			TYPE_TIME: next_timer = timer + TIME_BONUS;
			TYPE_MINUS_TIME:
				next_timer = timer > TIME_PENALTY ? timer - TIME_PENALTY : 8'd0;
			TYPE_CHARGE:
				if (skill_charge < SKILL_CHARGE_MAX)
					next_charge = skill_charge + 1;
			default: begin
				next_timer = timer;
				next_charge = skill_charge;
			end
		endcase

		score_delta_eff = score_delta;
		score_sum = $signed({1'b0, score}) + score_delta_eff;
		if (score_sum < 0)
			next_score = 0;
		else
			next_score = score_sum[9:0];
	end
end

wire game_ending = sec_tick && next_timer <= 1 && stage == STAGE_COUNT - 1;
wire stage_up_fire = sec_tick && next_timer <= 1 && stage < STAGE_COUNT - 1;
wire catch_fire = game_step && catch_valid;

// Sound triggers, most dramatic event wins when several land on one frame.
always @(posedge clk) begin
	if (!resetn) begin
		sfx_id <= 3'd0;
	end else if (game_ending) begin
		sfx_id <= 3'd6;
	end else if (stage_up_fire) begin
		sfx_id <= 3'd5;
	end else if (SKILL_ENABLE && skill_start) begin
		sfx_id <= 3'd4;
	end else if (ground_clone_fire) begin
		sfx_id <= 3'd3;
	end else if (jump_fire) begin
		sfx_id <= 3'd2;
	end else if (catch_fire) begin
		sfx_id <= 3'd1;
	end else begin
		sfx_id <= 3'd0;
	end
end
wire new_high_score = score_bcd > high_score_bcd;

wire high_score_will_update = game_ending && new_high_score;

bin2bcd #(
	.BIN_BITS(10)
) u_score_bcd (
	.bin(final_score),
	.bcd(score_bcd)
);

bin2bcd #(
	.BIN_BITS(8)
) u_timer_bcd (
	.bin(timer),
	.bcd(timer_bcd)
);

integer fly_pack_i;

always @(*) begin
	fly_x_bus = 0;
	fly_y_bus = 0;

	for (fly_pack_i = 0; fly_pack_i < `FLY_CLONES; fly_pack_i = fly_pack_i + 1) begin
		fly_x_bus[fly_pack_i*10 +: 10] = fly_x[fly_pack_i];
		fly_y_bus[fly_pack_i*10 +: 10] = fly_y[fly_pack_i];
	end
end

integer pack_i;

always @(*) begin
	obj_valid_bus = 0;
	obj_lane_bus = 0;
	obj_xoff_bus = 0;
	obj_ypos_bus = 0;
	obj_type_bus = 0;

	for (pack_i = 0; pack_i < MAX_OBJ; pack_i = pack_i + 1) begin
		if (pack_i < obj_count) begin
			obj_valid_bus[pack_i] = 1;
			obj_lane_bus[pack_i*LANE_BITS     +: LANE_BITS]     = obj_lane[pack_i];
			obj_xoff_bus[pack_i*XOFF_BITS     +: XOFF_BITS]     = obj_xoff[pack_i];
			obj_ypos_bus[pack_i*OBJ_Y_BITS    +: OBJ_Y_BITS]    = obj_ypos[pack_i];
			obj_type_bus[pack_i*OBJ_TYPE_BITS +: OBJ_TYPE_BITS] = obj_type[pack_i];
		end
	end
end

integer i;
integer fi;
reg [6:0] fly_mag_x;
reg [6:0] fly_mag_y;
reg signed [11:0] fly_nx;
reg signed [11:0] fly_ny;

always @(posedge clk) begin
	if (!resetn) begin
		player_x <= PLAYER_START_X;
		player_dir <= 1;
		player_y <= `PLAYER_Y;
		player_vy <= 0;
		jump_count <= 0;
		crazy_state <= C_IDLE;
		crazy_cnt <= 0;
		crazy_vx <= 0;
		crazy_vy <= 0;
		fly_active <= 0;
		stage <= 0;
		obj_count <= 0;
		timer <= TIMER_START;
		score <= 0;
		high_score_bcd <= 12'h000;
		skill_charge <= 0;
		state <= S_PLAY;
		frame_cnt <= 0;
		spawn_cnt <= SPAWN_PERIOD_FRAMES;
		btn_start_q <= 0;
		btn_skill_q <= 0;

		for (i = 0; i < MAX_OBJ; i = i + 1) begin
			obj_lane[i] <= 0;
			obj_xoff[i] <= 0;
			obj_ypos[i] <= 0;
			obj_type[i] <= 0;
		end

		for (fi = 0; fi < `FLY_CLONES; fi = fi + 1) begin
			fly_x[fi] <= PLAYER_START_X;
			fly_y[fi] <= `PLAYER_Y;
			fly_vx[fi] <= 0;
			fly_vy[fi] <= 0;
		end
	end else begin
		btn_start_q <= btn_start;
		btn_skill_q <= btn_skill;

		if (btn_start_rise) begin
			player_x <= PLAYER_START_X;
			player_dir <= 1;
			player_y <= `PLAYER_Y;
			player_vy <= 0;
			jump_count <= 0;
			crazy_state <= C_IDLE;
			crazy_cnt <= 0;
			crazy_vx <= 0;
			crazy_vy <= 0;
			fly_active <= 0;
			stage <= 0;
			obj_count <= 0;
			timer <= TIMER_START;
			score <= 0;
			skill_charge <= 0;
			state <= S_PLAY;
			frame_cnt <= 0;
			spawn_cnt <= SPAWN_PERIOD_FRAMES;

			for (i = 0; i < MAX_OBJ; i = i + 1) begin
				obj_lane[i] <= 0;
				obj_xoff[i] <= 0;
				obj_ypos[i] <= 0;
				obj_type[i] <= 0;
			end
		end else begin
			if (frame_tick && state == S_PLAY) begin

				// Direction control (suspended while the stage 3 flight has the wheel)
				if (!crazy_active) begin
					if (btn_left && !btn_right) begin
						if (can_left)
							player_x <= player_x - PLAYER_SPEED_START;
						else
							player_x <= 0;
						player_dir <= 0;
					end else if (btn_right && !btn_left) begin
						if (can_right)
							player_x <= player_x + PLAYER_SPEED_START;
						else
							player_x <= PLAYER_MAX_X;
						player_dir <= 1;
					end
				end

				if (crazy_active) begin
					// Escort clones: each re-rolls its own heading and bounces
					// off the play band independently of the body.
					for (fi = 0; fi < `FLY_CLONES; fi = fi + 1) begin
						fly_mag_x = CRAZY_SPEED_MIN + {2'd0, crazy_rnd[fi*5 +: 5]};
						fly_mag_y = CRAZY_SPEED_MIN + {2'd0, crazy_rnd2[fi*5 +: 5]};

						if (!crazy_cnt[0]) begin
							fly_vx[fi] <= crazy_rnd[31-fi] ?
								$signed({1'b0, fly_mag_x}) : -$signed({1'b0, fly_mag_x});
							fly_vy[fi] <= crazy_rnd2[31-fi] ?
								$signed({1'b0, fly_mag_y}) : -$signed({1'b0, fly_mag_y});
						end

						fly_nx = $signed({2'b0, fly_x[fi]}) + fly_vx[fi];
						fly_ny = $signed({2'b0, fly_y[fi]}) + fly_vy[fi];

						if (fly_nx < 0) begin
							fly_x[fi] <= 0;
							fly_vx[fi] <= -fly_vx[fi];
						end else if (fly_nx > $signed({2'b0, PLAYER_MAX_X})) begin
							fly_x[fi] <= PLAYER_MAX_X;
							fly_vx[fi] <= -fly_vx[fi];
						end else begin
							fly_x[fi] <= fly_nx[9:0];
						end

						if (fly_ny < $signed({2'b0, `PLAY_TOP})) begin
							fly_y[fi] <= `PLAY_TOP;
							fly_vy[fi] <= -fly_vy[fi];
						end else if (fly_ny > $signed({2'b0, `PLAYER_Y})) begin
							fly_y[fi] <= `PLAYER_Y;
							fly_vy[fi] <= -fly_vy[fi];
						end else begin
							fly_y[fi] <= fly_ny[9:0];
						end
					end

					// Re-roll heading every other frame for all-direction motion.
					// (flight owns every slot; ground runners are cleared below)
					// A wall bounce below overrides this in the frame it happens.
					if (!crazy_cnt[0]) begin
						crazy_vx <= crazy_new_vx;
						crazy_vy <= crazy_new_vy;
					end

					// Stage 3 flight: ricochet around the whole play band, ignoring input
					if (crazy_x_next < 0) begin
						player_x <= 0;
						crazy_vx <= -crazy_vx;
					end else if (crazy_x_next > $signed({2'b0, PLAYER_MAX_X})) begin
						player_x <= PLAYER_MAX_X;
						crazy_vx <= -crazy_vx;
					end else begin
						player_x <= crazy_x_next[9:0];
					end

					if (crazy_y_next < $signed({2'b0, `PLAY_TOP})) begin
						player_y <= `PLAY_TOP;
						crazy_vy <= -crazy_vy;
					end else if (crazy_y_next > $signed({2'b0, `PLAYER_Y})) begin
						player_y <= `PLAYER_Y;
						crazy_vy <= -crazy_vy;
					end else begin
						player_y <= crazy_y_next[9:0];
					end

					player_dir <= crazy_vx > 0;
					player_vy <= 0;
					jump_count <= 0;
				end else begin
					// Ground runners: walk outward, vanish at the screen edge
					if (fly_active[0]) begin
						if (fly_x[0] <= GROUND_CLONE_SPEED)
							fly_active[0] <= 1'b0;
						else
							fly_x[0] <= fly_x[0] - GROUND_CLONE_SPEED;
					end

					if (fly_active[1]) begin
						if (fly_x[1] + GROUND_CLONE_SPEED >= PLAYER_MAX_X)
							fly_active[1] <= 1'b0;
						else
							fly_x[1] <= fly_x[1] + GROUND_CLONE_SPEED;
					end

					// Jump physics: gravity integration with ground clamp
					if (player_y_next >= $signed({2'b0, `PLAYER_Y})) begin
						player_y <= `PLAYER_Y;
						player_vy <= 0;
						jump_count <= 0;
					end else if (player_y_next <= 0) begin
						player_y <= 0;
						player_vy <= player_vy + GRAVITY;
					end else begin
						player_y <= player_y_next[9:0];
						player_vy <= player_vy + GRAVITY;
					end
				end

				// Stage 3 skill timeline: wind-up, then uncontrolled flight
				if (crazy_state == C_WIND) begin
					if (crazy_cnt == CRAZY_DELAY - 1) begin
						crazy_state <= C_FLY;
						crazy_cnt <= 0;
						crazy_vx <= crazy_new_vx;
						crazy_vy <= crazy_new_vy;

						// Clones burst out of the body, then scatter on their own.
						// These are solid bodies, not afterimages.
						fly_active <= {`FLY_CLONES{1'b1}};
						for (fi = 0; fi < `FLY_CLONES; fi = fi + 1) begin
							fly_x[fi] <= player_x;
							fly_y[fi] <= player_y;
						end
					end else begin
						crazy_cnt <= crazy_cnt + 1;
					end
				end else if (crazy_state == C_FLY) begin
					if (crazy_cnt == CRAZY_RUN - 1) begin
						crazy_state <= C_IDLE;
						crazy_cnt <= 0;
						fly_active <= 0;
					end else begin
						crazy_cnt <= crazy_cnt + 1;
					end
				end

				// Hit effect update (body catch or ground runner catch)
				if (catch_valid) begin
					score <= next_score;
					timer <= next_timer;
					skill_charge <= next_charge;
				end

				// Object falling and spawning
				if (remove_valid) begin
					for (i = 0; i < MAX_OBJ-1; i = i + 1) begin
						if (i < obj_count - 1) begin
							if (i < remove_idx) begin
								obj_ypos[i] <= obj_ypos[i] + fall_speed_eff;
							end else begin
								obj_lane[i] <= obj_lane[i+1];
								obj_xoff[i] <= obj_xoff[i+1];
								obj_type[i] <= obj_type[i+1];
								obj_ypos[i] <= obj_ypos[i+1] + fall_speed_eff;
							end
						end
					end

					if (spawn_pop) begin
						obj_lane[obj_count - 1] <= spawn_lane;
						obj_xoff[obj_count - 1] <= spawn_xoff;
						obj_type[obj_count - 1] <= spawn_type;
						obj_ypos[obj_count - 1] <= 0;
						obj_count <= obj_count;
					end else begin
						obj_count <= obj_count - 1;
					end
				end else begin
					for (i = 0; i < MAX_OBJ; i = i + 1) begin
						if (i < obj_count)
							obj_ypos[i] <= obj_ypos[i] + fall_speed_eff;
					end

					if (spawn_pop) begin
						obj_lane[obj_count] <= spawn_lane;
						obj_xoff[obj_count] <= spawn_xoff;
						obj_type[obj_count] <= spawn_type;
						obj_ypos[obj_count] <= 0;
						obj_count <= obj_count + 1;
					end
				end

				if (spawn_pop)
					spawn_cnt <= spawn_period_eff - 1;
				else if (spawn_cnt != 0)
					spawn_cnt <= spawn_cnt - 1;

				if (timer_tick) begin
					frame_cnt <= 0;

					if (next_timer > 1) begin
						timer <= next_timer - 1;
					end else if (stage < STAGE_COUNT - 1) begin
						// Stage clear: roll into the next stage with a fresh minute
						stage <= stage + 1;
						timer <= TIMER_START;
					end else begin
						timer <= 0;
						state <= S_OVER;
						if (high_score_will_update) begin
							high_score_bcd <= score_bcd;
						end
					end
				end else begin
					frame_cnt <= frame_cnt + 1;
				end
			end
		end

		if (SKILL_ENABLE && skill_start)
			skill_charge <= 0;

		if (SKILL_ENABLE && skill_start)
			timer <= timer + TIME_SKILL_BONUS;

		if (jump_fire) begin
			player_vy <= -JUMP_VELOCITY;
			jump_count <= jump_count + 1;
		end

		// Both jumps spent and still airborne: drop the two ground runners
		if (ground_clone_fire) begin
			fly_x[0] <= player_x;
			fly_y[0] <= `PLAYER_Y;
			fly_x[1] <= player_x;
			fly_y[1] <= `PLAYER_Y;
			fly_active[0] <= 1'b1;
			fly_active[1] <= 1'b1;
		end

		// Arming the stage 3 flight wins over anything set above this cycle.
		if (SKILL_ENABLE && skill_start && stage == 2) begin
			crazy_state <= C_WIND;
			crazy_cnt <= 0;
		end
	end
end
endmodule
