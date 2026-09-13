`timescale 1ns/1ps
`include "bp_config.vh"

//==========================================================================
// TB -- self-contained Icarus Verilog testbench.
//
// Replaces the old cocotb/verilator flow (which needed WSL) with a plain
// SystemVerilog bench so the project builds with iverilog on Windows.
//
// Runs the program in code.mem/data.mem to completion, streams the UART
// output, and prints branch-predictor statistics harvested straight out of
// the predictor and the core.
//
// Plusargs:
//   +vcd          dump waves to the file named by +vcdfile (default dump.vcd)
//   +vcdfile=NAME
//   +maxcycles=N  cycle cap (default 20 000 000)
//   +quiet        suppress the UART stream
//==========================================================================

module TB;

  logic clk;
  logic rst;
  logic usePredictor;

  logic [31:0] imemRdata, imemAddr;
  logic [31:0] dmemRdata, dmemRdataFinal, dmemWdata;
  logic [2:0]  dmemSize;
  logic        dmemWen, dmemWenFinal;
  logic [31:0] dmemAddr;
  logic        uartWen;
  logic [7:0]  uartData;

  assign uartData       = dmemWdata[7:0];
  assign uartWen        = dmemWen & (dmemAddr == 32'hFFFF_FFFC);
  assign dmemWenFinal   = dmemWen & (!uartWen);
  assign dmemRdataFinal = dmemRdata;

  core uut (
         .clk          (clk),
         .rst          (rst),
         .usePredictor (usePredictor),
         .imemRdata    (imemRdata),
         .imemAddr     (imemAddr),
         .dmemRdata    (dmemRdataFinal),
         .dmemWdata    (dmemWdata),
         .dmemSize     (dmemSize),
         .dmemWen      (dmemWen),
         .dmemAddr     (dmemAddr)
       );

  imem instr (.clk(clk), .rAddr(imemAddr), .rData(imemRdata));

  dmem data (.wData(dmemWdata), .rData(dmemRdata), .clk(clk),
             .wEn(dmemWenFinal), .addr(dmemAddr), .size(dmemSize));

  simUart uart (.clk(clk), .rst(rst), .data(uartData), .wEn(uartWen));

  //---------------------------------------------------------------- clock
  initial
  begin
    clk = 1'b0;
    forever #0.5 clk = ~clk;      // 1 ns period
  end

  //---------------------------------------------------------------- names
  function automatic [8*12-1:0] predName;
    input integer sel;
    begin
      case (sel)
        0:       predName = "not-taken";
        1:       predName = "bimodal";
        2:       predName = "gshare";
        default: predName = "perceptron";
      endcase
    end
  endfunction

  //------------------------------------------------------------ main loop
  integer cycles;
  integer maxCycles;
  reg [1023:0] vcdFile;
  integer retired, mispred, xfers;
  real     rate, cpi;

  initial
  begin
    if (!$value$plusargs("maxcycles=%d", maxCycles))
      maxCycles = 20000000;

    if ($test$plusargs("vcd"))
    begin
      if (!$value$plusargs("vcdfile=%s", vcdFile))
        vcdFile = "dump.vcd";
      $dumpfile(vcdFile);
      $dumpvars(0, TB);
    end

    usePredictor = 1'b1;
    rst          = 1'b1;
    cycles       = 0;

    $display("");
    $display("=========================================================");
    $display(" RV32I pipeline -- predictor: %0s", predName(`PREDICTOR));
    $display("=========================================================");

    repeat (4) @(posedge clk);
    rst = 1'b0;

    // run until the HALT sentinel (boot.s loads 0xDEADC0DE into t0)
    forever
    begin
      @(posedge clk);
      cycles = cycles + 1;

      if (uut.decode.regF.writeEn === 1'b1 &&
          uut.decode.regF.writeData === 32'hDEADC0DE)
      begin
        report("program reached HALT");
        $finish;
      end

      if (cycles >= maxCycles)
      begin
        $display("\n[TB] TIMEOUT after %0d cycles", cycles);
        report("TIMED OUT");
        $fatal(1, "timeout");
      end
    end
  end

  //--------------------------------------------------------------- report
  task automatic report(input [8*40-1:0] why);
    begin
      // csrFile holds the architectural counters the benchmark also reads
      retired = uut.decode.csrF.csRegisters[2];
      mispred = uut.decode.csrF.csRegisters[0];
      xfers   = uut.decode.csrF.csRegisters[1];

      $display("");
      $display("---------------------------------------------------------");
      $display(" RESULT (%0s)", why);
      $display("---------------------------------------------------------");
      $display(" predictor              : %0s", predName(`PREDICTOR));
      $display(" cycles                 : %0d", cycles);
      $display(" instructions retired   : %0d", retired);
      if (retired > 0)
      begin
        cpi = cycles * 1.0 / retired;
        $display(" CPI                    : %0.4f", cpi);
      end
      $display(" control transfers      : %0d", xfers);
      $display(" mispredictions         : %0d", mispred);
      if (xfers > 0)
      begin
        rate = mispred * 100.0 / xfers;
        $display(" misprediction rate     : %0.2f %%", rate);
      end

`ifdef HAS_PERCEPTRON
      predictorReport;
`else
  `ifdef HAS_CLASSIC
      classicReport;
  `endif
`endif
      $display("---------------------------------------------------------");
      $display("");
    end
  endtask

`ifdef HAS_PERCEPTRON
  task automatic predictorReport;
    integer b, m, pu, puw, bu, buw, pa, ba, bm, ov;
    begin
      ov  = uut.gPerceptron.bPredict.st_override;
      b   = uut.gPerceptron.bPredict.st_branches;
      m   = uut.gPerceptron.bPredict.st_mispred;
      pu  = uut.gPerceptron.bPredict.st_percUsed;
      puw = uut.gPerceptron.bPredict.st_percUsedWrong;
      bu  = uut.gPerceptron.bPredict.st_bimUsed;
      buw = uut.gPerceptron.bPredict.st_bimUsedWrong;
      pa  = uut.gPerceptron.bPredict.st_percAlone;
      ba  = uut.gPerceptron.bPredict.st_bimAlone;
      bm  = uut.gPerceptron.bPredict.st_btbMiss;

      $display("");
      $display(" -- perceptron breakdown (conditional branches only) --");
      $display(" conditional branches   : %0d", b);
      $display(" cond. mispredictions   : %0d", m);
      if (b > 0)
        $display(" cond. mispred rate     : %0.2f %%", m * 100.0 / b);
      $display(" BTB misses             : %0d", bm);
      $display(" final theta            : %0d",
               $signed(uut.gPerceptron.bPredict.theta));
      $display(" N4 overrides (1 cycle) : %0d", ov);
      if (b > 0)
        $display(" override rate          : %0.2f %% of branches", ov*100.0/b);
      $display("");
      $display("  confidence gate (N3):");
      $display("   perceptron chosen     : %0d  (wrong %0d)", pu, puw);
      $display("   bimodal chosen        : %0d  (wrong %0d)", bu, buw);
      $display("");
      $display("  if each ran alone:");
      if (b > 0)
      begin
        $display("   perceptron only wrong : %0d  (%0.2f %%)", pa, pa*100.0/b);
        $display("   bimodal only wrong    : %0d  (%0.2f %%)", ba, ba*100.0/b);
        $display("   hybrid (actual) wrong : %0d  (%0.2f %%)",
                 puw + buw, (puw + buw) * 100.0 / b);
      end
    end
  endtask
`endif

`ifdef HAS_CLASSIC
  task automatic classicReport;
    integer b, m, bm;
    begin
      b  = uut.gClassic.bPredict.st_branches;
      m  = uut.gClassic.bPredict.st_mispred;
      bm = uut.gClassic.bPredict.st_btbMiss;
      $display("");
      $display(" -- %0s breakdown (conditional branches only) --",
               predName(`PREDICTOR));
      $display(" conditional branches   : %0d", b);
      $display(" cond. mispredictions   : %0d", m);
      if (b > 0)
        $display(" cond. mispred rate     : %0.2f %%", m * 100.0 / b);
      $display(" BTB misses             : %0d", bm);
    end
  endtask
`endif

endmodule
