// ========================================================
// Module: uart_tx_gpio
// Description: UART Transmitter GPIO Interface
// Address map:
//   0x2000_0000 - DATA     : Write the 8-bit data to transmit
//   0x3000_0000 - CTRL     : Control register (bit 0 = valid signal)
//   0x4000_0000 - STATUS   : Read status (bit 0 = ready to send next byte)
// This wraps the uart_tx module.
// ========================================================
`include "uart_tx.v"
module uart_tx_gpio(
    input [31:0] addr,         // Address from memory-mapped CPU
    input rst, clk,            // Reset and clock
    input [31:0] data_in,      // Data to write (either to DATA or CTRL)
    input rd_strobe,           // Memory-mapped read enable
    input [3:0] wr_strobe,     // Memory-mapped write strobe (any bit high => write)
    output reg [31:0] data_out,// Output data from STATUS register
    output tx_pin              // UART TX output line
);

  // Internal registers
  reg [31:0] uart_data;       // Holds byte to transmit (only lower 8 bits used)
  reg [31:0] uart_control;    // Holds control flags (bit 0 = valid signal)

  // Memory address decoding
  wire isUART_DATA   = (addr[31:28] == 4'b0010); // 0x2000_0000
  wire isUART_CTRL   = (addr[31:28] == 4'b0011); // 0x3000_0000
  wire isUART_STATUS = (addr[31:28] == 4'b0100); // 0x4000_0000

  // Signals to UART transmitter
  wire [7:0] tx_data = uart_data[7:0];   // Data byte to be sent
  wire valid         = uart_control[0]; // Assert high to start transmission
  wire o_ready;                         // High when transmitter is ready for new byte

  // --------------------------------------------------------
  // Initialization
  // --------------------------------------------------------
  initial begin
    uart_data    <= 32'b0;
    uart_control <= 32'b0;
  end

  // --------------------------------------------------------
  // Memory-mapped register access (read/write)
  // --------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      uart_data    <= 32'b0;
      uart_control <= 32'b0;
    end

    // Read STATUS register
    if (rd_strobe && isUART_STATUS) begin
      data_out <= {31'b0, o_ready}; // Bit 0 = ready flag
    end

    // Write to DATA register
    if (|wr_strobe && isUART_DATA) begin
      uart_data <= data_in;         // Only lower 8 bits are used
    end

    // Write to CTRL register
    if (|wr_strobe && isUART_CTRL) begin
      uart_control <= data_in;      // Bit 0: valid signal
    end
  end

  // --------------------------------------------------------
  // UART transmitter instantiation
  // --------------------------------------------------------
  // Handles the actual serial transmission
  uart_tx tx0 (
    .i_clk(clk),           // Clock input
    .i_rst(rst),           // Reset input
    .i_data(tx_data),      // Data byte to transmit
    .i_valid(valid),       // High to start transmission
    .o_ready(o_ready),     // High when UART is ready for next byte
    .o_uart_tx(tx_pin)     // Serial output
  );

endmodule
