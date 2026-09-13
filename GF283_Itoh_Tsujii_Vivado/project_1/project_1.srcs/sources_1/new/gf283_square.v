`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : gf283_square
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : s = a^2 mod f(x),  f(x) = x^283 + x^12 + x^7 + x^5 + 1
//
// Method      : In characteristic 2 the Frobenius map is linear, so squaring is
//               just bit interleaving followed by reduction:
//
//                   a(x)   = sum_i a_i x^i
//                   a(x)^2 = sum_i a_i x^(2i)          (all cross terms cancel)
//
//               i.e. insert a zero between every pair of input bits to build a
//               565-bit polynomial, then reduce with the shared gf283_reduce.
//               Because the odd coefficients are hard zeros, synthesis prunes
//               roughly half of the reducer's XOR tree automatically, so this
//               costs far less than a general multiply-by-self.
//
// Cost        : ~1 LUT level of XOR (no AND gates at all) - squaring is cheap,
//               which is exactly what makes Itoh-Tsujii inversion attractive.
//
// Latency     : combinational.
//////////////////////////////////////////////////////////////////////////////////

module gf283_square #(
    parameter integer M = 283
)(
    input  wire [M-1:0] a,
    output wire [M-1:0] s
);

    localparam integer WSQ = 2*M - 1;       // 565: degree of a^2 is <= 2*(M-1)

    wire [WSQ-1:0] spread;                  // a(x)^2 before reduction

    genvar i;
    generate
        for (i = 0; i < M; i = i + 1) begin : GEN_SPREAD
            assign spread[2*i] = a[i];                      // even positions
            if (2*i + 1 < WSQ)
                assign spread[2*i+1] = 1'b0;                // odd positions
        end
    endgenerate

    gf283_reduce #(.M(M), .WIN(WSQ)) u_red (
        .in  (spread),
        .out (s)
    );

endmodule