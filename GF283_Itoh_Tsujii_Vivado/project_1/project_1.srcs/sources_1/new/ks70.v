`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks70    (Karatsuba level 2, balanced split)
//
// Function    : Carry-less polynomial product, 70 x 70 -> 139 bits.
//
// Split       : 70 = 35 + 35  (balanced)
//                   Al = a[34:0]     Ah = a[69:35]
//               Three equal ks35 sub-products.
//               d = m2 + (m1^m2^m3)*x^35 + m1*x^70
//
// Instantiated by: ks141 (x1).      Children: ks35 (x3).
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

module ks70(a, b, d);
input wire [69:0] a;  input wire [69:0] b;            
output wire [138:0] d;


wire [68:0] m1; //AhBh
wire [68:0] m2; //AlBl
wire [68:0] m3; //(Ah+Al)(Bh+Bl)
wire [34:0] ahl; //(Ah+Al)
wire [34:0] bhl; //(Bh+Bl)

ks35 ksm1(a[34:0], b[34:0], m2);
ks35 ksm2(a[69:35], b[69:35], m1);

assign ahl[34:0] = a[69:35] ^ a[34:0];
assign bhl[34:0] = b[69:35] ^ b[34:0];

ks35 ksm3(ahl, bhl, m3);

assign d[34:0] = m2[34:0];
assign d[68:35] = m2[68:35] ^ m2[33:0] ^ m1[33:0] ^ m3[33:0];
assign d[69] = m2[34] ^ m1[34] ^ m3[34];
assign d[103:70] = m2[68:35] ^ m1[68:35] ^ m3[68:35] ^ m1[33:0];
assign d[138:104] = m1[68:34];

endmodule
