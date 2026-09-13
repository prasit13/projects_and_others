`include "bp_config.vh"

//==========================================================================
// classicPredictor -- reference predictors for comparison
//
//   MODE = 0 : bimodal  (PHT indexed by PC bits only)
//   MODE = 1 : gshare   (PHT indexed by PC bits XOR global history)
//
// Deliberately shares everything except the direction-prediction table with
// perceptronPredictor: same BTB organisation, same unconditional-jump
// handling, same speculative-history-with-repair scheme, same interface.
// That way a measured difference between this module and the perceptron is
// attributable to the direction predictor and nothing else.
//
// PHT_BITS is chosen so the 2-bit counter table costs the same number of
// bits as the perceptron weight table:
//     perceptron = 2^BP_INDEX_BITS * (BP_HIST+1) * BP_W_BITS bits
//     this       = 2^PHT_BITS * 2 bits
//==========================================================================

module classicPredictor #(
    parameter int MODE        = 1,
    parameter int BTB_ENTRIES = `BP_BTB_ENTRIES,
    parameter int PHT_BITS    = 13,    // 8192 counters = 16 Kbit
    // never wider than the side bus that carries it to EX
    parameter int GHR_BITS    = (`BP_HIST < 13) ? `BP_HIST : 13,
    parameter int BTB_IDX_W   = $clog2(BTB_ENTRIES),
    parameter int BTB_TAG_W   = 32 - BTB_IDX_W
  ) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [31:0]          fetchPc,
    input  logic                 fetchStall,
    output logic                 fetchHit,
    output logic [31:0]          fetchTarget,
    output logic [`BP_BUS_W-1:0] fetchBpBus,

    // N4 override interface -- these predictors are single-cycle, so they
    // never override. The ports exist so core.sv can wire any predictor
    // identically.
    input  logic                 dStall,
    input  logic                 dFlush,
    output logic                 ovrValid,
    output logic                 ovrTaken,
    output logic [31:0]          ovrTarget,

    input  logic                 exBranch,
    input  logic                 exTaken,
    input  logic                 exWrong,
    input  logic [31:0]          exPc,
    input  logic [31:0]          exTarget,
    input  logic [`BP_BUS_W-1:0] exBpBus,
    input  logic                 exControlXfer
  );

  localparam int NPHT = (1 << PHT_BITS);
  localparam logic [1:0] S_TAKEN  = 2'b10,
                         W_TAKEN  = 2'b00,
                         W_NTAKEN = 2'b01,
                         S_NTAKEN = 2'b11;

  logic [1:0]           pht       [0:NPHT-1];
  logic                 btbValid  [0:BTB_ENTRIES-1];
  logic                 btbUncond [0:BTB_ENTRIES-1];
  logic [BTB_TAG_W-1:0] btbTag    [0:BTB_ENTRIES-1];
  logic [31:0]          btbTgt    [0:BTB_ENTRIES-1];

  logic [GHR_BITS-1:0]  ghrSpec, ghrArch;
  integer r, q;

  assign ovrValid  = 1'b0;
  assign ovrTaken  = 1'b0;
  assign ovrTarget = 32'b0;

  // Power-up init; see perceptronPredictor for why the table reset is
  // separately compiled out for synthesis. An 8192 x 2-bit PHT with a reset
  // is 16 384 flip-flops (39% of an xc7a35t); without one it is ~512 LUTs.
  initial
  begin
    for (q = 0; q < NPHT; q = q + 1)
      pht[q] = W_NTAKEN;
    for (q = 0; q < BTB_ENTRIES; q = q + 1)
    begin
      btbValid[q]  = 1'b0;
      btbUncond[q] = 1'b0;
      btbTag[q]    = '0;
      btbTgt[q]    = '0;
    end
  end

  // ------------------------------------------------------------- fetch
  logic [BTB_IDX_W-1:0] fIdx;
  logic [BTB_TAG_W-1:0] fTag;
  logic [PHT_BITS-1:0]  fPhtIdx, fPcBits;
  logic                 fBtbHit, fUncond, fPredTaken, fSpecUpdate;

  assign fIdx    = fetchPc[BTB_IDX_W+1:2];
  assign fTag    = fetchPc[31:BTB_IDX_W];
  assign fBtbHit = btbValid[fIdx] && (btbTag[fIdx] == fTag);
  assign fUncond = btbUncond[fIdx];

  // Widen by plain assignment rather than a replication: when PHT_BITS ==
  // GHR_BITS a {0{...}} replication is a zero-width concatenation item, which
  // is not legal Verilog.
  logic [PHT_BITS-1:0]   fGhrExt;
  logic [`BP_HIST-1:0]   fGhrBus;
  assign fGhrExt = ghrSpec;
  assign fGhrBus = ghrSpec;

  assign fPcBits = fetchPc[PHT_BITS+1:2];
  assign fPhtIdx = (MODE == 0) ? fPcBits : (fPcBits ^ fGhrExt);

  assign fPredTaken  = fUncond ? 1'b1 : (pht[fPhtIdx][0] == 1'b0);
  assign fetchHit    = fBtbHit && fPredTaken;
  assign fetchTarget = btbTgt[fIdx];

  assign fSpecUpdate = fBtbHit && !fUncond && !fetchStall && !exWrong;
  assign fetchBpBus  = {fSpecUpdate, fGhrBus};

  // ------------------------------------------------------------ execute
  logic [BTB_IDX_W-1:0] eIdx;
  logic [BTB_TAG_W-1:0] eTag;
  logic [PHT_BITS-1:0]  ePhtIdx, ePcBits;
  logic [GHR_BITS-1:0]  eGhr;
  logic                 eBtbHit, eSpecUpdated, eNeedInsert;
  logic [1:0]           eCount, eNextCount;

  assign eIdx         = exPc[BTB_IDX_W+1:2];
  assign eTag         = exPc[31:BTB_IDX_W];
  assign eBtbHit      = btbValid[eIdx] && (btbTag[eIdx] == eTag);
  assign eGhr         = exBpBus[GHR_BITS-1:0];
  assign eSpecUpdated = exBpBus[`BP_HIST];
  assign eNeedInsert  = exBranch && !eSpecUpdated;

  logic [PHT_BITS-1:0] eGhrExt;
  assign eGhrExt = eGhr;

  assign ePcBits = exPc[PHT_BITS+1:2];
  assign ePhtIdx = (MODE == 0) ? ePcBits : (ePcBits ^ eGhrExt);

  assign eCount = pht[ePhtIdx];
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

  logic [GHR_BITS-1:0] ghrSpecNext;
  always_comb
  begin
    if (exWrong)
      // see perceptronPredictor: also drops the spurious history bit left
      // behind by a BTB false hit
      ghrSpecNext = exBranch ? {ghrArch[GHR_BITS-2:0], exTaken} : ghrArch;
    else if (eNeedInsert && fSpecUpdate)
      ghrSpecNext = {ghrSpec[GHR_BITS-3:0], exTaken, fPredTaken};
    else if (eNeedInsert)
      ghrSpecNext = {ghrSpec[GHR_BITS-2:0], exTaken};
    else if (fSpecUpdate)
      ghrSpecNext = {ghrSpec[GHR_BITS-2:0], fPredTaken};
    else
      ghrSpecNext = ghrSpec;
  end

  // ---------------------------------------------------------- sequential
  always_ff @(posedge clk)
  begin
    if (rst)
    begin
