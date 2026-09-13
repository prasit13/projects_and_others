`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks17    *** KARATSUBA BASE CASE (odd sibling of ks18) ***
//
// Function    : Carry-less polynomial product, 17 x 17 -> 33 bits, by the
//               schoolbook AND-XOR array
//                   p[i+j] ^= a[i] & b[j]      for all i, j
//
// Used for the high half wherever a 35-bit operand splits as 18 + 17.
// 11 instances exist in the tree. See ks18.v for the base-case rationale.
//
// Instantiated by: ks35 (x1).      Leaf module.
//
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Part of the Karatsuba multiplier tree rooted at ks283.v - see that file for
// the full split schedule, recursion depth and base-case rationale.
//
// All arithmetic is over GF(2): addition is XOR, there are no carries, and the
// product is UNREDUCED (reduction mod f(x) happens in gf283_reduce).
//
// Latency     : combinational.
////////////////////////////////////////////////////////////////////////////////

module ks17(
    input  wire [16:0] a,
    input  wire [16:0] b,
    output reg  [32:0] p
);
    integer i,j;
    always @* begin
        p = {33{1'b0}};
        for (i=0; i<17; i=i+1)
            for (j=0; j<17; j=j+1)
                p[i+j] = p[i+j] ^ (a[i] & b[j]);
    end
endmodule