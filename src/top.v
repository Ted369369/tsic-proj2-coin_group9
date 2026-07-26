module top (
	input clk,
	input resetn,
	input btn_left,
	input btn_right,
	input btn_start,
	input btn_skill,

	output snd,

	output tmds_clk_n,
	output tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

wire clk_p;
wire clk_p5;
wire pll_lock;
wire sys_resetn;

// synchronized and debounced button signals
wire btn_left_syn, btn_left_deb;
wire btn_right_syn, btn_right_deb;
wire btn_start_syn, btn_start_deb;
wire btn_skill_syn, btn_skill_deb;

wire game_tvalid;
wire game_tready;
wire [23:0] game_tdata;
wire [0:0] game_tuser;

Gowin_CLKDIV u_clkdiv (
	.clkout(clk_p),
	.hclkin(clk_p5),
	.resetn(pll_lock)
);

Gowin_PLLVR u_pll (
	.clkout(clk_p5),
	.lock(pll_lock),
	.clkin(clk)
);

reset_sync u_reset_sync (
	.clk(clk_p),
	.ext_reset(resetn & pll_lock),
	.resetn(sys_resetn)
);

ff_sync u_btn_left_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_left),
	.out(btn_left_syn)
);

ff_sync u_btn_right_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_right),
	.out(btn_right_syn)
);

ff_sync u_btn_start_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_start),
	.out(btn_start_syn)
);

ff_sync u_btn_skill_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_skill),
	.out(btn_skill_syn)
);

debounce u_btn_left_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_left_syn),
	.out(btn_left_deb)
);

debounce u_btn_right_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_right_syn),
	.out(btn_right_deb)
);

debounce u_btn_start_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_start_syn),
	.out(btn_start_deb)
);

debounce u_btn_skill_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_skill_syn),
	.out(btn_skill_deb)
);

game_core #(
	.SVO_MODE("640x480V")
) u_game_core (
	.clk(clk_p),
	.resetn(sys_resetn),

	.btn_left(btn_left_deb),
	.btn_right(btn_right_deb),
	.btn_start(btn_start_deb),
	.btn_skill(btn_skill_deb),

	.snd(snd),

	.out_axis_tvalid(game_tvalid),
	.out_axis_tready(game_tready),
	.out_axis_tdata(game_tdata),
	.out_axis_tuser(game_tuser)
);

svo_hdmi #(
	.SVO_MODE("640x480V")
) u_svo_hdmi (
	.resetn(sys_resetn),

	.clk_pixel(clk_p),
	.clk_5x_pixel(clk_p5),
	.locked(pll_lock),

	.in_axis_tvalid(game_tvalid),
	.in_axis_tready(game_tready),
	.in_axis_tdata(game_tdata),
	.in_axis_tuser(game_tuser),

	.tmds_clk_n(tmds_clk_n),
	.tmds_clk_p(tmds_clk_p),
	.tmds_d_n(tmds_d_n),
	.tmds_d_p(tmds_d_p)
);

endmodule
