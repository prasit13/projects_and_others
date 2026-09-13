`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks71    (Karatsuba level 2, unbalanced split)
//
// Function    : Carry-less polynomial product, 71 x 71 -> 141 bits.
//
// Split       : 71 = 36 + 35  (low half takes the extra bit)
//                   Al = a[35:0]  (36 bits)    Ah = a[70:36]  (35 bits)
//               m2 = Al*Bl          via ks36
//               m1 = Ah*Bh          via ks35
//               m3 = (Ah+Al)(Bh+Bl) via ks36
//               d  = m2 + (m1^m2^m3)*x^36 + m1*x^72
//
// Instantiated by: ks142 (x3), ks141 (x2).   Children: ks36 (x2), ks35 (x1).
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

module ks71(a, b, d);
input wire [70:0] a;  input wire [70:0] b;            
output wire [140:0] d;


wire [68:0] m1; //AhBh
wire [70:0] m2; //AlBl
wire [70:0] m3; //(Ah+Al)(Bh+Bl)
wire [35:0] ahl; //(Ah+Al)
wire [35:0] bhl; //(Bh+Bl)

ks36 ksm1(a[35:0], b[35:0], m2);
ks35 ksm2(a[70:36], b[70:36], m1);

assign ahl[34:0] = a[70:36] ^ a[34:0];
assign ahl[35] = a[35];
assign bhl[34:0] = b[70:36] ^ b[34:0];
assign bhl[35] = b[35];

ks36 ksm3(ahl, bhl, m3);

assign d[35:0] = m2[35:0];
assign d[70:36] = m2[70:36] ^ m2[34:0] ^ m1[34:0] ^ m3[34:0];
assign d[71] = m2[35] ^ m1[35] ^ m3[35];
assign d[104:72] = m2[68:36] ^ m1[68:36] ^ m3[68:36] ^ m1[32:0];
assign d[105] = m2[69] ^ m3[69] ^ m1[33];
assign d[106] = m2[70] ^ m3[70] ^ m1[34];
assign d[140:107] = m1[68:35];

endmodule
