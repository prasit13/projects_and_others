// ==========================================================
// Module: uart_tx
// Description: UART Transmitter
// Sends 8-bit serial data using 1 start bit, 8 data bits, 1 stop bit
// Clock divider is calculated based on clk_freq_hz and baud_rate
// ==========================================================

module uart_tx
#(
    parameter clk_freq_hz = 27 * 1000000,  // Clock frequency in Hz (default 27 MHz)
    parameter baud_rate = 9600             // Baud rate for UART (bits/sec)
)
(
    input wire        i_clk,       // Clock input
    input wire        i_rst,       // Asynchronous reset
    input wire [7:0]  i_data,      // Byte to transmit
    input wire        i_valid,     // High to start transmission
    output reg        o_ready,     // High when ready for new byte
    output wire       o_uart_tx    // UART TX output
);

  // ---------------------------------------------------------
  // Internal Parameter Setup
  // ---------------------------------------------------------

  // Calculate how many clock cycles = 1 baud period
  localparam START_VALUE = clk_freq_hz / baud_rate;

  // Determine number of bits needed to count up to START_VALUE
  localparam WIDTH = $clog2(START_VALUE);

  // ---------------------------------------------------------
  // Internal Registers
  // ---------------------------------------------------------
  reg [WIDTH:0] cnt;       // Baud rate counter
  reg [9:0] data;          // Shift register: [0]=start, [8:1]=data, [9]=stop

  // UART TX pin assignment:
  // - If not transmitting, drive '1' (idle state)
  // - Otherwise send LSB (data[0]) of shift register
  assign o_uart_tx = data[0] | !(|data);  // If data == 0 => idle => 1

  // ---------------------------------------------------------
  // Sequential Logic
  // ---------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst) begin
      // Reset all internal registers
      cnt <= {WIDTH{1'b0}};
      data <= 10'b0;
      o_ready <= 1'b1; // Ready after reset
    end
    else begin
      // 1. READY signal control
      if (cnt[WIDTH] && !(|data)) // Finished previous transmission
        o_ready <= 1'b1;
      else if (i_valid && o_ready) // Start of new transmission
        o_ready <= 1'b0;

      // 2. Counter logic for baud timing
      if (o_ready || cnt[WIDTH])
        cnt <= {1'b0, START_VALUE[WIDTH-1:0]};  // Reload counter
      else
        cnt <= cnt - 1;

      // 3. Shift logic
      if (cnt[WIDTH]) begin
        // Each time baud tick happens, shift right
        data <= {1'b0, data[9:1]};
      end
      else if (i_valid && o_ready) begin
        // Load new byte to transmit if ready and valid asserted
        // Format: [STOP][DATA][START] = 1 i_data 0
        data <= {1'b1, i_data, 1'b0};  // 10 bits total
      end
    end
  end

endmodule
