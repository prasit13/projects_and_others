`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : ks283      (root of the Karatsuba multiplier tree)
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : Carry-less (GF(2)) polynomial multiplication
//                   d(x) = a(x) * b(x),   283 x 283 -> 565 bits
//               UNREDUCED. Reduction modulo f(x) is a separate module
//               (gf283_reduce), keeping "multiply" and "reduce" independent.
//
// ============================ SPLIT STRATEGY ==================================
//
// One-level Karatsuba-Ofman identity. Split each operand into a low and a high
// part at bit 142:
//
//     A = Ah*x^142 + Al      Al = a[141:0]  (142 bits)
//     B = Bh*x^142 + Bl      Ah = a[282:142] (141 bits)
//
// The schoolbook expansion needs four products; Karatsuba needs three:
//
//     A*B = Ah*Bh*x^284
//         + [ (Ah+Al)(Bh+Bl) + Ah*Bh + Al*Bl ] * x^142      <-- the "middle"
//         + Al*Bl
//
// so the three recursive calls are
//     m2 = Al*Bl               via ks142
//     m1 = Ah*Bh               via ks141
//     m3 = (Ah+Al)(Bh+Bl)      via ks142   ((Ah+Al) is 142 bits wide)
// and the middle term is  mid = m1 ^ m2 ^ m3.
//
// In GF(2) addition is XOR, so there are no borrows and no sign handling - this
// is why Karatsuba is especially attractive for binary fields.
//
// -------------------- RECURSION SCHEDULE OF THE WHOLE TREE --------------------
//
//   level 0   ks283   283 = 142 + 141      -> 2x ks142 + 1x ks141
//   level 1   ks142   142 =  71 +  71      -> 3x ks71                 (balanced)
//             ks141   141 =  71 +  70      -> 2x ks71  + 1x ks70
//   level 2   ks71     71 =  36 +  35      -> 2x ks36  + 1x ks35
//             ks70     70 =  35 +  35      -> 3x ks35                 (balanced)
//   level 3   ks36     36 =  18 +  18      -> 3x ks18                 (balanced)
//             ks35     35 =  18 +  17      -> 2x ks18  + 1x ks17
//   level 4   ks18 / ks17  BASE CASE: schoolbook AND-XOR array
//
// Recursion depth        : 4 Karatsuba levels, then a schoolbook base case.
// Base-case threshold    : 17-18 bits. Below this the XOR overhead of another
//                          Karatsuba level costs more LUTs than it saves ANDs
//                          on a 6-input-LUT architecture.
// Base multipliers built : 3^4 = 81 total  (70x ks18 + 11x ks17)
// AND-gate count         : 70*18^2 + 11*17^2 = 25 859
//                          versus 283^2 = 80 089 for flat schoolbook  (~3.1x less)
//
// Every split is "as balanced as possible": odd widths split as
// ceil(n/2) + floor(n/2), with the LOW half taking the extra bit so that the
// (Ah+Al) sum is exactly ceil(n/2) bits and feeds the same sub-multiplier as Al.
//
// -------------------------- OUTPUT RECOMBINATION ------------------------------
//
// d = m2 + mid*x^142 + m1*x^284. The assignments below are split into several
// slices rather than written as one shifted XOR because m1 (281 bits) is
// narrower than m2/m3 (283 bits): the boundary bits 283, 423 and 424 take
// contributions from different sub-ranges, and writing them explicitly avoids
// out-of-range part-selects (which return X in simulation).
//
// Latency     : combinational.
//////////////////////////////////////////////////////////////////////////////////

module ks283(a, b, d);
input wire [282:0] a;  input wire [282:0] b;
output wire [564:0] d;

wire [280:0] m1;   // Ah*Bh              (141 x 141 -> 281 bits)
wire [282:0] m2;   // Al*Bl              (142 x 142 -> 283 bits)
wire [282:0] m3;   // (Ah+Al)(Bh+Bl)     (142 x 142 -> 283 bits)
wire [141:0] ahl;  // Ah + Al
wire [141:0] bhl;  // Bh + Bl

// --- the three recursive sub-products ---
ks142 ksm1(a[141:0], b[141:0], m2);         // low  x low
ks141 ksm2(a[282:142], b[282:142], m1);     // high x high

// Ah is one bit narrower than Al, so bit 141 of the sum is just Al[141].
assign ahl[140:0] = a[282:142] ^ a[140:0];
assign ahl[141] = a[141];
assign bhl[140:0] = b[282:142] ^ b[140:0];
assign bhl[141] = b[141];

ks142 ksm3(ahl, bhl, m3);                   // (sum) x (sum)

// --- recombination: d = m2 + (m1^m2^m3)*x^142 + m1*x^284 ---
assign d[141:0] = m2[141:0];                                        // m2 only
assign d[282:142] = m2[282:142] ^ m2[140:0] ^ m1[140:0] ^ m3[140:0];// m2 + mid
assign d[283] = m2[141] ^ m1[141] ^ m3[141];                        // mid only
assign d[422:284] = m2[280:142] ^ m1[280:142] ^ m3[280:142] ^ m1[138:0]; // mid + m1
assign d[423] = m2[281] ^ m3[281] ^ m1[139];    // m1[281] does not exist -> 0
assign d[424] = m2[282] ^ m3[282] ^ m1[140];    // m1[282] does not exist -> 0
assign d[564:425] = m1[280:141];                                    // m1 only

endmodule
