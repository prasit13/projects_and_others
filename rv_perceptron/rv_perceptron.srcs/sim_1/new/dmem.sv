`timescale 1ns/1ps
//==========================================================================
// dmem -- byte-addressable data memory
//
// The read path is expressed as four continuous assignments feeding a small
// always_comb rather than indexing the array inside the always_comb itself.
// Functionally identical, but it keeps the process sensitive to four bytes
// instead of all 32768, which is what let Icarus elaborate this module in
// under a second instead of several minutes.
//
// Also fixes the LB sign-extension, which previously took its sign bit from
// mem[addr] (an un-offset address, always out of range and therefore x)
// while taking the data from mem[addrMinusOff].
//==========================================================================
module dmem #(
    parameter DEPTH = 32 //32K
  )(
    input logic [31:0] wData,
    output logic [31:0] rData,
    input logic [31:0] addr,
    input logic [2:0] size,
    input logic clk,
    input logic wEn
  );
  logic [7:0] mem [(1024*DEPTH)-1:0];
  logic [31:0] addrplus1;
  logic [31:0] addrplus2;
  logic [31:0] addrplus3;
  logic [31:0] addrMinusOff;

  assign addrMinusOff = {4'b0,addr[27:0]};
  assign addrplus1 = addrMinusOff + 1;
  assign addrplus2 = addrMinusOff + 2;
  assign addrplus3 = addrMinusOff + 3;

  // narrow read ports -> small sensitivity list downstream
  logic [7:0] b0, b1, b2, b3;
  assign b0 = mem[addrMinusOff];
  assign b1 = mem[addrplus1];
  assign b2 = mem[addrplus2];
  assign b3 = mem[addrplus3];

  always_ff@(posedge clk)
  begin
    if(wEn)
    begin
      case (size)
        3'b000:
          mem[addrMinusOff] <= wData[7:0];
        3'b001:
        begin
          mem[addrMinusOff] <= wData[7:0];
          mem[addrplus1] <= wData[15:8];
        end
        3'b010:
        begin
          mem[addrMinusOff] <= wData[7:0];
          mem[addrplus1] <= wData[15:8];
          mem[addrplus2] <= wData[23:16];
          mem[addrplus3] <= wData[31:24];
        end
        default:
          ;
      endcase
    end
  end

  always_comb
  begin
    case (size)
      3'b000:
        rData = {{24{b0[7]}},b0};          // LB
      3'b001:
        rData = {{16{b1[7]}},b1,b0};       // LH
      3'b010:
        rData = {b3,b2,b1,b0};             // LW
      3'b100:
        rData = {24'b0,b0};                // LBU
      3'b101:
        rData = {16'b0,b1,b0};             // LHU
      default :
        rData = 32'hDEADC0DE;
    endcase
  end

  // Zero the array before loading the image. .bss is not in data.mem, so
  // without this every uninitialised global reads as x. (Verilator zeroed
  // state implicitly, which is why the old flow did not trip over this.)
  integer z;
  initial
  begin
    for (z = 0; z < (1024*DEPTH); z = z + 1)
      mem[z] = 8'h00;
    $readmemh("data.mem",mem);
  end
endmodule
