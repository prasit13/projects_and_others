`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module      : gf283_top          *** SYNTHESIS TOP LEVEL ***
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Function    : System wrapper exposing both mandated field operations over a
//               narrow, pin-friendly streaming interface:
//
//                   op = OP_MUL (0):   C <- A * B    in GF(2^283)
//                   op = OP_INV (1):   D <- A^-1     in GF(2^283)
//
// WHY A STREAMING INTERFACE
//   A 283-bit-wide parallel interface needs 283*2 + 283 + control > 500 device
//   pins. The target xc7a100tcsg324 has only 210 user I/O, so synthesising a
//   wide-port module directly fails implementation with
//
//       [Place 30-415] IO Placement failed due to overutilization. This design
//       contains 570 I/O ports while the target device ... contains only 210
//       available user I/O.
//
//   Operands and results are therefore streamed as NW = ceil(283/W) words of W
//   bits, least-significant word first. With the default W = 32 the whole top
//   level uses 75 pins, which fits comfortably.
//
// RESOURCE SHARING
//   The 283-bit Karatsuba multiplier is the dominant cost of the design
//   (~90% of the LUTs). Rather than instantiate one for the OP_MUL datapath
//   and another inside the inverter, a SINGLE gf283_mul_pipe is instantiated
//   here and multiplexed between:
//       - the OP_MUL datapath  (operands opa/opb), and
//       - the Itoh-Tsujii controller's request port.
//   This is why gf283_itoh_tsujii takes an external multiplier port and why the
//   self-contained gf283_inverse wrapper is used only by its testbench.
//
// PROTOCOL
//   1. Pulse `start` for one cycle together with the desired `op`.
//   2. Feed operand words while `in_ready` is high, asserting `in_valid`:
//         OP_MUL : NW words of A, then NW words of B
//         OP_INV : NW words of A
//      Word 0 carries bits [W-1:0]; the top (NW*W - 283) bits of the last word
//      are ignored.
//   3. The core computes (a few cycles for OP_MUL, ~190 for OP_INV).
//   4. Result words appear with `out_valid`; consume them with `out_ready`,
//      least-significant word first.
//   5. `done` pulses for one cycle after the final word is accepted.
//      `err_zero` flags an attempted inversion of 0 (mathematically undefined);
//      it is valid alongside `done`.
//
// Module hierarchy
//   gf283_top
//    +- gf283_mul_pipe            shared 3-stage field multiplier
//    |   +- ks283                 Karatsuba tree (see ks283.v)
//    |   +- gf283_reduce          mod f(x)
//    +- gf283_itoh_tsujii         inversion controller
//        +- gf283_sqr_pow2k       a^(2^k) engine
//            +- gf283_square xN   Frobenius cascade
//                +- gf283_reduce
//////////////////////////////////////////////////////////////////////////////////

module gf283_top #(
    parameter integer M          = 283, // field degree
    parameter integer W          = 32,  // streaming word width
    parameter integer SQ_CASCADE = 4    // squarings per cycle inside the squarer
)(
    input  wire            clk,
    input  wire            rst_n,       // active-low asynchronous reset

    // ---- command ---------------------------------------------------------
    input  wire            start,       // 1-cycle strobe, latches `op`
    input  wire            op,          // 0 = multiply, 1 = invert

    // ---- operand input stream (LSW first) --------------------------------
    input  wire            in_valid,
    input  wire [W-1:0]    in_word,
    output wire            in_ready,

    // ---- result output stream (LSW first) --------------------------------
    output wire            out_valid,
    output wire [W-1:0]    out_word,
    input  wire            out_ready,

    // ---- status ----------------------------------------------------------
    output wire            busy,
    output reg             done,        // 1-cycle strobe
    output reg             err_zero     // inversion of zero was requested
);

    localparam OP_MUL = 1'b0;
    localparam OP_INV = 1'b1;

    // Words per operand and the padded shift-register width
    localparam integer NW  = (M + W - 1) / W;   // 9 words for M=283, W=32
    localparam integer SRW = NW * W;            // 288 bits

    localparam [2:0] S_IDLE   = 3'd0,
                     S_LOAD_A = 3'd1,
                     S_LOAD_B = 3'd2,
                     S_GO     = 3'd3,
                     S_EXEC   = 3'd4,
                     S_PREP   = 3'd5,
                     S_UNLOAD = 3'd6,
                     S_DONE   = 3'd7;

    reg [2:0]     state;
    reg [7:0]     cnt;                  // word counter (0 .. NW-1)
    reg           op_r;                 // latched operation
    reg [SRW-1:0] sh;                   // load/unload shift register
    reg [M-1:0]   opa, opb;             // captured operands
    reg [M-1:0]   res;                  // captured result

    // Next shift-register value while loading: new word enters at the top,
    // so after NW pushes the FIRST word has travelled down to bits [W-1:0].
    wire [SRW-1:0] sh_load_next = {in_word, sh[SRW-1:W]};

    // ---------------------------------------------------------------------
    // Shared field multiplier and the inversion controller
    // ---------------------------------------------------------------------
    reg            mul_req_top;         // OP_MUL datapath request
    wire           mul_start;
    wire [M-1:0]   mul_a, mul_b, mul_c;
    wire           mul_done;

    reg            it_start;
    wire           it_done, it_busy, it_err;
    wire [M-1:0]   it_inv;
    wire           it_mul_req;
    wire [M-1:0]   it_mul_a, it_mul_b;

    // Multiplier arbitration: the inverter owns the multiplier for the whole
    // OP_INV operation; otherwise the OP_MUL datapath drives it.
    wire sel_inv = (op_r == OP_INV);

    assign mul_start = sel_inv ? it_mul_req : mul_req_top;
    assign mul_a     = sel_inv ? it_mul_a   : opa;
    assign mul_b     = sel_inv ? it_mul_b   : opb;

    gf283_mul_pipe #(.M(M)) u_mul (
        .clk   (clk),
        .rst_n (rst_n),
        .start (mul_start),
        .a     (mul_a),
        .b     (mul_b),
        .c     (mul_c),
        .done  (mul_done)
    );

    gf283_itoh_tsujii #(.M(M), .SQ_CASCADE(SQ_CASCADE)) u_inv (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (it_start),
        .a        (opa),
        .inv      (it_inv),
        .done     (it_done),
        .busy     (it_busy),
        .err_zero (it_err),
        .mul_req  (it_mul_req),
        .mul_a    (it_mul_a),
        .mul_b    (it_mul_b),
        .mul_done (mul_done),           // ignored by the controller when idle
        .mul_c    (mul_c)
    );

    // ---------------------------------------------------------------------
    // Stream handshakes
    // ---------------------------------------------------------------------
    assign in_ready  = (state == S_LOAD_A) || (state == S_LOAD_B);
    assign out_valid = (state == S_UNLOAD);
    assign out_word  = sh[W-1:0];
    assign busy      = (state != S_IDLE);

    // ---------------------------------------------------------------------
    // Main sequencer
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            cnt         <= 8'd0;
            op_r        <= OP_MUL;
            sh          <= {SRW{1'b0}};
            opa         <= {M{1'b0}};
            opb         <= {M{1'b0}};
            res         <= {M{1'b0}};
            done        <= 1'b0;
            err_zero    <= 1'b0;
            mul_req_top <= 1'b0;
            it_start    <= 1'b0;
        end else begin
            done        <= 1'b0;        // defaults: single-cycle strobes
            mul_req_top <= 1'b0;
            it_start    <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        op_r     <= op;
                        cnt      <= 8'd0;
                        err_zero <= 1'b0;
                        state    <= S_LOAD_A;
                    end
                end

                // ---- stream in operand A ---------------------------------
                S_LOAD_A: begin
                    if (in_valid) begin
                        sh <= sh_load_next;
                        if (cnt == NW-1) begin
                            opa   <= sh_load_next[M-1:0];
                            cnt   <= 8'd0;
                            state <= (op_r == OP_MUL) ? S_LOAD_B : S_GO;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                end

                // ---- stream in operand B (multiply only) -----------------
                S_LOAD_B: begin
                    if (in_valid) begin
                        sh <= sh_load_next;
                        if (cnt == NW-1) begin
                            opb   <= sh_load_next[M-1:0];
                            cnt   <= 8'd0;
                            state <= S_GO;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                end

                // ---- launch the selected operation -----------------------
                S_GO: begin
                    if (op_r == OP_INV) it_start    <= 1'b1;
                    else                mul_req_top <= 1'b1;
                    state <= S_EXEC;
                end

                // ---- wait for the datapath -------------------------------
                S_EXEC: begin
                    if (op_r == OP_INV) begin
                        if (it_done) begin
                            res      <= it_inv;
                            err_zero <= it_err;
                            state    <= S_PREP;
                        end
                    end else begin
                        if (mul_done) begin
                            res   <= mul_c;
                            state <= S_PREP;
                        end
                    end
                end

                // ---- preload the shift register with the result ----------
                S_PREP: begin
                    sh    <= {{(SRW-M){1'b0}}, res};
                    cnt   <= 8'd0;
                    state <= S_UNLOAD;
                end

                // ---- stream out the result -------------------------------
                S_UNLOAD: begin
                    if (out_ready) begin
                        sh <= {{W{1'b0}}, sh[SRW-1:W]};
                        if (cnt == NW-1) begin
                            cnt   <= 8'd0;
                            state <= S_DONE;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule

