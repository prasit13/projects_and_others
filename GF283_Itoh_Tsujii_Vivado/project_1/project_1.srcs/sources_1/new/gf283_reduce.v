`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : gf283_reduce
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : Reduces an unreduced binary polynomial of degree < WIN modulo the
//               NIST/SECG irreducible pentanomial
//
//                   f(x) = x^283 + x^12 + x^7 + x^5 + 1
//
// Method      : Two-pass "fold" reduction (purely combinational, no loops).
//
//               From f(x) = 0 we get the folding identity
//                   x^283 == x^12 + x^7 + x^5 + 1        (mod f, char 2)
//               so for any j >= 0
//                   x^(283+j) == x^(12+j) + x^(7+j) + x^(5+j) + x^j.
//
//               PASS 1: split the input C into
//                          C = HI*x^283 + LO,   LO = C[282:0], HI = C[WIN-1:283]
//                       and replace HI*x^283 by HI*(x^12+x^7+x^5+1):
//                          T = LO ^ HI ^ (HI<<5) ^ (HI<<7) ^ (HI<<12)
//                       For WIN = 565, HI is 282 bits so deg(T) <= 281+12 = 293:
//                       still 11 bits too wide, hence a second pass.
//
//               PASS 2: identical fold applied to T. Now HI2 is only 11 bits, so
//                       the folded term has degree <= 10+12 = 22 < 283 and the
//                       result is guaranteed fully reduced. No third pass needed.
//
//               Each output bit is therefore an XOR of at most 5+5 = 10 input
//               bits -> two LUT6 levels. This replaces the naive 282-iteration
//               bit-serial long division (which synthesises into a very deep
//               dependency chain) and is a large area/delay win.
//
// Parameters  : M   - field degree (283). The tap positions below are specific to
//                     the mandated pentanomial and are NOT parameterised.
//               WIN - width of the unreduced input. 565 for a Karatsuba product
//                     (2*283-1), but the module also handles narrower inputs.
//
// Latency     : combinational.
//////////////////////////////////////////////////////////////////////////////////

module gf283_reduce #(
    parameter integer M   = 283,        // field degree
    parameter integer WIN = 2*283 - 1   // width of unreduced input (565)
)(
    input  wire [WIN-1:0] in,           // unreduced polynomial, deg < WIN
    output wire [M-1:0]   out           // in mod f(x), deg < 283
);

    // Non-zero, non-leading exponents of f(x) = x^283 + x^12 + x^7 + x^5 + 1
    localparam integer T1 = 12;
    localparam integer T2 = 7;
    localparam integer T3 = 5;

    // ---------------------------------------------------------------------
    // Pass 1 : fold bits [WIN-1:M] down into the low part
    // ---------------------------------------------------------------------
    localparam integer H1 = WIN - M;        // 282 high bits for WIN = 565
    localparam integer W1 = H1 + T1;        // 294 : widest possible intermediate

    wire [H1-1:0] hi1 = in[WIN-1:M];        // coefficients of x^283 .. x^(WIN-1)
    wire [M-1:0]  lo1 = in[M-1:0];          // already-reduced part

    // Zero-extend hi1 to W1 bits so that the <<T1 shift never truncates
    // (H1 + T1 == W1 exactly, so the top tap fits by construction).
    wire [W1-1:0] h1e = {{(W1-H1){1'b0}}, hi1};
    wire [W1-1:0] l1e = {{(W1-M){1'b0}},  lo1};

    // T = LO ^ HI*(x^12 + x^7 + x^5 + 1)
    wire [W1-1:0] fold1 = l1e ^ h1e ^ (h1e << T3) ^ (h1e << T2) ^ (h1e << T1);

    // ---------------------------------------------------------------------
    // Pass 2 : fold the (now only H2-bit) overflow of pass 1
    // ---------------------------------------------------------------------
    localparam integer H2 = W1 - M;         // 11 bits for WIN = 565

    wire [H2-1:0] hi2 = fold1[W1-1:M];
    wire [M-1:0]  lo2 = fold1[M-1:0];

    // (H2-1)+T1 = 22 < M, so this pass cannot overflow: result is final.
    wire [M-1:0]  h2e = {{(M-H2){1'b0}}, hi2};

    assign out = lo2 ^ h2e ^ (h2e << T3) ^ (h2e << T2) ^ (h2e << T1);

    // Design-time sanity checks (simulation only, ignored by synthesis)
    // synthesis translate_off
    initial begin
        if (WIN <= M) begin
            $display("FATAL gf283_reduce: WIN (%0d) must exceed M (%0d)", WIN, M);
            $finish;
        end
        if (H2 + T1 > M) begin
            $display("FATAL gf283_reduce: two folds insufficient for WIN = %0d", WIN);
            $finish;
        end
    end
    // synthesis translate_on

endmodule