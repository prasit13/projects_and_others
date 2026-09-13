module registerFile(
    output logic [31:0] reg1,
    output logic [31:0] reg2,
    input logic [31:0] writeData,
    input logic [4:0] addr1,
    input logic [4:0] addr2,
    input logic [4:0] writeAddr,
    input logic writeEn,
    input logic clk
  );
  logic negClk;
  logic [31:0] registers [31:0];
  integer z;
  initial
    for (z = 0; z < 32; z = z + 1)
      registers[z] = 32'b0;
  assign reg1 = |addr1 ? registers[addr1] : 0;
  assign reg2 = |addr2 ? registers[addr2] : 0;
  assign negClk = !clk;
  always@(posedge negClk)
  begin
    if (writeEn & |writeAddr)
      registers[writeAddr] <= writeData;
  end
endmodule
