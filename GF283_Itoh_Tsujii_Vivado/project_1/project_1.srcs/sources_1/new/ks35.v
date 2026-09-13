`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module      : ks35    (Karatsuba level 3, unbalanced split)
//
// Function    : Carry-less polynomial product, 35 x 35 -> 69 bits.
//
// Split       : 35 = 18 + 17  (low half takes the extra bit)
//                   Al = a[17:0]  (18 bits)    Ah = a[34:18]  (17 bits)
//               m2 = Al*Bl          via ks18
//               m1 = Ah*Bh          via ks17   <- 33-bit result
//               m3 = (Ah+Al)(Bh+Bl) via ks18
//               d  = m2 + (m1^m2^m3)*x^18 + m1*x^36
//
// Instantiated by: ks71 (x1), ks70 (x3).   Children: ks18 (x2), ks17 (x1).
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

module ks35(a, b, d);
input wire [34:0] a;  input wire [34:0] b;            
output wire [68:0] d;


wire [32:0] m1; //AhBh
wire [34:0] m2; //AlBl
wire [34:0] m3; //(Ah+Al)(Bh+Bl)
wire [17:0] ahl; //(Ah+Al)
wire [17:0] bhl; //(Bh+Bl)

ks18 ksm1(a[17:0], b[17:0], m2);
ks17 ksm2(a[34:18], b[34:18], m1);

assign ahl[16:0] = a[34:18] ^ a[16:0];
assign ahl[17] = a[17];
assign bhl[16:0] = b[34:18] ^ b[16:0];
assign bhl[17] = b[17];

ks18 ksm3(ahl, bhl, m3);

assign d[17:0] = m2[17:0];
assign d[34:18] = m2[34:18] ^ m2[16:0] ^ m1[16:0] ^ m3[16:0];
assign d[35] = m2[17] ^ m1[17] ^ m3[17];
assign d[50:36] = m2[32:18] ^ m1[32:18] ^ m3[32:18] ^ m1[14:0];
assign d[51] = m2[33] ^ m3[33] ^ m1[15];
assign d[52] = m2[34] ^ m3[34] ^ m1[16];
assign d[68:53] = m1[32:17];

endmodule