`ifndef BP_NO_TABLE_RESET
      for (r = 0; r < NPHT; r = r + 1)
        pht[r] <= W_NTAKEN;
      for (r = 0; r < BTB_ENTRIES; r = r + 1)
      begin
        btbValid[r]  <= 1'b0;
        btbUncond[r] <= 1'b0;
        btbTag[r]    <= '0;
        btbTgt[r]    <= '0;
      end
`endif
      ghrSpec <= '0;
      ghrArch <= '0;
    end
    else
    begin
      ghrSpec <= ghrSpecNext;

      if (exBranch)
      begin
        ghrArch        <= {ghrArch[GHR_BITS-2:0], exTaken};
        pht[ePhtIdx]   <= eBtbHit ? eNextCount : (exTaken ? W_TAKEN : W_NTAKEN);
      end

      // Same allocation policy as perceptronPredictor: any conditional
      // branch (taken or not) plus any taken jump.
      if (eBtbHit)
      begin
        if (exTaken)
          btbTgt[eIdx] <= exTarget;
      end
      else if (exBranch || (exTaken && exControlXfer))
      begin
        btbValid[eIdx]  <= 1'b1;
        btbUncond[eIdx] <= !exBranch;
        btbTag[eIdx]    <= eTag;
        btbTgt[eIdx]    <= exTarget;
      end
    end
  end

  // ----------------------------------------------- simulation statistics
`ifndef SYNTHESIS
  integer st_branches, st_mispred, st_btbMiss;
  integer st_percUsed, st_percUsedWrong, st_bimUsed, st_bimUsedWrong;
  integer st_percAlone, st_bimAlone;

  initial
  begin
    st_branches  = 0;  st_mispred       = 0;  st_btbMiss      = 0;
    st_percUsed  = 0;  st_percUsedWrong = 0;
    st_bimUsed   = 0;  st_bimUsedWrong  = 0;
    st_percAlone = 0;  st_bimAlone      = 0;
  end

  // Plain `always`, not `always_ff` -- see perceptronPredictor.sv: these
  // counters are also written by the initial block above, and always_ff
  // permits only one driving process per variable.
  always @(posedge clk)
  begin
    if (!rst && exBranch)
    begin
      st_branches = st_branches + 1;
      if (exWrong)       st_mispred = st_mispred + 1;
      if (!eSpecUpdated) st_btbMiss = st_btbMiss + 1;
    end
  end
`endif

endmodule
