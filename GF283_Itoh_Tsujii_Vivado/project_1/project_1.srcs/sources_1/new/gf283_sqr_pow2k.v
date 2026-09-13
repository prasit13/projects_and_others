`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : gf283_sqr_pow2k
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : Iterated Frobenius / repeated squaring
//                   r = a^(2^k) mod f(x),   0 <= k <= 511
//
//               This is the workhorse of Itoh-Tsujii inversion: the addition
//               chain for m-1 = 282 needs 282 squarings in total but only 11
//               multiplications, so squaring throughput dominates the runtime.
//
// Architecture: A cascade of CASCADE combinational gf283_square blocks lets the
//               unit retire up to CASCADE squarings per clock cycle:
//
//                   cur --[sq]--[sq]-- ... --[sq]--> sqflat[CASCADE]
//                        ^1     ^2            ^CASCADE
//                          \      \             \
//                           +------+-------------+--> mux (by remaining count)
//
//               On the final cycle fewer than CASCADE squarings may be needed,
//               so the mux selects the correct tap. CASCADE therefore trades
//               latency against combinational depth:
//                   CASCADE = 1 -> 282 cycles, shortest path
//                   CASCADE = 4 ->  ~71 cycles, ~4 squarer delays  (default)
//                   CASCADE = 8 ->  ~36 cycles, ~8 squarer delays
//
// Handshake   : pulse `start` with `a` and `k` valid. `done` pulses for one
//               cycle when finished; `r` is valid on that cycle and holds.
//               k = 0 is handled correctly and returns r = a.
//
// Latency     : ceil(k/CASCADE) + 3 clock cycles (k>0); 3 cycles for k = 0.
//////////////////////////////////////////////////////////////////////////////////

module gf283_sqr_pow2k #(
    parameter integer M       = 283,
    parameter integer CASCADE = 4       // squarings retired per clock cycle
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            start,       // 1-cycle strobe
    input  wire [M-1:0]    a,           // base
    input  wire [8:0]      k,           // exponent: compute a^(2^k)
    output reg  [M-1:0]    r,           // valid when done == 1
    output reg             done         // 1-cycle strobe
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1,
                     S_FIN  = 2'd2;

    reg  [1:0]   state;
    reg  [M-1:0] cur;                   // running value
    reg  [8:0]   rem;                   // squarings still to perform

    // ---------------------------------------------------------------------
    // Combinational squaring cascade.
    // sqflat[i*M +: M] holds cur^(2^i) for i = 0 .. CASCADE.
    // ---------------------------------------------------------------------
    wire [(CASCADE+1)*M-1:0] sqflat;

    assign sqflat[0 +: M] = cur;        // tap 0 = cur^(2^0) = cur

    genvar i;
    generate
        for (i = 1; i <= CASCADE; i = i + 1) begin : GEN_CHAIN
            gf283_square #(.M(M)) u_sq (
                .a (sqflat[(i-1)*M +: M]),
                .s (sqflat[ i   *M +: M])
            );
        end
    endgenerate

    // Squarings to retire this cycle: min(rem, CASCADE)
    wire [8:0] step = (rem > CASCADE[8:0]) ? CASCADE[8:0] : rem;

    // Tap select. The loop bound is a parameter, so synthesis unrolls this into
    // a plain (CASCADE+1)-input mux with constant bit offsets.
    reg [M-1:0] nxt;
    integer j;
    always @* begin
        nxt = cur;
        for (j = 0; j <= CASCADE; j = j + 1)
            if (step == j[8:0]) nxt = sqflat[j*M +: M];
    end

    // ---------------------------------------------------------------------
    // Control FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cur   <= {M{1'b0}};
            rem   <= 9'd0;
            r     <= {M{1'b0}};
            done  <= 1'b0;
        end else begin
            done <= 1'b0;               // default: single-cycle strobe

            case (state)

                S_IDLE: begin
                    if (start) begin
                        cur   <= a;
                        rem   <= k;
                        state <= S_RUN;
                    end
                end

                // Retire `step` squarings per cycle until rem reaches zero.
                S_RUN: begin
                    cur <= nxt;
                    rem <= rem - step;
                    if (rem <= step)    // this was the last chunk (covers k = 0)
                        state <= S_FIN;
                end

                // Publish the result. `cur` already holds the final value.
                S_FIN: begin
                    r     <= cur;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
