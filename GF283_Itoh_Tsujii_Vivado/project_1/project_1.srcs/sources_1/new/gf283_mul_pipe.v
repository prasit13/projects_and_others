`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : gf283_mul_pipe
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : Registered GF(2^283) field multiplier,  c = a * b mod f(x).
//
// Why pipelined
//               The flat combinational path
//                   operands -> Karatsuba tree (4 recursion levels) -> reducer
//               is by far the longest path in the design. Splitting it with a
//               register on the 565-bit unreduced product turns one very long
//               path into two shorter ones and roughly doubles the achievable
//               clock frequency, at a cost of 565 flip-flops.
//
// Pipeline     stage 0 : capture operands              (a_r, b_r)
//              stage 1 : Karatsuba product             (prod_r)   <- ks283
//              stage 2 : reduction mod f(x)            (c)        <- gf283_reduce
//
// Handshake   : pulse `start` for one cycle with `a`/`b` valid.
//               `done` pulses for one cycle exactly 3 cycles later, and `c`
//               holds the result on (and after) that cycle.
//               Fully pipelined: a new `start` may be issued every cycle, but
//               the Itoh-Tsujii controller issues them one at a time.
//
// Latency     : 3 clock cycles.
//////////////////////////////////////////////////////////////////////////////////

module gf283_mul_pipe #(
    parameter integer M = 283
)(
    input  wire            clk,
    input  wire            rst_n,       // active-low synchronous-release reset
    input  wire            start,       // 1-cycle strobe: sample a and b
    input  wire [M-1:0]    a,
    input  wire [M-1:0]    b,
    output reg  [M-1:0]    c,           // valid when done == 1
    output reg             done         // 1-cycle strobe, 3 cycles after start
);

    // ---- stage 0 : operand registers ------------------------------------
    reg [M-1:0] a_r, b_r;
    reg         v1, v2;

    // ---- stage 1 : Karatsuba (combinational between a_r/b_r and prod) ----
    wire [2*M-2:0] prod;
    reg  [2*M-2:0] prod_r;

    ks283 u_kar (
        .a (a_r),
        .b (b_r),
        .d (prod)
    );

    // ---- stage 2 : reduction (combinational between prod_r and red) ------
    wire [M-1:0] red;

    gf283_reduce #(.M(M), .WIN(2*M-1)) u_red (
        .in  (prod_r),
        .out (red)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_r    <= {M{1'b0}};
            b_r    <= {M{1'b0}};
            prod_r <= {(2*M-1){1'b0}};
            c      <= {M{1'b0}};
            v1     <= 1'b0;
            v2     <= 1'b0;
            done   <= 1'b0;
        end else begin
            // stage 0
            if (start) begin
                a_r <= a;
                b_r <= b;
            end
            v1 <= start;

            // stage 1
            if (v1) prod_r <= prod;
            v2 <= v1;

            // stage 2
            if (v2) c <= red;
            done <= v2;
        end
    end

endmodule
