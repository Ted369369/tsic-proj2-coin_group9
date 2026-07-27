`timescale 1ns / 1ps

// Combinational binary -> packed BCD (double dabble).
// BCD_DIGITS sets how many 4-bit digits come out, so the same module serves
// both the 3-digit timer and the 4-digit score.
module bin2bcd #(
	parameter BIN_BITS = 10,
	parameter BCD_DIGITS = 3
) (
	input [BIN_BITS-1:0] bin,
	output reg [BCD_DIGITS*4-1:0] bcd
);

integer i;
integer d;
reg [BIN_BITS+BCD_DIGITS*4-1:0] shift;

always @(*) begin
	shift = 0;
	shift[BIN_BITS-1:0] = bin;

	for (i = 0; i < BIN_BITS; i = i + 1) begin
		// Any digit already >= 5 gets +3 before the shift, so that shifting
		// carries it into the next digit at the right decimal weight.
		//
		// After i shifts the converted value is at most 2**i - 1, so digit d
		// cannot have reached 5 until 2**i - 1 >= 5 * 10**d. That first happens
		// at i = 3, 6, 9, 13, ... which is what 3 + (10*d)/3 produces with
		// integer division. Skipping the earlier stages drops this converter to
		// roughly half the compare/add units for the same result -- worth it on
		// a device this full.
		for (d = 0; d < BCD_DIGITS; d = d + 1) begin
			if (i >= 3 + (10 * d) / 3) begin
				if (shift[BIN_BITS + d*4 +: 4] >= 4'd5)
					shift[BIN_BITS + d*4 +: 4] =
						shift[BIN_BITS + d*4 +: 4] + 4'd3;
			end
		end

		shift = shift << 1;
	end

	bcd = shift[BIN_BITS + BCD_DIGITS*4 - 1 : BIN_BITS];
end

endmodule
