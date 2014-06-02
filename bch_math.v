`timescale 1ns / 1ps

/*
 * Bit-serial Berlekamp (mixed dual/standard basis) multiplier)
 * Can multiply one dual basis input by N_INPUTS standard basis
 * inputs in M cycles, producing one bit of each output per
 * cycle
 */
module serial_mixed_multiplier #(
	parameter M = 4,
	parameter N_INPUT = 1
) (
	input clk,
	input start,
	input [M-1:0] dual_in,
	input [M*N_INPUT-1:0] standard_in,
	output [N_INPUT-1:0] dual_out
);

	`include "bch.vh"

	localparam TCQ = 1;

	reg [M-1:0] lfsr = 0;
	wire [M-1:0] poly = bch_polynomial(M);
	genvar i;

	/* LFSR for generating aux bits */
	always @(posedge clk) begin
		if (start)
			lfsr <= #TCQ dual_in;
		else
			lfsr <= #TCQ {^(lfsr & poly), lfsr[M-1:1]};
	end

	for (i = 0; i < N_INPUT; i = i + 1) begin : mult
		assign dual_out[i] = ^(standard_in[M*i+:M] & lfsr);
	end
endmodule

/* Berlekamp bit-parallel dual-basis multiplier */
module parallel_mixed_multiplier #(
	parameter M = 4
) (
	input [M-1:0] dual_in,
	input [M-1:0] standard_in,
	output [M-1:0] dual_out
);
	`include "bch.vh"

	wire [M-2:0] aux;
	wire [M-1:0] poly = bch_polynomial(M);
	wire [M*2-2:0] all;
	genvar i;

	assign all = {aux, dual_in};

	/* Generate additional terms via an LFSR */
	for (i = 0; i < M - 1; i = i + 1) begin : aux_assign
		assign aux[i] = ^(all[i+:M] & poly);
	end

	/* Perform matrix multiplication of terms */
	for (i = 0; i < M; i = i + 1) begin : mult
		assign dual_out[i] = ^(all[i+:M] & standard_in);
	end

endmodule

/* Bit-parallel standard basis multiplier (PPBML) */
module parallel_standard_multiplier #(
	parameter M = 4,
	parameter N_INPUT = 1
) (
	input [M-1:0] standard_in1,
	input [M*N_INPUT-1:0] standard_in2,
	output [M*N_INPUT-1:0] standard_out
);
	`include "bch.vh"
	genvar i, j;

	generate
	for (i = 0; i < M; i = i + 1) begin : BLOCKS
		/* alpha^i * standard_in1, each block does one mult */
		wire [M-1:0] bits;

		/* Bit i of each block */
		wire [M-1:0] z;

		/* Stage 1, multiply by alpha once for each block */
		if (i == 0)
			assign bits = standard_in1;
		else
			assign bits = mul1(M, BLOCKS[i-1].bits);

		/* Arrange bits for input into stage 2 */
		for (j = 0; j < M; j = j + 1) begin : arrange
			assign z[j] = BLOCKS[j].bits[i];
		end

		/* Perform multiplication */
		for (j = 0; j < N_INPUT; j = j + 1) begin : mult
			assign standard_out[j*M+i] = ^(standard_in2[j*M+:M] & z);
		end
	end
	endgenerate
endmodule

/*
 * Final portion of MSB first bit-serial standard basis multiplier
 * Input per cycle:
 *	M{a[M-1]} & b
 *	M{a[M-2]} & b
 *	...
 *	M[a[0]} & b
 * The above input stage can be combined with other functions.
 * Takes M cycles
 */
module serial_standard_multiplier_final #(
	parameter M = 4
) (
	input clk,
	input run, /* FIXME: Probably not required */
	input start,
	input [M-1:0] standard_in,
	output reg [M-1:0] out = 0
);
	`include "bch.vh"

	localparam TCQ = 1;
	localparam POLY = bch_polynomial(M);

	always @(posedge clk) begin
		if (start)
			out <= #TCQ standard_in;
		else if (run)
			out <= standard_in ^ {out[M-2:0], 1'b0} ^ (POLY & {M{out[M-1]}});
	end
endmodule

/* Square the standard basis input */
module parallel_standard_square #(
	parameter M = 4
) (
	input [M-1:0] standard_in,
	output [M-1:0] standard_out
);
	`include "bch.vh"

	genvar i, j;
	for (i = 0; i < M; i = i + 1) begin : out_assign
		wire [M-1:0] terms = lpow(M, i * 2);
		wire [M-1:0] rot;
		for (j = 0; j < M; j = j + 1) begin : rotate
			assign rot[j] = out_assign[j].terms[i];
		end
		assign standard_out[i] = ^(standard_in & rot);
	end
endmodule

/*
 * Divider, takes M clock cycles.
 * Inverse of denominator is calculated by using fermat inverter:
 * 	a^(-1) = (a^2)*(a^2^2)*(a^2^3)....*(a^2^(m-1))
 * Wang, Charles C., et al. "VLSI architectures for computing multiplications
 * and inverses in GF (2 m)." Computers, IEEE Transactions on 100.8 (1985):
 * 709-717.
 *
 * Load denominator with start=1. If !busy (M cyles have passed), result is
 * in dual_out. Numerator is not required until busy is low.
 */
