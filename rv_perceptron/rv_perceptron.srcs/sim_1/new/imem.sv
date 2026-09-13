`timescale 1ns/1ps
module imem #(
    parameter DEPTH = 16383  //16K for now
  )(
    output logic [31:0] rData,
    input logic [31:0] rAddr,
    input logic clk
  );
  localparam ADDR_WIDTH = $clog2(DEPTH);
  logic [31:0] mem [0:DEPTH-1];
  assign rData = mem[rAddr[ADDR_WIDTH+1:2]];

  integer z;
  initial
  begin
    // fill with NOP (addi x0,x0,0) so fetching past the image is harmless
    for (z = 0; z < DEPTH; z = z + 1)
      mem[z] = 32'h00000013;
    $readmemh("code.mem",mem);
  end

endmodule
