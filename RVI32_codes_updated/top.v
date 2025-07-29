// ============================================================================
// Module: top
// Description: Top-level SoC integrating a RISC-V CPU with UART and LED GPIO
// Functionality:
//   - Receives characters via UART RX
//   - Displays received characters via UART TX
//   - If received character is '0' to '9', displays on LEDs
// ============================================================================
`include "cpu.v"
`include "progmem.v"
`include "uart_tx_gpio.v"
`include "uart_rx_gpio.v"
`include "led_gpio.v"
module top(
    input rst, clk,           // Reset (active high), and system clock
    input uart_rx,            // UART receive pin
    output uart_tx,           // UART transmit pin
    output [5:0] LEDS         // 6 onboard LED outputs
);

  // -------------------------------
  // Internal Wires
  // -------------------------------
  wire [31:0] mem_rdata;     // Data from program memory
  wire [31:0] mem_wdata;     // Data to be written to memory/peripherals
  wire [31:0] addr;          // Address from CPU
  wire        rstrb;         // Read enable from CPU
  wire [3:0]  wr_strobe;     // Write enable byte-wise from CPU
  wire [31:0] uart_txstatus; // Data read from UART TX status register
  wire [31:0] uart_rx_data;  // Data read from UART RX data/status register
  wire [31:0] led_rdata;     // Data read from LED register

  // -------------------------------
  // Device Address Decoding
  // -------------------------------
  // Address upper 4 bits used to identify peripherals
  wire isMEM            = (addr[31:28] == 4'b0000); // Program memory
  wire isLED            = (addr[31:28] == 4'b0001); // LED GPIO
  wire isUART_RXDATA    = (addr[31:28] == 4'b0101); // UART RX Data
  wire isUART_RXSTATUS  = (addr[31:28] == 4'b0111); // UART RX Status
  wire isUART_TXSTATUS  = (addr[31:28] == 4'b0100); // UART TX Status

  // -------------------------------
  // Readback Multiplexing (for CPU reads)
  // Select which device's data to return based on address
  // -------------------------------
  wire [31:0] cpu_rdata = isUART_TXSTATUS                 ? uart_txstatus :
                          isMEM                           ? mem_rdata     :
                          (isUART_RXSTATUS | isUART_RXDATA) ? uart_rx_data :
                          32'h0;

  // -------------------------------
  // LED Output Handling
  // Note: LEDs are active-low on many boards (hence the ~)
  // -------------------------------
  wire [7:0] leds;
  assign LEDS = ~leds[5:0]; // Only using lower 6 bits of 8 LEDs

  // ==========================================================================
  // Submodule Instantiations
  // ==========================================================================

  // -------------------------------
  // CPU Core
  // -------------------------------
  cpu cpu0(
    .rst(!rst),           // Inverted reset since CPU expects active-low
    .clk(clk),
    .mem_rdata(cpu_rdata),// Data read from memory or peripheral
    .mem_addr(addr),      // Address bus
    .cycle(),             // Optional cycle counter (unused)
    .mem_rstrb(rstrb),    // Read strobe
    .mem_wdata(mem_wdata),// Data to be written
    .mem_wstrb(wr_strobe) // Write strobe
  );

  // -------------------------------
  // Program Memory
  // -------------------------------
  progmem mem0(
    .rst(!rst), .clk(clk),
    .addr(addr),
    .data_in(mem_wdata),
    .rd_strobe(rstrb & isMEM),                  // Only read if targeting memory
    .wr_strobe(wr_strobe & {4{isMEM}}),         // Write only if targeting memory
    .data_out(mem_rdata)
  );

  // -------------------------------
  // UART Transmitter GPIO
  // -------------------------------
  uart_tx_gpio uart_tx0(
    .rst(!rst), .clk(clk),
    .addr(addr),
    .data_in(mem_wdata),
    .rd_strobe(rstrb),      // TX GPIO handles address internally
    .wr_strobe(wr_strobe),
    .data_out(uart_txstatus),
    .tx_pin(uart_tx)        // Actual UART TX pin to outside world
  );

  // -------------------------------
  // UART Receiver GPIO
  // -------------------------------
  uart_rx_gpio uart_rx0(
    .rst(!rst), .clk(clk),
    .addr(addr),
    .data_in(mem_wdata),
    .rd_strobe(rstrb),      // RX GPIO handles address internally
    .wr_strobe(wr_strobe),
    .data_out(uart_rx_data),
    .uart_rx(uart_rx)       // Actual RX pin input from outside world
  );

  // -------------------------------
  // LED GPIO Peripheral
  // -------------------------------
  led_gpio led0(
    .rst(!rst), .clk(clk),
    .addr(addr),
    .data_in(mem_wdata),
    .rd_strobe(rstrb & isLED),                 // Enable read if address matches LED region
    .wr_strobe(wr_strobe & {4{isLED}}),        // Enable write if targeting LED region
    .data_out(led_rdata),
    .leds(leds)                                // Actual LED output bits
  );

endmodule