module finite_divider #(
	parameter M = 6
) (
	input clk,
	input reset,
	input start,
	input [M-1:0] standard_numer,
	input [M-1:0] standard_denom,
	output [M-1:0] dual_out,
	output reg busy = 0
);
	`include "bch.vh"

	localparam TCQ = 1;

	reg busy_last = 0;
	reg [M-1:0] standard_a = 0;
	wire [M-1:0] standard_b;
	reg [M-1:0] dual_c = standard_to_dual(M, lpow(M, 0));
	wire [M-1:0] dual_d;
	wire [log2(M)-1:0] count;

	assign dual_out = dual_d;

	/* Since standard_to_dual doesn't support pentanomials */
	if (bch_is_pentanomial(M))
		inverter_cannot_handle_pentanomials_yet u_ichp();

	/* Square the input each cycle */
	parallel_standard_square #(M) u_dsq(
		.standard_in(start ? standard_denom : standard_a),
		.standard_out(standard_b)
	);

	/* Accumulate the term each cycle (Reuse for C = A*B^(-1) ) */
	parallel_mixed_multiplier #(M) u_parallel_mixed_multiplier(
		.dual_in(dual_c),
		.standard_in((busy || busy_last) ? standard_a : standard_numer),
		.dual_out(dual_d)
	);

	lfsr_counter #(log2(M)) u_counter(
		.clk(clk),
		.reset(start),
		.count(count)
	);

	always @(posedge clk) begin
		busy_last <= #TCQ busy;
		if (start && !reset)
			busy <= #TCQ 1;
		else if (count == lfsr_count(log2(M), M - 2) || reset)
			busy <= #TCQ 0;

		if (start || reset)
			dual_c <= #TCQ standard_to_dual(M, lpow(M, 0));
		else if (busy)
			dual_c <= #TCQ dual_d;

		if (start || busy)
			standard_a <= #TCQ standard_b;
	end
endmodule

module pow3 #(
	parameter M = 4
) (
	input [M-1:0] in,
	output [M-1:0] out
);
	`include "bch.vh"

	function [MAX_M*(MAX_M+1)/2-1:0] pow3_terms;
		input [31:0] m;
		input [31:0] bit_pos;
		integer i;
		integer j;
		integer k;
		integer s;
		integer mask;
		integer ret;
	begin
		s = (m * (m + 1)) / 2;
		mask = 1 << bit_pos;
		k = 1;

		ret = 0;
		for (i = 0; i < m; i = i + 1) begin
			ret = ret | ((lpow(m, 3*i) & mask) ? k : 1'b0);
			k = k << 1;
		end

		for (i = 0; i < m - 1; i = i + 1) begin
			for (j = i + 1; j < m; j = j + 1) begin
				ret = ret | (((lpow(m, 2*i+j) ^ lpow(m, 2*j+i)) & mask) ? k : 1'b0);
				k = k << 1;
			end
		end

		pow3_terms = ret;
	end
	endfunction

	function integer dxor_terms;
		input [31:0] m;
		input [31:0] bit_pos;
		integer k;
		integer i;
		integer done;
		integer ret;
	begin
		k = 0;
		ret = 0;
		done = 0;
		for (i = 0; i < m && !done; i = i + 1) begin
			if (bit_pos < k + m - i) begin
				if (i > 0)
					ret = ret | (1 << (i - 1));
				ret = ret | (1 << (bit_pos - k + i));
				done = 1;
			end
			k = k + m - i;
		end
		dxor_terms = ret;
	end
	endfunction

	wire [M*(M+1)/2-1:0] dxor;
	genvar i;

	for (i = 0; i < M * (M + 1) / 2; i = i + 1) begin : gen_xor
		assign dxor[i] = !(dxor_terms(M, i) & ~in);
	end

	for (i = 0; i < M; i = i + 1) begin : gen_out
		assign out[i] = ^(dxor & pow3_terms(M, i));
	end
endmodule

module generate_cs #(
	parameter M = 4,
	parameter T = 3
) (
	input [M*(T+1)-1:0] terms,
	output [M-1:0] cs
);
	wire [M*(T+1)-1:0] rearranged;
	genvar i, j;

	/* cs generation, input rearranged_in, output cs */
	/* snNen dandm/msN doxrt */
	for (i = 0; i < M; i = i + 1) begin : snen
		for (j = 0; j <= T; j = j + 1) begin : ms
			assign rearranged[i*(T+1)+j] = terms[j*M+i];
		end
	end

	/* msN dxort */
	for (i = 0; i < M; i = i + 1) begin : cs_arrange
		assign cs[i] = ^rearranged[i*(T+1)+:T+1];
	end

endmodule

module lfsr_counter #(
	parameter M = 4
) (
	input clk,
	input reset,
	output reg [M-1:0] count = 1
);
	`include "bch.vh"

	localparam TCQ = 1;

	always @(posedge clk)
		count <= #TCQ reset ? 1'b1 : {count[M-2:0], 1'b0} ^
			({M{count[M-1]}} & bch_polynomial(M));
endmodule
