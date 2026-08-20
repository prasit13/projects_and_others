// ========================================================
// Module: uart_rx_gpio
// Description: Memory-mapped interface for UART receiver
// Address map:
//   0x5000_0000 - RXDATA    : Read 8-bit received UART data
//   0x6000_0000 - RXCTRL    : Write control (enable reception)
//   0x7000_0000 - RXSTATUS  : Read status (1 if data ready)
// ========================================================
`include "uart_rx.v"
module uart_rx_gpio(
    input [31:0] addr,          // Address bus for memory-mapped access
    input rst, clk,             // Reset and clock signals
    input [31:0] data_in,       // Data input (only used for RXCTRL writes)
    input rd_strobe,            // Read enable signal
    input [3:0] wr_strobe,      // Write enable signal (byte-wise, any high bit triggers write)
    output reg [31:0] data_out, // Data output (RXDATA or RXSTATUS)
    input uart_rx               // Serial input pin (connected to UART RX line)
);

  // Internal registers to hold UART state
  reg [31:0] uart_data;       // Holds the received data (not used explicitly here)
  reg [31:0] uart_status;     // Holds UART status (not used explicitly here)
  reg [31:0] uart_control;    // Control register (only bit 0 used)

  // Address decoding: determine which register is being accessed
  wire isUART_RXDATA   = (addr[31:28] == 4'b0101); // 0x5000_0000
  wire isUART_RXCTRL   = (addr[31:28] == 4'b0110); // 0x6000_0000
  wire isUART_RXSTATUS = (addr[31:28] == 4'b0111); // 0x7000_0000

  // Signals from UART RX module
  wire [7:0] rx_data;     // 8-bit data received from serial
  wire o_ready;           // Data ready flag from UART RX module

  // Initialize control register on startup
  initial begin
    uart_control <= 0;
  end

  // Sequential logic for read/write operations
  always @(posedge clk) begin
    if (rst) begin
      // On reset, clear control register (don't need to clear status/data)
      uart_control <= 0;
    end

    // Read from RXSTATUS register
    if (rd_strobe && isUART_RXSTATUS) begin
      // Output 1 if UART RX has data ready, else 0
      data_out <= o_ready;
    end

    // Read from RXDATA register
    if (rd_strobe && isUART_RXDATA) begin
      // Output 8-bit received data (upper 24 bits are zero)
      data_out <= {24'h0, rx_data};
    end

    // Write to RXCTRL register
    if (|wr_strobe && isUART_RXCTRL) begin
      // Store control configuration (e.g., bit 0 = rx_data_ready)
      uart_control <= data_in;
    end
  end

  // ===============================
  // UART Receiver Instantiation
  // ===============================
  // This module handles actual serial reception and outputs:
  // - rx_data: 8-bit received data
  // - rx_data_valid (o_ready): asserted high when a byte is received
  // - rx_data_ready: from software (bit 0 of uart_control) to acknowledge receipt
  uart_rx rx0 (
    .clk(clk), 
    .rst_n(!rst),                 // Active-low reset for UART
    .rx_data(rx_data),           // Received byte
    .rx_data_valid(o_ready),     // Valid pulse when byte is ready
    .rx_data_ready(uart_control[0]), // Software-controlled ready signal
    .rx_pin(uart_rx)             // Serial input from external device
  );

endmodule
