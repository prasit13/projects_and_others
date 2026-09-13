`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks142   (Karatsuba level 1, balanced split)
//
// Function    : Carry-less polynomial product, 142 x 142 -> 283 bits.
//
// Split       : 142 = 71 + 71  (balanced)
//                   Al = a[70:0]     Ah = a[141:71]
//               Three equal-width sub-products, all ks71:
//                   m2 = Al*Bl,  m1 = Ah*Bh,  m3 = (Ah+Al)(Bh+Bl)
//               d  = m2 + (m1^m2^m3)*x^71 + m1*x^142
//
// Because the split is balanced, (Ah+Al) is exactly 71 bits and all three
// children are the same module - the cheapest case for Karatsuba.
//
// Instantiated by: ks283 (x2).      Children: ks71 (x3).
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

module ks142(a, b, d);
input wire [141:0] a;  input wire [141:0] b;            
output wire [282:0] d;


wire [140:0] m1; //AhBh
wire [140:0] m2; //AlBl
wire [140:0] m3; //(Ah+Al)(Bh+Bl)
wire [70:0] ahl; //(Ah+Al)
wire [70:0] bhl; //(Bh+Bl)

ks71 ksm1(a[70:0], b[70:0], m2);
ks71 ksm2(a[141:71], b[141:71], m1);

assign ahl[70:0] = a[141:71] ^ a[70:0];
assign bhl[70:0] = b[141:71] ^ b[70:0];

ks71 ksm3(ahl, bhl, m3);

assign d[70:0] = m2[70:0];
assign d[140:71] = m2[140:71] ^ m2[69:0] ^ m1[69:0] ^ m3[69:0];
assign d[141] = m2[70] ^ m1[70] ^ m3[70];
assign d[211:142] = m2[140:71] ^ m1[140:71] ^ m3[140:71] ^ m1[69:0];
assign d[282:212] = m1[140:70];

endmodule
