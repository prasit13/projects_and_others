`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks141   (Karatsuba level 1, unbalanced split)
//
// Function    : Carry-less polynomial product, 141 x 141 -> 281 bits.
//
// Split       : 141 = 71 + 70  (low half takes the extra bit)
//                   Al = a[70:0]  (71 bits)    Ah = a[140:71]  (70 bits)
//               m2 = Al*Bl        via ks71
//               m1 = Ah*Bh        via ks70     <- narrower result, 139 bits
//               m3 = (Ah+Al)(Bh+Bl) via ks71   <- sum is 71 bits, so ks71
//               d  = m2 + (m1^m2^m3)*x^71 + m1*x^142
//
// m1 is two bits narrower than m2/m3, so bits 210 and 211 of the result are
// written out explicitly instead of folding them into a part-select.
//
// Instantiated by: ks283 (x1).      Children: ks71 (x2), ks70 (x1).
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

module ks141(a, b, d);
input wire [140:0] a;  input wire [140:0] b;            
output wire [280:0] d;


wire [138:0] m1; //AhBh
wire [140:0] m2; //AlBl
wire [140:0] m3; //(Ah+Al)(Bh+Bl)
wire [70:0] ahl; //(Ah+Al)
wire [70:0] bhl; //(Bh+Bl)

ks71 ksm1(a[70:0], b[70:0], m2);
ks70 ksm2(a[140:71], b[140:71], m1);

assign ahl[69:0] = a[140:71] ^ a[69:0];
assign ahl[70] = a[70];
assign bhl[69:0] = b[140:71] ^ b[69:0];
assign bhl[70] = b[70];

ks71 ksm3(ahl, bhl, m3);

assign d[70:0] = m2[70:0];
assign d[140:71] = m2[140:71] ^ m2[69:0] ^ m1[69:0] ^ m3[69:0];
assign d[141] = m2[70] ^ m1[70] ^ m3[70];
assign d[209:142] = m2[138:71] ^ m1[138:71] ^ m3[138:71] ^ m1[67:0];
assign d[210] = m2[139] ^ m3[139] ^ m1[68];
assign d[211] = m2[140] ^ m3[140] ^ m1[69];
assign d[280:212] = m1[138:70];

endmodule
