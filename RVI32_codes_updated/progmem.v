// ==========================================
// Module: progmem
// Description: Program Memory for RISC-V processor
//              Supports byte-wise write and word-wise read
// ==========================================

module progmem(
    input rst,                  // Active-high reset signal
    input clk,                  // Clock signal
    input [31:0] addr,          // Address input for memory access (byte address)
    input [31:0] data_in,       // Data to be written to memory (write input)
    input rd_strobe,            // Read strobe: when high, triggers a read from memory
    input [3:0] wr_strobe,      // Write strobe: 4-bit signal to enable byte-wise writes
    output reg [31:0] data_out  // Data output from memory (read result)
);

  // Define the number of 32-bit words in memory
  parameter MEM_SIZE = 1024;

  // Declare the actual memory:
  // PROGMEM is an array of 1024 words, each 32 bits wide
  reg [31:0] PROGMEM[0:MEM_SIZE-1];

  // Calculate word-aligned memory index from the address
  // Since each word is 4 bytes, ignore the bottom 2 bits of the address
  wire [29:0] mem_loc = addr[31:2];

  // Initial block to load memory contents at simulation start
  initial begin
    // Read hex values from a file named "firmware.hex" into the PROGMEM array
    // Each line in firmware.hex should contain a 32-bit instruction/data in hexadecimal
    $readmemh("firmware.hex", PROGMEM);
  end

  // Sequential read logic (word-wise read)
  always @(posedge clk) begin
    if (rst) begin
      // On reset, clear data_out
      data_out <= 32'h0;
    end
    else if (rd_strobe) begin
      // On read strobe, read from memory at the calculated location
      data_out <= PROGMEM[mem_loc];
    end
  end

  // Sequential write logic (byte-wise write)
  // Each wr_strobe bit controls writing a corresponding byte
  always @(posedge clk) begin
    if (wr_strobe[0]) begin
      // Write lower byte (bits [7:0])
      PROGMEM[mem_loc][7:0] <= data_in[7:0];
    end
    if (wr_strobe[1]) begin
      // Write next byte (bits [15:8])
      PROGMEM[mem_loc][15:8] <= data_in[15:8];
    end
    if (wr_strobe[2]) begin
      // Write next byte (bits [23:16])
      PROGMEM[mem_loc][23:16] <= data_in[23:16];
    end
    if (wr_strobe[3]) begin
      // Write upper byte (bits [31:24])
      PROGMEM[mem_loc][31:24] <= data_in[31:24];
    end
  end

endmodule
