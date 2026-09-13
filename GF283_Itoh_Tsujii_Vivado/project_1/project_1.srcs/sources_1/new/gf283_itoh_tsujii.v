`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : gf283_itoh_tsujii
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : Inversion controller. Computes  inv = a^(-1) mod f(x)  for a != 0
//               in GF(2^283) using the Itoh-Tsujii algorithm.
//
// Algorithm
//   By Fermat's little theorem in GF(2^m):   a^(2^m - 1) = 1, so
//
//        a^(-1) = a^(2^m - 2) = ( a^(2^(m-1) - 1) )^2 ,     m = 283
//
//   Define the Itoh-Tsujii quantity
//
//        B_n = a^(2^n - 1)          (so B_1 = a, and a^(-1) = (B_282)^2)
//
//   which obeys the composition rule
//
//        B_(p+q) = ( B_p )^(2^q) * B_q                                    (*)
//
//   Each application of (*) costs q squarings plus ONE field multiplication, so
//   the whole inversion needs only len(chain) multiplications instead of the 282
//   a general square-and-multiply ladder would need.
//
// Addition chain for m-1 = 282
//   282 = 2 * 141,  141 = 3 * 47.  We use the chain
//
//        1 -> 2 -> 4 -> 8 -> 16 -> 17 -> 34 -> 35 -> 70 -> 140 -> 141 -> 282
//
//   giving 11 multiplications and 1+2+4+8+1+17+1+35+70+1+141 = 281 squarings,
//   plus 1 final squaring -> 282 squarings, 11 multiplications total.
//
//   step | rule                                | squarings | multiply by
//   -----+-------------------------------------+-----------+-------------
//     1  | B_2   = (B_1)^(2^1)   * B_1         |     1     | acc
//     2  | B_4   = (B_2)^(2^2)   * B_2         |     2     | acc
//     3  | B_8   = (B_4)^(2^4)   * B_4         |     4     | acc
//     4  | B_16  = (B_8)^(2^8)   * B_8         |     8     | acc
//     5  | B_17  = (B_16)^(2^1)  * B_1         |     1     | a
//     6  | B_34  = (B_17)^(2^17) * B_17        |    17     | acc
//     7  | B_35  = (B_34)^(2^1)  * B_1         |     1     | a
//     8  | B_70  = (B_35)^(2^35) * B_35        |    35     | acc
//     9  | B_140 = (B_70)^(2^70) * B_70        |    70     | acc
//    10  | B_141 = (B_140)^(2^1) * B_1         |     1     | a
//    11  | B_282 = (B_141)^(2^141) * B_141     |   141     | acc
//    12  | a^-1  = (B_282)^2                   |     1     | (none)
//
//   `acc` holds the current B_n; `B_1 = a` is latched at start so the caller
//   need not hold the input stable for the whole operation.
//
// Multiplier interface
//   This module does NOT instantiate a multiplier. It drives an external one
//   through a request/acknowledge port so that the system top level can share a
//   single (large) Karatsuba multiplier between inversion and plain field
//   multiplication. See gf283_inverse.v for a self-contained wrapper.
//
// Latency     : ~ (282/SQ_CASCADE) + 12*3 + 11*3 + overhead clock cycles.
//               With SQ_CASCADE = 4 this is roughly 190 cycles.
//////////////////////////////////////////////////////////////////////////////////

module gf283_itoh_tsujii #(
    parameter integer M          = 283,
    parameter integer SQ_CASCADE = 4    // squarings per cycle in the squarer
)(
    input  wire            clk,
    input  wire            rst_n,

    // ---- control ----------------------------------------------------------
    input  wire            start,       // 1-cycle strobe
    input  wire [M-1:0]    a,           // element to invert (must be non-zero)
    output reg  [M-1:0]    inv,         // a^-1, valid when done == 1
    output reg             done,        // 1-cycle strobe
    output wire            busy,
    output reg             err_zero,    // set with done if a == 0 (undefined op)

    // ---- external multiplier port (c = ma * mb mod f) ---------------------
    output reg             mul_req,     // 1-cycle strobe to the multiplier
    output wire [M-1:0]    mul_a,
    output wire [M-1:0]    mul_b,
    input  wire            mul_done,    // 1-cycle strobe from the multiplier
    input  wire [M-1:0]    mul_c
);

    localparam integer NSTEPS = 12;     // last step is the final squaring

    localparam [2:0] S_IDLE     = 3'd0,
                     S_SQ_GO    = 3'd1,
                     S_SQ_WAIT  = 3'd2,
                     S_MUL_WAIT = 3'd3,
                     S_DONE     = 3'd4;

    reg [2:0]   state;
    reg [3:0]   step;                   // 1 .. NSTEPS
    reg [M-1:0] acc;                    // current B_n
    reg [M-1:0] a_hold;                 // latched copy of B_1 = a

    // ---- squaring unit ----------------------------------------------------
    reg          sq_start;
    reg  [8:0]   sq_k;
    wire         sq_done;
    wire [M-1:0] sq_r;

    gf283_sqr_pow2k #(.M(M), .CASCADE(SQ_CASCADE)) u_sqr (
        .clk   (clk),
        .rst_n (rst_n),
        .start (sq_start),
        .a     (acc),
        .k     (sq_k),
        .r     (sq_r),
        .done  (sq_done)
    );

    // ---- addition-chain schedule: squaring count per step -----------------
    always @(*) begin
        case (step)
            4'd1  : sq_k = 9'd1;
            4'd2  : sq_k = 9'd2;
            4'd3  : sq_k = 9'd4;
            4'd4  : sq_k = 9'd8;
            4'd5  : sq_k = 9'd1;
            4'd6  : sq_k = 9'd17;
            4'd7  : sq_k = 9'd1;
            4'd8  : sq_k = 9'd35;
            4'd9  : sq_k = 9'd70;
            4'd10 : sq_k = 9'd1;
            4'd11 : sq_k = 9'd141;
            4'd12 : sq_k = 9'd1;        // final squaring, no multiply follows
            default: sq_k = 9'd0;
        endcase
    end

    // ---- addition-chain schedule: multiplier operand ----------------------
    // Steps 5, 7 and 10 fold in B_1 = a; every other step folds in the
    // accumulator itself (B_p * (B_p)^(2^p) style doubling of the chain index).
    wire use_a = (step == 4'd5) || (step == 4'd7) || (step == 4'd10);

    assign mul_a = sq_r;                        // (B_p)^(2^q), from the squarer
    assign mul_b = use_a ? a_hold : acc;        // B_q
    assign busy  = (state != S_IDLE);

    // ---- control FSM ------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            step     <= 4'd0;
            acc      <= {M{1'b0}};
            a_hold   <= {M{1'b0}};
            inv      <= {M{1'b0}};
            done     <= 1'b0;
            err_zero <= 1'b0;
            sq_start <= 1'b0;
            mul_req  <= 1'b0;
        end else begin
            done     <= 1'b0;           // defaults: all strobes are 1 cycle
            sq_start <= 1'b0;
            mul_req  <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        acc      <= a;
                        a_hold   <= a;
                        err_zero <= (a == {M{1'b0}});
                        step     <= 4'd1;
                        state    <= S_SQ_GO;
                    end
                end

                // Kick off a^(2^sq_k) on the current accumulator.
                S_SQ_GO: begin
                    sq_start <= 1'b1;
                    state    <= S_SQ_WAIT;
                end

                S_SQ_WAIT: begin
                    if (sq_done) begin
                        if (step == NSTEPS[3:0]) begin
                            // Final step: a^-1 = (B_282)^2, no multiply needed.
                            state <= S_DONE;
                        end else begin
                            mul_req <= 1'b1;
                            state   <= S_MUL_WAIT;
                        end
                    end
                end

                S_MUL_WAIT: begin
                    if (mul_done) begin
                        acc   <= mul_c;
                        step  <= step + 4'd1;
                        state <= S_SQ_GO;
                    end
                end

                S_DONE: begin
                    inv   <= sq_r;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
