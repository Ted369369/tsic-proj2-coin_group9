`define GAME_X0 10'd64
`define UI_TOP 10'd416
`define OBJ_W 10'd32
`define OBJ_H 10'd32
`define PLAYER_W 10'd64
`define PLAYER_H 10'd64
`define PLAYER_Y 10'd352
`define PLAY_TOP 10'd16
`define CLONE_SIDE 1
`define FLY_CLONES 5
// Shared so game_ctrl's threshold and ui_layer's meter can never disagree.
`define SKILL_CHARGE_MAX 3
`define CLONE_SPAN (`PLAYER_W * (2 * `CLONE_SIDE + 1))
