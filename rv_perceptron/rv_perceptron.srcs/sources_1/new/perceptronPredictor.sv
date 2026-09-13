`include "bp_config.vh"

//==========================================================================
// perceptronPredictor
//
// Confidence-gated hybrid perceptron branch predictor, organised as a
// two-level overriding predictor.
//
// Baseline is the Jimenez & Lin perceptron (HPCA-7, 2001):
//
//     y = w[0] + SUM(i=1..H) x[i] * w[i]      x[i] in {-1,+1}
//     predict taken  <=>  y >= 0
//     train if mispredicted or |y| <= theta:
//         w[i] += t * x[i],  t = +1 if taken else -1
//
// Four additions over that baseline:
//
//  N1  SPECULATIVE GLOBAL HISTORY WITH EXACT REPAIR.
//      The history feeding the perceptron is updated at FETCH, the moment a
//      prediction is made, not at EXECUTE when the branch resolves. A second
//      architectural history register tracks resolved outcomes and restores
//      the speculative copy on a misprediction. Without this the history is
//      two pipeline stages stale, so a loop whose body is shorter than the
//      F->E distance never sees its own previous iteration -- which destroys
//      exactly the correlation the perceptron exists to exploit. The history
//      vector in use at prediction time rides the pipeline down to EX
//      (bpBus F -> D -> E) so training uses the same inputs the prediction
//      was computed from.
//
//  N2  ADAPTIVE TRAINING THRESHOLD (Seznec-style).
//      theta is not the fixed 1.93*H+14 of the original paper. A saturating
//      counter raises theta when mispredictions accumulate and lowers it when
//      the predictor is correct but under-trained.
//
//  N3  CONFIDENCE-GATED HYBRID SELECTION.
//      |y| is a free confidence estimate. The vote is handed to the BTB's
//      2-bit counter only when the perceptron is essentially tied
//      (|y| <= CONF_GATE) AND that counter is strongly biased.
//
//  N4  TWO-LEVEL OVERRIDING ORGANISATION  (BP_OVERRIDE=1, the default).
//      The reason this matters is timing, and it is measured, not assumed.
//      With the perceptron in the fetch path directly, Vivado's critical path
//      on an xc7a35t is a single-cycle loop
//          pc -> weight-table read -> adder tree -> |y| vs theta -> next-PC
//          mux -> pc
//      at 17.6 ns, capping the core at 56 MHz against 91 MHz with no
//      predictor at all. The perceptron then wins on cycles and loses on
//      wall-clock time, which makes it pointless.
//
//      So the work is split. The BTB's 2-bit counter is a fast predictor --
//      a narrow table read and a bit test -- and it steers fetch in the same
//      cycle. The perceptron is the slow, accurate predictor: its dot product
//      is cut in half by a pipeline register inside the adder tree
//      (BP_PIPE_LEVEL) and its verdict lands one cycle later, while the
//      instruction is in DECODE. If it disagrees with the fast prediction it
//      redirects fetch and rewrites the recorded prediction, costing one
//      bubble rather than the two-to-three cycle flush of an EX-stage
//      misprediction.
//
//      Neither half of the split path now contains both the table read and
//      the whole tree, which is what removes the frequency penalty.
//==========================================================================

module perceptronPredictor #(
    parameter int BTB_ENTRIES   = `BP_BTB_ENTRIES,
    parameter int HIST          = `BP_HIST,
    parameter int INDEX_BITS    = `BP_INDEX_BITS,
    parameter int W_BITS        = `BP_W_BITS,
    parameter int CONF_GATE     = `BP_CONF_GATE,
    parameter int OVERRIDE      = `BP_OVERRIDE,
    parameter int THETA_INIT    = (193 * `BP_HIST) / 100 + 14,  // 1.93*H + 14
    parameter int BTB_IDX_W     = $clog2(BTB_ENTRIES),
    parameter int BTB_TAG_W     = 32 - BTB_IDX_W
  ) (
    input  logic                    clk,
    input  logic                    rst,          // active high

    // ---- fetch side ----
    input  logic [31:0]             fetchPc,
    input  logic                    fetchStall,   // fetch PC is not advancing
    output logic                    fetchHit,     // fast prediction: taken
    output logic [31:0]             fetchTarget,
    output logic [`BP_BUS_W-1:0]    fetchBpBus,   // snapshot to ride the pipe

    // ---- decode side (N4 override) ----
    // These mirror the F->D pipeline register so the slow-path state always
    // corresponds to the instruction currently in DECODE.
    input  logic                    dStall,
    input  logic                    dFlush,
    output logic                    ovrValid,     // perceptron overrules fetch
    output logic                    ovrTaken,     // its verdict
    output logic [31:0]             ovrTarget,    // where to resteer

    // ---- execute side (resolution / training) ----
    input  logic                    exBranch,     // conditional branch in EX
    input  logic                    exTaken,      // resolved taken (btbUpdate)
    input  logic                    exWrong,      // this EX instr mispredicted
    input  logic [31:0]             exPc,
    input  logic [31:0]             exTarget,
    input  logic [`BP_BUS_W-1:0]    exBpBus,      // snapshot that produced it
    input  logic                    exControlXfer // branch or jump in EX
  );

  // ---------------------------------------------------------------- sizes
  localparam int NPERC   = (1 << INDEX_BITS);
  localparam int ROW_W   = (HIST + 1) * W_BITS;              // bits per row
  localparam int SUM_W   = W_BITS + $clog2(HIST + 1) + 2;    // headroom for y
  localparam int THETA_W = 10;

  // Balanced adder tree. Summing the HIST+1 terms sequentially synthesises to
  // a HIST-deep ripple of adders (Vivado: 22 logic levels, 9 cascaded
  // CARRY4s). A balanced tree is ceil(log2(HIST+1)) levels instead.
  localparam int NTERM = HIST + 1;
  localparam int TLEV  = $clog2(NTERM);
  localparam int TPAD  = (1 << TLEV);
  localparam int PIPE  = (`BP_PIPE_LEVEL > TLEV) ? TLEV : `BP_PIPE_LEVEL;
  localparam int NPART = (TPAD >> PIPE);      // partial sums registered

  localparam signed [W_BITS-1:0] W_MAX =  (1 <<< (W_BITS-1)) - 1;
  localparam signed [W_BITS-1:0] W_MIN = -(1 <<< (W_BITS-1));

  // BTB 2-bit counter encoding, kept identical to the baseline bimodal
  // predictor so the two are directly comparable:  taken <=> bit0 == 0
  localparam logic [1:0] S_TAKEN  = 2'b10,
                         W_TAKEN  = 2'b00,
                         W_NTAKEN = 2'b01,
                         S_NTAKEN = 2'b11;

  // ------------------------------------------------------------- storage
  logic [ROW_W-1:0] wtable [0:NPERC-1];

  logic                   btbValid  [0:BTB_ENTRIES-1];
  logic                   btbUncond [0:BTB_ENTRIES-1]; // jal: always taken
  logic [BTB_TAG_W-1:0]   btbTag    [0:BTB_ENTRIES-1];
  logic [31:0]            btbTgt    [0:BTB_ENTRIES-1];
  logic [1:0]             btbCount  [0:BTB_ENTRIES-1];

  logic [HIST-1:0]        ghrSpec;   // N1: speculative, updated at fetch
  logic [HIST-1:0]        ghrArch;   // N1: architectural, updated at EX

  logic signed [THETA_W-1:0] theta;  // N2: adaptive training threshold
  logic signed [7:0]         tc;     // N2: threshold adjust counter

  integer r, q;

  // Power-up initialisation. On an FPGA this becomes the RAM's INIT value and
  // costs nothing; in simulation it produces the same zeroed start state.
  //
  // This exists so the *reset* of the big tables can be compiled out for
  // synthesis (-DBP_NO_TABLE_RESET). A reset that drives every bit of the
  // weight table forces it into flip-flops: 128 x 25 x 8 = 25 600 FFs, plus
  // 15 360 for the BTB, which is 98% of an xc7a35t. With no reset the same
  // arrays infer distributed RAM and cost ~1 280 LUTs instead.
  initial
  begin
    for (q = 0; q < NPERC; q = q + 1)
      wtable[q] = '0;
    for (q = 0; q < BTB_ENTRIES; q = q + 1)
    begin
      btbValid[q]  = 1'b0;
      btbUncond[q] = 1'b0;
      btbTag[q]    = '0;
      btbTgt[q]    = '0;
      btbCount[q]  = W_NTAKEN;
    end
  end

  // ------------------------------------------------------------- helpers
  // Weight k of a row, sign extended to SUM_W.
  function automatic signed [SUM_W-1:0] getW(input [ROW_W-1:0] row,
                                             input integer k);
    logic signed [W_BITS-1:0] t;
    begin
      t    = row[k*W_BITS +: W_BITS];
      getW = t;                       // signed lvalue -> sign extension
    end
  endfunction

  // Saturating +/-1 step on weight k, returned as a raw W_BITS field.
  function automatic [W_BITS-1:0] stepW(input [ROW_W-1:0] row,
                                        input integer k,
                                        input logic up);
    logic signed [W_BITS-1:0] t;
    begin
      t = row[k*W_BITS +: W_BITS];
      if (up)
        stepW = (t == W_MAX) ? W_MAX : (t + 1);
      else
        stepW = (t == W_MIN) ? W_MIN : (t - 1);
    end
  endfunction

  //=====================================================================
  // FETCH PATH
  //=====================================================================
  logic [BTB_IDX_W-1:0]  fIdx;
  logic [BTB_TAG_W-1:0]  fTag;
  logic [INDEX_BITS-1:0] fPercIdx;
  logic                  fBtbHit, fUncond, fBimTaken, fStrongBim;
  logic [ROW_W-1:0]      fRow;
  logic                  fPredTaken, fSpecUpdate;
  // history as it stood when the instruction now in DECODE was fetched;
  // driven from whichever generate branch is active below
  logic [HIST-1:0]       ovrGhr;

  assign fIdx       = fetchPc[BTB_IDX_W+1:2];
  assign fTag       = fetchPc[31:BTB_IDX_W];
  assign fPercIdx   = fetchPc[INDEX_BITS+1:2];
  assign fBtbHit    = btbValid[fIdx] && (btbTag[fIdx] == fTag);
  assign fUncond    = btbUncond[fIdx];
  assign fRow       = wtable[fPercIdx];
  assign fBimTaken  = (btbCount[fIdx][0] == 1'b0);
  assign fStrongBim = (btbCount[fIdx] == S_TAKEN) || (btbCount[fIdx] == S_NTAKEN);

  // ---- level 0 of the adder tree: the signed terms, zero padded ----
  logic signed [SUM_W-1:0] tF [0:TLEV][0:TPAD-1];
  genvar gi, gl;

  generate
    for (gi = 0; gi < TPAD; gi = gi + 1)
    begin : gTF0
      if (gi == 0)
        assign tF[0][gi] = getW(fRow, 0);                       // bias
      else if (gi <= HIST)
        assign tF[0][gi] = ghrSpec[gi-1] ? getW(fRow, gi) : -getW(fRow, gi);
      else
        assign tF[0][gi] = '0;                                  // padding
    end
  endgenerate

  // Addition is associative here -- SUM_W carries enough headroom that no
  // partial sum can overflow -- so the tree computes exactly the same y as a
  // sequential accumulation, just log-depth instead of linear-depth. The
  // pipelined and single-cycle variants below therefore agree bit for bit.

  generate
    //-------------------------------------------------------------------
    if (OVERRIDE == 0)
    begin : gDirect
      // Single-cycle: the whole tree sits in the fetch path.
      logic signed [SUM_W-1:0] yF, yFabs;

      for (gl = 1; gl <= TLEV; gl = gl + 1)
      begin : gTFL
        for (gi = 0; gi < TPAD; gi = gi + 1)
        begin : gTFN
          if (gi < (TPAD >> gl))
            assign tF[gl][gi] = tF[gl-1][2*gi] + tF[gl-1][2*gi+1];
          else
            assign tF[gl][gi] = '0;
        end
      end

      assign yF    = tF[TLEV][0];
      assign yFabs = (yF < 0) ? -yF : yF;

      // N3 gate, evaluated at fetch
      assign fPredTaken =
             fUncond ? 1'b1
                     : (((CONF_GATE > 0) && (yFabs <= CONF_GATE) && fStrongBim)
                        ? fBimTaken : (yF >= 0));

      assign ovrValid  = 1'b0;
      assign ovrTaken  = 1'b0;
      assign ovrTarget = 32'b0;
      assign ovrGhr    = '0;
    end
    //-------------------------------------------------------------------
    else
    begin : gOvr
      // N4: fetch is steered by the 2-bit counter only -- a narrow table
      // read and a bit test.
      assign fPredTaken = fUncond ? 1'b1 : fBimTaken;

      // ---- slow path, stage 1: tree levels 1..PIPE ----
      for (gl = 1; gl <= PIPE; gl = gl + 1)
      begin : gTFL
        for (gi = 0; gi < TPAD; gi = gi + 1)
        begin : gTFN
          if (gi < (TPAD >> gl))
            assign tF[gl][gi] = tF[gl-1][2*gi] + tF[gl-1][2*gi+1];
          else
            assign tF[gl][gi] = '0;
        end
      end

      // ---- F -> D registers, in lockstep with the decode pipeline reg ----
      logic signed [SUM_W-1:0] dPart [0:NPART-1];
      logic                    dBtbHit, dUncond, dBimTaken, dStrongBim;
      logic                    dFastTaken;
      logic [31:0]             dTgt, dPcPlus4;
      logic [HIST-1:0]         dGhr;
      integer                  p;

      always_ff @(posedge clk)
      begin
        if (rst || dFlush)
        begin
          for (p = 0; p < NPART; p = p + 1)
            dPart[p] <= '0;
          dBtbHit    <= 1'b0;
          dUncond    <= 1'b0;
          dBimTaken  <= 1'b0;
          dStrongBim <= 1'b0;
          dFastTaken <= 1'b0;
          dTgt       <= '0;
          dPcPlus4   <= '0;
          dGhr       <= '0;
        end
        else if (!dStall)
        begin
          for (p = 0; p < NPART; p = p + 1)
            dPart[p] <= tF[PIPE][p];
          dBtbHit    <= fBtbHit;
          dUncond    <= fUncond;
          dBimTaken  <= fBimTaken;
          dStrongBim <= fStrongBim;
          dFastTaken <= fBtbHit && fPredTaken;
          dTgt       <= btbTgt[fIdx];
          dPcPlus4   <= fetchPc + 32'd4;
          dGhr       <= ghrSpec;          // history *before* this branch
        end
      end

      // ---- slow path, stage 2: tree levels PIPE+1..TLEV ----
      logic signed [SUM_W-1:0] tD [0:TLEV][0:TPAD-1];
      logic signed [SUM_W-1:0] yD, yDabs;

      for (gi = 0; gi < TPAD; gi = gi + 1)
      begin : gTD0
        if (gi < NPART)
          assign tD[PIPE][gi] = dPart[gi];
        else
          assign tD[PIPE][gi] = '0;
      end
      for (gl = PIPE + 1; gl <= TLEV; gl = gl + 1)
      begin : gTDL
        for (gi = 0; gi < TPAD; gi = gi + 1)
        begin : gTDN
          if (gi < (TPAD >> gl))
            assign tD[gl][gi] = tD[gl-1][2*gi] + tD[gl-1][2*gi+1];
          else
            assign tD[gl][gi] = '0;
        end
      end

      assign yD    = tD[TLEV][0];
      assign yDabs = (yD < 0) ? -yD : yD;

      // N3 gate, now evaluated one cycle later on registered state
      logic dPercVote, dUseBim, dFinalTaken;
      assign dUseBim = (CONF_GATE > 0) && (yDabs <= CONF_GATE) && dStrongBim;
      assign dPercVote = dUseBim ? dBimTaken : (yD >= 0);
      assign dFinalTaken = dUncond ? 1'b1 : dPercVote;

      // Override when the slow verdict disagrees with what fetch actually
      // did. Suppressed while DECODE is stalled so it fires exactly once,
      // and while EX is redirecting, because EX wins.
      assign ovrValid  = dBtbHit && !dUncond && !dStall && !exWrong &&
                         (dFinalTaken != dFastTaken);
      assign ovrTaken  = dFinalTaken;
      assign ovrTarget = dFinalTaken ? dTgt : dPcPlus4;
      assign ovrGhr    = dGhr;
    end
  endgenerate

  // A taken prediction needs a target, which only the BTB can supply.
  assign fetchHit    = fBtbHit && fPredTaken;
  assign fetchTarget = btbTgt[fIdx];

  // N1: this fetch advances the speculative history only if the BTB
  // recognises the PC as a *conditional* branch and the fetch is real.
  assign fSpecUpdate = fBtbHit && !fUncond && !fetchStall && !exWrong &&
                       !ovrValid;
  assign fetchBpBus  = {fSpecUpdate, ghrSpec};

  //=====================================================================
  // EXECUTE PATH -- resolution, training, history repair
  //=====================================================================
  logic [BTB_IDX_W-1:0]  eIdx;
  logic [BTB_TAG_W-1:0]  eTag;
  logic [INDEX_BITS-1:0] ePercIdx;
  logic                  eBtbHit;
  logic [ROW_W-1:0]      eRow;
  logic [HIST-1:0]       eGhr;
  logic                  eSpecUpdated;
  logic [1:0]            eCount;   // declared here: the training pipeline
                                   // registers below read it before the
                                   // bimodal update logic further down

  assign eCount       = btbCount[eIdx];
  assign eIdx         = exPc[BTB_IDX_W+1:2];
  assign eTag         = exPc[31:BTB_IDX_W];
  assign ePercIdx     = exPc[INDEX_BITS+1:2];
  assign eBtbHit      = btbValid[eIdx] && (btbTag[eIdx] == eTag);
  assign eRow         = wtable[ePercIdx];
  assign eGhr         = exBpBus[HIST-1:0];
  assign eSpecUpdated = exBpBus[HIST];

  //---------------------------------------------------------------------
  // TRAINING, pipelined over two cycles.
  //
  // Doing it in one cycle makes
  //     exPc -> weight-table read -> adder tree -> |y| vs theta -> table
  //     write enable
  // the critical path (Vivado: 17.1 ns, 20 logic levels, 10 cascaded
  // CARRY4s) once the fetch path has been dealt with by N4. Unlike the fetch
  // path there is nothing speculative here -- the branch has already
  // resolved and nothing is waiting on the weight update -- so the work can
  // simply be spread over two cycles.
  //
  // EX cycle:   read the row, compute tree levels 0..PIPE, register.
  // EX+1 cycle: finish the tree, decide, write the row back.
  //
  // The cost is that two branches resolving back to back into the same
  // perceptron row see the older one's weights. That is a real (small)
  // accuracy effect, measured rather than assumed -- see the README.
  //---------------------------------------------------------------------
  logic signed [SUM_W-1:0] tE [0:TLEV][0:TPAD-1];

  generate
    for (gi = 0; gi < TPAD; gi = gi + 1)
    begin : gTE0
      if (gi == 0)
        assign tE[0][gi] = getW(eRow, 0);
      else if (gi <= HIST)
        assign tE[0][gi] = eGhr[gi-1] ? getW(eRow, gi) : -getW(eRow, gi);
      else
        assign tE[0][gi] = '0;
    end
    for (gl = 1; gl <= PIPE; gl = gl + 1)
    begin : gTEL
      for (gi = 0; gi < TPAD; gi = gi + 1)
      begin : gTEN
        if (gi < (TPAD >> gl))
          assign tE[gl][gi] = tE[gl-1][2*gi] + tE[gl-1][2*gi+1];
        else
          assign tE[gl][gi] = '0;
      end
    end
  endgenerate

  // ---- EX -> EX+1 registers ----
  logic                    tValid, tTaken, tExWrong, tSpecUpd;
  logic [INDEX_BITS-1:0]   tIdx;
  logic [ROW_W-1:0]        tRow;
  logic [HIST-1:0]         tGhr;
  logic [1:0]              tCount;
  logic signed [SUM_W-1:0] tPart [0:NPART-1];
  integer                  tp;

  always_ff @(posedge clk)
  begin
    if (rst)
    begin
      tValid <= 1'b0; tTaken <= 1'b0; tExWrong <= 1'b0; tSpecUpd <= 1'b0;
      tIdx   <= '0;   tRow   <= '0;   tGhr     <= '0;   tCount   <= '0;
      for (tp = 0; tp < NPART; tp = tp + 1)
        tPart[tp] <= '0;
    end
    else
    begin
      tValid   <= exBranch;
      tTaken   <= exTaken;
      tExWrong <= exBranch && exWrong;
      tSpecUpd <= eSpecUpdated;
      tIdx     <= ePercIdx;
      tRow     <= eRow;
      tGhr     <= eGhr;
      tCount   <= eCount;
      for (tp = 0; tp < NPART; tp = tp + 1)
        tPart[tp] <= tE[PIPE][tp];
    end
  end

  // ---- EX+1: finish the tree and decide ----
  logic signed [SUM_W-1:0] tT [0:TLEV][0:TPAD-1];
  logic signed [SUM_W-1:0] yT, yTabs;

  generate
    for (gi = 0; gi < TPAD; gi = gi + 1)
    begin : gTT0
      if (gi < NPART)
        assign tT[PIPE][gi] = tPart[gi];
      else
        assign tT[PIPE][gi] = '0;
    end
    for (gl = PIPE + 1; gl <= TLEV; gl = gl + 1)
    begin : gTTL
      for (gi = 0; gi < TPAD; gi = gi + 1)
      begin : gTTN
        if (gi < (TPAD >> gl))
          assign tT[gl][gi] = tT[gl-1][2*gi] + tT[gl-1][2*gi+1];
        else
          assign tT[gl][gi] = '0;
      end
    end
  endgenerate

  assign yT    = tT[TLEV][0];
  assign yTabs = (yT < 0) ? -yT : yT;

  // Was the perceptron itself right? (independent of which source was gated in)
  logic tPercTaken, tPercWrong, tUnderTrained, tDoTrain;
  assign tPercTaken    = (yT >= 0);
  assign tPercWrong    = (tPercTaken != tTaken);
  assign tUnderTrained = (yTabs <= theta);
  assign tDoTrain      = tValid && (tPercWrong || tUnderTrained);

  // Trained row, built as a whole so the array write is a single assignment.
  logic [ROW_W-1:0] tRowNext;
  always_comb
  begin : trainRow
    integer k;
    tRowNext              = tRow;
    tRowNext[0 +: W_BITS] = stepW(tRow, 0, tTaken);          // bias: += t
    for (k = 1; k <= HIST; k = k + 1)
      // t*x[i] == +1 exactly when history bit i agrees with the outcome
      tRowNext[k*W_BITS +: W_BITS] = stepW(tRow, k, (tGhr[k-1] == tTaken));
  end

  // Next 2-bit bimodal counter for this BTB entry.
  logic [1:0] eNextCount;
  always_comb
  begin
    case (eCount)
      W_TAKEN:  eNextCount = exTaken ? S_TAKEN  : W_NTAKEN;
      S_TAKEN:  eNextCount = exTaken ? S_TAKEN  : W_TAKEN;
      W_NTAKEN: eNextCount = exTaken ? W_TAKEN  : S_NTAKEN;
      S_NTAKEN: eNextCount = exTaken ? W_NTAKEN : S_NTAKEN;
      default:  eNextCount = W_TAKEN;
    endcase
  end

  // Next speculative history.
  // Priority: EX repair > override repair > missed-bit > fetch advance.
  logic            eNeedInsert;
  logic [HIST-1:0] ghrSpecNext;
  assign eNeedInsert = exBranch && !eSpecUpdated;   // BTB missed this branch

  always_comb
  begin
    if (exWrong)
      // Everything younger is being flushed, so the exact post-recovery
      // history is the architectural one, plus this outcome if the culprit
      // was itself a conditional branch. This also covers a BTB false hit
      // (predicted taken for something that is not a control transfer):
      // fetch advanced the speculative history for it, and restoring to
      // ghrArch drops that spurious bit.
      ghrSpecNext = exBranch ? {ghrArch[HIST-2:0], exTaken} : ghrArch;
    else if (ovrValid && eNeedInsert)
      // the EX branch is older than the overridden one, so it goes in first
      ghrSpecNext = {ovrGhr[HIST-3:0], exTaken, ovrTaken};
    else if (ovrValid)
      // rewrite this branch's history bit with the perceptron's verdict; the
      // younger speculative bit is discarded along with the flushed fetch
      ghrSpecNext = {ovrGhr[HIST-2:0], ovrTaken};
    else if (eNeedInsert && fSpecUpdate)
      ghrSpecNext = {ghrSpec[HIST-3:0], exTaken, fPredTaken};
    else if (eNeedInsert)
      ghrSpecNext = {ghrSpec[HIST-2:0], exTaken};
    else if (fSpecUpdate)
      ghrSpecNext = {ghrSpec[HIST-2:0], fPredTaken};
    else
      ghrSpecNext = ghrSpec;
  end

  //=====================================================================
  // Sequential state
  //=====================================================================
  always_ff @(posedge clk)
  begin
    if (rst)
    begin
`ifndef BP_NO_TABLE_RESET
      // Simulation default: clear the tables so each run starts identically.
      // Compiled out for synthesis -- see the initial block above.
      for (r = 0; r < NPERC; r = r + 1)
        wtable[r] <= '0;
      for (r = 0; r < BTB_ENTRIES; r = r + 1)
      begin
        btbValid[r]  <= 1'b0;
        btbUncond[r] <= 1'b0;
        btbTag[r]    <= '0;
        btbTgt[r]    <= '0;
        btbCount[r]  <= W_NTAKEN;
      end
`endif
      ghrSpec <= '0;
      ghrArch <= '0;
      theta   <= THETA_INIT;
      tc      <= 0;
    end
    else
    begin
      ghrSpec <= ghrSpecNext;

      if (exBranch)
        ghrArch <= {ghrArch[HIST-2:0], exTaken};

      //---------------- perceptron weight update (EX+1) ------------------
      if (tDoTrain)
        wtable[tIdx] <= tRowNext;

      //---------------- N2: adaptive threshold (EX+1) --------------------
      if (tValid)
      begin
        if (tPercWrong)
        begin
          if (tc >= 15)
          begin
            theta <= theta + 1;
            tc    <= 0;
          end
          else
            tc <= tc + 1;
        end
        else if (tUnderTrained)
        begin
          if (tc <= -15)
          begin
            if (theta > 8)
              theta <= theta - 1;
            tc <= 0;
          end
          else
            tc <= tc - 1;
        end
      end

      //------------------- BTB allocate / update ------------------------
      // Allocate on ANY conditional branch, taken or not, and on any taken
      // jump. exTarget is pc+imm, which EX computes for a branch whichever
      // way it resolves -- so there is no reason to wait for a taken outcome.
      // Allocating not-taken branches too is what lets fetch recognise them
      // as branches and advance the speculative global history for them,
      // which is the whole basis of N1.
      if (eBtbHit)
      begin
        if (exBranch)
          btbCount[eIdx] <= eNextCount;
        if (exTaken)
          btbTgt[eIdx] <= exTarget;
      end
      else if (exBranch || (exTaken && exControlXfer))
      begin
        btbValid[eIdx]  <= 1'b1;
        btbUncond[eIdx] <= !exBranch;              // jal -> unconditional
        btbTag[eIdx]    <= eTag;
        btbTgt[eIdx]    <= exTarget;
        btbCount[eIdx]  <= !exBranch ? S_TAKEN
                                     : (exTaken ? W_TAKEN : W_NTAKEN);
      end
    end
  end

  //=====================================================================
  // Simulation-only statistics (excluded from synthesis)
  //=====================================================================
`ifndef SYNTHESIS
  integer st_branches, st_mispred;
  integer st_percUsed, st_percUsedWrong;
  integer st_bimUsed,  st_bimUsedWrong;
  integer st_percAlone, st_bimAlone;
  integer st_btbMiss, st_override;

  // Sampled in the EX+1 training stage, where y for the resolved branch is
  // available. One cycle later than before, same branches, same outcomes.
  logic tBimodalTaken, tStrongBim, tUseBim;
  assign tBimodalTaken = (tCount[0] == 1'b0);
  assign tStrongBim    = (tCount == S_TAKEN) || (tCount == S_NTAKEN);
  assign tUseBim       = (CONF_GATE > 0) && (yTabs <= CONF_GATE) && tStrongBim;

  initial
  begin
    st_branches  = 0;  st_mispred       = 0;
    st_percUsed  = 0;  st_percUsedWrong = 0;
    st_bimUsed   = 0;  st_bimUsedWrong  = 0;
    st_percAlone = 0;  st_bimAlone      = 0;
    st_btbMiss   = 0;  st_override      = 0;
  end

  // Plain `always`, not `always_ff`: these counters are also written by the
  // initial block above, and always_ff requires exactly one driving process
  // per variable. Icarus tolerates the violation; Vivado's xelab rejects it
  // with "driven by invalid combination of procedural drivers". This is a
  // simulation monitor rather than hardware, so plain always is correct here.
  always @(posedge clk)
  begin
    if (!rst && ovrValid)
      st_override = st_override + 1;

    if (!rst && tValid)
    begin
      st_branches = st_branches + 1;
      if (tExWrong)   st_mispred = st_mispred + 1;
      if (!tSpecUpd)  st_btbMiss = st_btbMiss + 1;

      if (tUseBim)
      begin
        st_bimUsed = st_bimUsed + 1;
        if (tBimodalTaken != tTaken) st_bimUsedWrong = st_bimUsedWrong + 1;
      end
      else
      begin
        st_percUsed = st_percUsed + 1;
        if (tPercTaken != tTaken) st_percUsedWrong = st_percUsedWrong + 1;
      end

      // what each component would have scored on its own
      if (tPercTaken    != tTaken) st_percAlone = st_percAlone + 1;
      if (tBimodalTaken != tTaken) st_bimAlone  = st_bimAlone  + 1;
    end
  end
`endif

endmodule
