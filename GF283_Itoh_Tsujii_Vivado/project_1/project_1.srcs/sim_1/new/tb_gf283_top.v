`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench   : tb_gf283_top          *** POST-IMPLEMENTATION SIMULATION TB ***
// Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
//
// Drives ONLY the top-level ports of gf283_top, so the exact same testbench runs
// against behavioural RTL, the post-synthesis netlist and the post-implementation
// (timing-annotated) netlist. No hierarchical references, no force/release.
//
// Timing-simulation hygiene
//   * stimulus is applied on the FALLING clock edge  -> half a period of setup
//   * outputs are sampled on the FALLING clock edge  -> half a period for all
//     SDF-annotated delays to settle before we look
//   * reset is held asserted for several clock periods so the netlist leaves its
//     unknown power-up state before any transaction starts
//
// Checking strategy (three independent layers)
//   1. GOLDEN VECTORS computed offline in Python with an independent GF(2^283)
//      model (bit-serial clmul + long-division reduction, cross-checked against
//      a second Itoh-Tsujii implementation).
//   2. A behavioural reference model inside this file, written with a DIFFERENT
//      algorithm from the RTL (long division rather than the RTL's two-pass
//      fold), used for randomised multiply tests.
//   3. The mathematical identity  a * a^-1 == 1  for random a, which needs no
//      precomputed answer at all.
//////////////////////////////////////////////////////////////////////////////////

module tb_gf283_top;

    // ---------------------------------------------------------------------
    // Parameters (must match the DUT)
    // ---------------------------------------------------------------------
    localparam integer M   = 283;
    localparam integer W   = 32;
    localparam integer NW  = (M + W - 1) / W;   // 9 words
    localparam integer SRW = NW * W;            // 288 bits

    localparam OP_MUL = 1'b0;
    localparam OP_INV = 1'b1;

    // Clock period. Keep >= the period the design was implemented at, otherwise
    // post-implementation timing simulation will (correctly) report violations.
    localparam real CLK_PERIOD = 20.0;

    // ---------------------------------------------------------------------
    // DUT connections
    // ---------------------------------------------------------------------
    reg              clk = 1'b0;
    reg              rst_n = 1'b0;
    reg              start = 1'b0;
    reg              op = 1'b0;
    reg              in_valid = 1'b0;
    reg  [W-1:0]     in_word = {W{1'b0}};
    wire             in_ready;
    wire             out_valid;
    wire [W-1:0]     out_word;
    reg              out_ready = 1'b0;
    wire             busy;
    wire             done;
    wire             err_zero;

    gf283_top #(.M(M), .W(W)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .op        (op),
        .in_valid  (in_valid),
        .in_word   (in_word),
        .in_ready  (in_ready),
        .out_valid (out_valid),
        .out_word  (out_word),
        .out_ready (out_ready),
        .busy      (busy),
        .done      (done),
        .err_zero  (err_zero)
    );

    always #(CLK_PERIOD/2.0) clk = ~clk;

    // ---------------------------------------------------------------------
    // Behavioural reference model
    // Deliberately uses bit-serial long division, i.e. a different algorithm
    // from the RTL's two-pass fold, so a shared conceptual bug is unlikely.
    // ---------------------------------------------------------------------
    function [M-1:0] ref_reduce;
        input [2*M-2:0] p;
        reg   [2*M-2:0] t;
        integer k;
        begin
            t = p;
            for (k = 2*M-2; k >= M; k = k - 1) begin
                if (t[k]) begin
                    // x^k == x^(k-283) * (x^12 + x^7 + x^5 + 1)
                    t[k]          = 1'b0;
                    t[k-M]        = t[k-M]        ^ 1'b1;
                    t[k-M+5]      = t[k-M+5]      ^ 1'b1;
                    t[k-M+7]      = t[k-M+7]      ^ 1'b1;
                    t[k-M+12]     = t[k-M+12]     ^ 1'b1;
                end
            end
            ref_reduce = t[M-1:0];
        end
    endfunction

    function [M-1:0] ref_mul;
        input [M-1:0] x;
        input [M-1:0] y;
        reg   [2*M-2:0] p;
        reg   [2*M-2:0] xe;
        integer i;
        begin
            p  = {(2*M-1){1'b0}};
            xe = {{(M-1){1'b0}}, x};
            for (i = 0; i < M; i = i + 1) begin
                if (y[i]) p = p ^ (xe << i);
            end
            ref_mul = ref_reduce(p);
        end
    endfunction

    function [M-1:0] rnd283;
        input dummy;
        begin
            rnd283 = {$random, $random, $random, $random, $random,
                      $random, $random, $random, $random} & {M{1'b1}};
        end
    endfunction

    // ---------------------------------------------------------------------
    // Bus-level driver tasks
    //
    // I/O TIMING CONTRACT (must agree with gf283_top.xdc)
    //   Inputs  are launched  T_DRIVE  after a rising edge, so the design has
    //           CLK_PERIOD - T_DRIVE  to propagate them to their capture flop.
    //           This mirrors  set_input_delay  T_DRIVE.
    //   Outputs are sampled   T_SAMPLE after a rising edge, so the design has
    //           T_SAMPLE  of clock-to-out budget and the value is read well
    //           before the next edge changes it.
    //           This mirrors  set_output_delay (CLK_PERIOD - T_SAMPLE).
    //
    // Sampling on the falling edge instead (the obvious first instinct) gives
    // inputs only half a period. That is NOT enough here: the high-fan-out
    // enables in_valid and out_ready feed all 288 shift-register flops and
    // route in ~11.4 ns and ~10.4 ns respectively. Under the old scheme
    // out_ready reached the sh[0] flop late, that bit missed its shift, and
    // post-implementation simulation reported wrong data in bit 0 of every
    // output word - while behavioural simulation, having no delays, passed.
    // ---------------------------------------------------------------------
    localparam real T_DRIVE  = CLK_PERIOD * 0.20;   //  4 ns of the 20 ns period
    localparam real T_SAMPLE = CLK_PERIOD * 0.80;   // 16 ns of the 20 ns period

    integer errors = 0;
    integer checks = 0;

    // Advance to this cycle's input-launch instant / output-sample instant.
    task drive_point;  begin @(posedge clk); #(T_DRIVE);  end endtask
    task sample_point; begin @(posedge clk); #(T_SAMPLE); end endtask

    task send_operand;
        input [M-1:0] v;
        reg   [SRW-1:0] pad;
        integer w;
        begin
            pad = {{(SRW-M){1'b0}}, v};

            // Poll in_ready at the safe sample instant.
            sample_point;
            while (in_ready !== 1'b1) sample_point;

            // in_ready stays high for the whole NW-word burst, so the words can
            // be launched back to back, one per cycle.
            for (w = 0; w < NW; w = w + 1) begin
                drive_point;
                in_valid = 1'b1;
                in_word  = pad[w*W +: W];       // least-significant word first
            end

            drive_point;
            in_valid = 1'b0;
            in_word  = {W{1'b0}};
        end
    endtask

    task recv_result;
        output [M-1:0] v;
        reg    [SRW-1:0] acc;
        integer w;
        begin
            acc = {SRW{1'b0}};

            drive_point;
            out_ready = 1'b1;

            sample_point;
            while (out_valid !== 1'b1) sample_point;

            // out_word now presents word 0; each further rising edge shifts.
            for (w = 0; w < NW; w = w + 1) begin
                acc[w*W +: W] = out_word;       // least-significant word first
                if (w < NW-1) sample_point;
            end

            drive_point;
            out_ready = 1'b0;
            v = acc[M-1:0];
        end
    endtask

    task issue;
        input which_op;
        begin
            drive_point;
            op    = which_op;
            start = 1'b1;
            drive_point;
            start = 1'b0;
        end
    endtask

    // Full multiply transaction: c = a*b
    task do_mul;
        input  [M-1:0] a;
        input  [M-1:0] b;
        output [M-1:0] c;
        begin
            issue(OP_MUL);
            send_operand(a);
            send_operand(b);
            recv_result(c);
        end
    endtask

    // Full inversion transaction: d = a^-1
    task do_inv;
        input  [M-1:0] a;
        output [M-1:0] d;
        begin
            issue(OP_INV);
            send_operand(a);
            recv_result(d);
        end
    endtask

    task check;
        input [1023:0] label;
        input [M-1:0]  got;
        input [M-1:0]  exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %0s", label);
                $display("        expected = %h", exp);
                $display("        got      = %h", got);
            end else begin
                $display("[ PASS] %0s", label);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Golden vectors (generated by the independent Python model)
    // ---------------------------------------------------------------------
    localparam integer N_MUL_VEC = 12;
    localparam integer N_INV_VEC = 12;

    reg [M-1:0] MA [0:N_MUL_VEC-1];
    reg [M-1:0] MB [0:N_MUL_VEC-1];
    reg [M-1:0] MC [0:N_MUL_VEC-1];
    reg [M-1:0] IA [0:N_INV_VEC-1];
    reg [M-1:0] IC [0:N_INV_VEC-1];

    task load_vectors;
        begin
            MA[0]=283'h00000000000000000000000000000000000000000000000000000000000000000000001;
            MB[0]=283'h00000000000000000000000000000000000000000000000000000000000000000000001;
            MC[0]=283'h00000000000000000000000000000000000000000000000000000000000000000000001;

            MA[1]=283'h00000000000000000000000000000000000000000000000000000000000000000000002;
            MB[1]=283'h00000000000000000000000000000000000000000000000000000000000000000000002;
            MC[1]=283'h00000000000000000000000000000000000000000000000000000000000000000000004;

            MA[2]=283'h00000000000000000000000000000000000000000000000000000000000000000000003;
            MB[2]=283'h00000000000000000000000000000000000000000000000000000000000000000000005;
            MC[2]=283'h0000000000000000000000000000000000000000000000000000000000000000000000f;

            // x^282 * x^282 : maximum-degree product, exercises the reducer hard
            MA[3]=283'h40000000000000000000000000000000000000000000000000000000000000000000000;
            MB[3]=283'h40000000000000000000000000000000000000000000000000000000000000000000000;
            MC[3]=283'h20000000000000000000000000000000000000000000000000000000000000000401528;

            // all-ones squared : every Karatsuba XOR path toggles
            MA[4]=283'h7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
            MB[4]=283'h7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
            MC[4]=283'h55555555555555555555555555555555555555555555555555555555555555555001eea;

            MA[5]=283'h00000000000000000000000000000000000000000000000000000001234567890abcdef;
            MB[5]=283'h0000000000000000000000000000000000000000000000000000000fedcba0987654321;
            MC[5]=283'h0000000000000000000000000000000000000000e038d8eab3af47a1f31f87ebb8c810f;

            MA[6]=283'h7457ba0b5421d84d6b053f0ab8cb7acd48fc9cf26988d2154c87241140f105b297bb1e1;
            MB[6]=283'h615ad1f9737f2e7b7a6fc5ac158e75c7cce725ac804075cab61ac363e5b8d26f9be2c11;
            MC[6]=283'h34562da9d595b06a39ea75489407a7d18884f695812a1ead81d3eed54bb307d1f6d1288;

            MA[7]=283'h1a31e84f06241a06d3322f2d25fa12f671ed2486737e53c05e9f652773fbfd4ba943a6e;
            MB[7]=283'h7e4ce9d0bad4597362139822743356bf6b5258701c1be840a19d8f8a430371d11e1ad41;
            MC[7]=283'h78118490857c7d9a0369ed7b0f28f487f52016357d781c583829a44363c9fad11225ee0;

            MA[8]=283'h74fc8ea569a724f26307acdad925353e1f3c5ce77831a190f7205a84c0f31e4c5a3c633;
            MB[8]=283'h58d2c67df14a7d5c19736a0277b34d5c6c529dcc94d6ade11550f3fc9d90594f03a0ef6;
            MC[8]=283'h0e3e11925fb41afdfdc8ea39b2f93bad6550b06b0776ea32662085df204c41fe2af49cb;

            MA[9]=283'h230ef283f9de095f0222e010b4412a6959efbbff9c1b4032d1573e895cd437a043a831d;
            MB[9]=283'h7e0af20caa0b7be794d77557c0640e6f00f8c82ce7d3cf0a8ecbb33f2ad22bd9c3f696e;
            MC[9]=283'h6042dceadeb6c3cdfa2331fec967588f68073e8069a10dbb345aa55c51e536b0ac7e4b2;

            MA[10]=283'h5d664c15778c9865af2658fba89b13b83d21b24bc7475627477ceeaaea808cc3e1e8cd5;
            MB[10]=283'h2fcb0686d81be353fa7fa34140c95c5d2bae823e58412a642495045806a7bba796fe00a;
            MC[10]=283'h505d2b2d3b10c45b8e3b25e33067ff00c388ab956973398828c05fe35b2c9dd03e87363;

            MA[11]=283'h295e3357245a7227b1d107ccba47715b0e5b8e28130de68ef608634fb36febbda6ebcfc;
            MB[11]=283'h78fbe27668bb19519b8e7bc8eca7e803fd55b862c9bce5459a9ff1eaa2f922dbdf4ac3b;
            MC[11]=283'h4e88679df41a96eb46397c10ce98669df2658fcffba8579365737ec794533a48436568d;

            IA[0]=283'h00000000000000000000000000000000000000000000000000000000000000000000001;
            IC[0]=283'h00000000000000000000000000000000000000000000000000000000000000000000001;

            IA[1]=283'h00000000000000000000000000000000000000000000000000000000000000000000002;
            IC[1]=283'h40000000000000000000000000000000000000000000000000000000000000000000850;

            IA[2]=283'h00000000000000000000000000000000000000000000000000000000000000000000003;
            IC[2]=283'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff060;

            IA[3]=283'h00000000000000000000000000000000000000000000000000000000000000000000005;
            IC[3]=283'h55555555555555555555555555555555555555555555555555555555555555555555fbf;

            IA[4]=283'h00000000000000000000000000000000000000000000000000000000000000000000009;
            IC[4]=283'h24924924924924924924924924924924924924924924924924924924924924924924d9b;

            IA[5]=283'h40000000000000000000000000000000000000000000000000000000000000000000000;
            IC[5]=283'h200214ad7bffbd6a50800852b5effef5a94200214ad7bffbd6a50800852b5effef5ad6a;

            IA[6]=283'h7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
            IC[6]=283'h2667f063d9793baa04291ae2d33f831ecbc9dd502148d71699fc18f65e4eea810a46f68;

            IA[7]=283'h680581dd50c14a1a969bc727489bebda6db08bd03c7759ca86f09264ad9ee8954337044;
            IC[7]=283'h44f01f1cc5b484d10b52f8a1101f93b10c0022d26dd1915c8a2c7dcdc56ed49a51f81ad;

            IA[8]=283'h1806785487521299c881ec0c0d6dcec797bdde0a89735c2bb73c2b3766b7893ab6851ed;
            IC[8]=283'h74b1a18f27d785bb645253d40835285a3e4bf14cf6caa4482ae9563399f676d4a107b84;

            IA[9]=283'h6bb30c57fd4be4c513d71575954cc1aa96433490ed58994d225f7d649beb4018fda5dba;
            IC[9]=283'h05240c6b6ca3825e3334dbf6104225ee62b38f84174940c34acf5ce2b6f2897646fa8ec;

            IA[10]=283'h190597abbcc6450a8a057f99b552b50a5b39a4a64208139ed636b4ee1d7fa32bbe990c6;
            IC[10]=283'h7f34e20d82e6224e504ad0164fafec3eac80ebeb83f5d1dfc9346d978033735f51a4d65;

            IA[11]=283'h7daf74cad7eed0680cd26136d3d3d3aed26a188ed414c2e2a74806915e52c79f0f5970d;
            IC[11]=283'h7d09de49e5661f75717ab0fdeb0bf3addd396eb824267b77daabf35676bb8e94246a388;
        end
    endtask

    // ---------------------------------------------------------------------
    // Main stimulus
    // ---------------------------------------------------------------------
    integer      t;
    integer      n_mul, n_inv, n_rnd;
    reg [M-1:0]  got, a_rnd, b_rnd, inv_rnd, prod;
    reg [1023:0] lbl;

    initial begin
        load_vectors();

        // Post-implementation timing simulation is slow; +SHORT trims the run
        // to a representative subset while still covering both operations.
        if ($test$plusargs("SHORT")) begin
            n_mul = 4; n_inv = 3; n_rnd = 2;
        end else begin
            n_mul = N_MUL_VEC; n_inv = N_INV_VEC; n_rnd = 5;
        end

        $display("");
        $display("==========================================================");
        $display(" GF(2^283) top-level testbench");
        $display(" f(x) = x^283 + x^12 + x^7 + x^5 + 1");
        $display(" streaming width W = %0d, %0d words per operand", W, NW);
        $display("==========================================================");

        // Hold reset long enough for the implemented netlist to settle, then
        // release it at the input-launch instant. rst_n is a declared false
        // path with ~17 ns of routing skew across its 4032 loads, so several
        // idle cycles follow the release before the first transaction starts.
        rst_n = 1'b0;
        repeat (8) drive_point;
        rst_n = 1'b1;
        repeat (6) drive_point;

        // ---- 1. multiplication against golden vectors --------------------
        $display("\n---- Multiplication: golden vectors ----");
        for (t = 0; t < n_mul; t = t + 1) begin
            do_mul(MA[t], MB[t], got);
            $sformat(lbl, "MUL vector %0d", t);
            check(lbl, got, MC[t]);
        end

        // ---- 2. inversion against golden vectors -------------------------
        $display("\n---- Inversion: golden vectors ----");
        for (t = 0; t < n_inv; t = t + 1) begin
            do_inv(IA[t], got);
            $sformat(lbl, "INV vector %0d", t);
            check(lbl, got, IC[t]);
        end

        // ---- 3. randomised multiply vs. in-testbench reference model -----
        $display("\n---- Multiplication: random vs reference model ----");
        for (t = 0; t < n_rnd; t = t + 1) begin
            a_rnd = rnd283(0);
            b_rnd = rnd283(0);
            do_mul(a_rnd, b_rnd, got);
            $sformat(lbl, "MUL random %0d", t);
            check(lbl, got, ref_mul(a_rnd, b_rnd));
        end

        // ---- 4. randomised inversion via the identity a * a^-1 == 1 ------
        $display("\n---- Inversion: random, checked by a * a^-1 == 1 ----");
        for (t = 0; t < n_rnd; t = t + 1) begin
            a_rnd = rnd283(0);
            if (a_rnd == {M{1'b0}}) a_rnd = {{(M-1){1'b0}}, 1'b1};
            do_inv(a_rnd, inv_rnd);
            do_mul(a_rnd, inv_rnd, prod);
            $sformat(lbl, "INV random %0d  (a * a^-1)", t);
            check(lbl, prod, {{(M-1){1'b0}}, 1'b1});
        end

        // ---- 5. inversion of zero must raise err_zero --------------------
        $display("\n---- Corner case: inversion of zero ----");
        do_inv({M{1'b0}}, got);
        checks = checks + 1;
        if (err_zero !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] err_zero not asserted for a = 0");
        end else begin
            $display("[ PASS] err_zero asserted for a = 0");
        end

        // ---- summary ------------------------------------------------------
        repeat (4) sample_point;
        $display("");
        $display("==========================================================");
        $display(" checks run : %0d", checks);
        $display(" failures   : %0d", errors);
        if (errors == 0)
            $display(" RESULT     : *** ALL TESTS PASSED ***");
        else
            $display(" RESULT     : *** %0d TEST(S) FAILED ***", errors);
        $display("==========================================================");
        $display("");
        $finish;
    end

    // Watchdog. The full vector set takes about 4 300 clocks; 40 000 leaves an
    // order of magnitude of headroom while still failing fast at gate level,
    // where every simulated cycle is expensive.
    initial begin
        #(CLK_PERIOD * 40000);
        $display("[FATAL] testbench watchdog expired - DUT appears hung");
        $display(" RESULT     : *** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
