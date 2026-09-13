`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks18    *** KARATSUBA BASE CASE ***
//
// Function    : Carry-less polynomial product, 18 x 18 -> 35 bits, by the
//               schoolbook AND-XOR array
//                   p[i+j] ^= a[i] & b[j]      for all i, j
//
// Why stop the recursion here
//   Each extra Karatsuba level trades one n/2-bit multiplier for roughly 4
//   n/2-bit XOR rows. On a 6-input-LUT FPGA that trade stops paying off at
//   around 16-20 bits, so 18/17 is the base-case threshold. 70 instances of
//   this module exist in the tree.
//
//   The nested for-loops are fully static, so synthesis unrolls them into a
//   plain 324-AND / XOR-tree array - no sequential logic is inferred despite
//   the always block (p is a combinational reg).
//
// Instantiated by: ks36 (x3), ks35 (x2).   Leaf module.
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

module ks18(
    input  wire [17:0] a,
    input  wire [17:0] b,
    output reg  [34:0] p
);
    integer i,j;
    always @* begin
        p = {35{1'b0}};
        for (i=0; i<18; i=i+1)
            for (j=0; j<18; j=j+1)
                p[i+j] = p[i+j] ^ (a[i] & b[j]);
    end
endmodule