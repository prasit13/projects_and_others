`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks36    (Karatsuba level 3, balanced split)
//
// Function    : Carry-less polynomial product, 36 x 36 -> 71 bits.
//
// Split       : 36 = 18 + 18  (balanced)
//                   Al = a[17:0]     Ah = a[35:18]
//               Three equal ks18 base-case sub-products.
//               d = m2 + (m1^m2^m3)*x^18 + m1*x^36
//
// This is the last Karatsuba level: its children are schoolbook arrays.
//
// Instantiated by: ks71 (x2).       Children: ks18 (x3).
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

module ks36(a, b, d);
input wire [35:0] a;  input wire [35:0] b;            
output wire [70:0] d;


wire [34:0] m1; //AhBh
wire [34:0] m2; //AlBl
wire [34:0] m3; //(Ah+Al)(Bh+Bl)
wire [17:0] ahl; //(Ah+Al)
wire [17:0] bhl; //(Bh+Bl)

ks18 ksm1(a[17:0], b[17:0], m2);
ks18 ksm2(a[35:18], b[35:18], m1);

assign ahl[17:0] = a[35:18] ^ a[17:0];
assign bhl[17:0] = b[35:18] ^ b[17:0];

ks18 ksm3(ahl, bhl, m3);

assign d[17:0] = m2[17:0];
assign d[34:18] = m2[34:18] ^ m2[16:0] ^ m1[16:0] ^ m3[16:0];
assign d[35] = m2[17] ^ m1[17] ^ m3[17];
assign d[52:36] = m2[34:18] ^ m1[34:18] ^ m3[34:18] ^ m1[16:0];
assign d[70:53] = m1[34:17];


endmodule