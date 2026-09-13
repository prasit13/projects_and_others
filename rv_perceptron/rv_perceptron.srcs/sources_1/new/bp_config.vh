//==========================================================================
// bp_config.vh -- global configuration for the branch-prediction subsystem
//
// These are `define (not parameters) because the speculative-history bus has
// to be plumbed through stageDecode and stageExecute, and a single width
// symbol keeps every port declaration in sync.
//==========================================================================
`ifndef BP_CONFIG_VH
`define BP_CONFIG_VH

// ---- perceptron geometry -------------------------------------------------
// Every knob is `ifndef-guarded so -D<name>=<n> on the command line wins.
// Without the guard the header silently overrides the command line and a
// parameter sweep produces identical numbers for every point.
`ifndef BP_HIST
  `define BP_HIST      24   // global-history length (number of weights - 1)
`endif
`ifndef BP_INDEX_BITS
  `define BP_INDEX_BITS 7   // log2(number of perceptrons)  -> 128 rows
`endif
`ifndef BP_W_BITS
  `define BP_W_BITS     8   // signed weight width          -> [-128, 127]
`endif

// Storage = 2^7 rows * (24+1) weights * 8 bits = 25 600 bits = 3.125 KiB

// ---- N3 confidence gate --------------------------------------------------
// The perceptron's vote is overridden by the BTB's 2-bit counter only when
// |y| <= BP_CONF_GATE *and* that counter is in a strongly-biased state.
// This has to be far smaller than the training threshold theta: a perceptron
// with a small but non-zero margin is still usually right, so a wide gate
// hands away predictions the perceptron would have got correct.
// Set to 0 to disable the hybrid and run a pure perceptron.
`ifndef BP_CONF_GATE
  `define BP_CONF_GATE 16
`endif

// ---- BTB -----------------------------------------------------------------
`ifndef BP_BTB_ENTRIES
  `define BP_BTB_ENTRIES 256
`endif

// ---- overriding (pipelined) organisation ---------------------------------
// BP_OVERRIDE = 0
//   Single-cycle perceptron: fetch waits for the weight-table read and the
//   whole adder tree before it can pick the next PC. Best cycle count, but
//   the path pc -> RAM -> tree -> compare -> next-PC mux -> pc is 17.6 ns on
//   an xc7a35t, which caps the core at ~56 MHz.
//
// BP_OVERRIDE = 1  (default)
//   Two-level overriding predictor. The BTB's 2-bit counter steers fetch in
//   the same cycle (a short path), while the perceptron's dot product is
//   computed across two cycles and delivers its verdict one cycle later. If
//   the perceptron disagrees it redirects fetch and corrects the recorded
//   prediction, costing one bubble instead of a full EX-stage flush.
//
// BP_PIPE_LEVEL is where the adder tree is cut. Level 0 is the raw +/-w[i]
// terms and each level halves the count, so cutting at L registers
// ceil((HIST+1)/2^L) partial sums -- 4 values for the default geometry.
`ifndef BP_OVERRIDE
  `define BP_OVERRIDE 1
`endif
`ifndef BP_PIPE_LEVEL
  `define BP_PIPE_LEVEL 3
`endif

// ---- speculative-history side bus ---------------------------------------
// Carried F -> D -> E alongside the instruction.
//   [BP_HIST-1:0] : global history as it was when the prediction was made
//   [BP_HIST]     : 1 if this fetch advanced the speculative history
//                   (i.e. the BTB recognised the PC as a control transfer)
`define BP_BUS_W      (`BP_HIST + 1)

// ---- predictor selection -------------------------------------------------
// Pick exactly one on the iverilog command line:
//   -DPRED_NOTAKEN     static not-taken (no predictor)
//   -DPRED_BIMODAL     bimodal BTB (2-bit counters)
//   -DPRED_GSHARE      gshare
//   -DPRED_PERCEPTRON  confidence-gated hybrid perceptron  (default)
//
// Verilog's preprocessor has no `if <expression>, only `ifdef, so the
// selection is by symbol and this header derives the numeric code and the
// statistics flags from it.
`ifdef PRED_NOTAKEN
  `define PREDICTOR 0
`elsif PRED_BIMODAL
  `define PREDICTOR 1
  `define HAS_CLASSIC
`elsif PRED_GSHARE
  `define PREDICTOR 2
  `define HAS_CLASSIC
`else
  `define PRED_PERCEPTRON
  `define PREDICTOR 3
  `define HAS_PERCEPTRON
`endif

`endif
