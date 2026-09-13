//==========================================================================
// csrFile -- read-only performance counters exposed to software
//
//   0x80 -> [0] mispredicted control transfers
//   0x81 -> [1] control transfers
//   0x82 -> [2] instructions
//   0x83 -> [3] cycles
//
// These had no reset. Verilator zero-initialises state, so the old flow
// happened to work; under Icarus (and on real hardware) they came up X and
// every counter difference the benchmark computed was garbage, which then
// hung the software divide routine. They are reset properly now.
//==========================================================================
module csrFile#(
    parameter int regSize = 16
  )(
    output logic [31:0] csr,
    input logic wEn,
    input logic [31:0] wData,
    input logic [11:0] wAddr,
    input logic  wrongBranch,
    input logic validInst,
    input logic  controlXfer,
    input logic [3:0] readAddr,
    input logic rst,
    input logic clk
  );

  logic [31:0] csRegisters [regSize-1:0];
  integer i;

  assign csr = csRegisters[readAddr];

  always_ff@(posedge clk)
  begin
    if (rst)
    begin
      for (i = 0; i < regSize; i = i + 1)
        csRegisters[i] <= 32'b0;
    end
    else
    begin
      csRegisters[3] <= csRegisters[3] + 1; //cycle count
      if(wEn)
      begin
        csRegisters[wAddr[3:0]] <= wData;
      end
      csRegisters[0] <= csRegisters[0] + {31'b0,wrongBranch};
      csRegisters[1] <= csRegisters[1] + {31'b0,controlXfer};
      csRegisters[2] <= csRegisters[2] + {31'b0,validInst};
    end
  end

endmodule
