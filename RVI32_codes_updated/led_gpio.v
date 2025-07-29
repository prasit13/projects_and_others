// ==========================================
// Module: led_gpio
// Description: Simple memory-mapped LED GPIO controller
// Target Address: 0x1000_0000
// Maps lower 8 bits of a 32-bit register to onboard LEDs
// ==========================================

module led_gpio(
    input [31:0] addr,         // Address bus (not used internally, fixed address externally mapped)
    input rst, clk,            // Reset and clock
    input [31:0] data_in,      // Data input for writing to LED register
    input rd_strobe,           // Read enable signal
    input [3:0] wr_strobe,     // Write strobe (any non-zero value triggers write)
    output reg [31:0] data_out,// Output data from the LED register (for memory-mapped read)
    output [7:0] leds          // 8-bit output connected to onboard LEDs
);

  // 32-bit internal register to hold LED states
  reg [31:0] led_data_reg;

  // Sequential logic to update or read LED register
  always @(posedge clk) begin
    if (rst) begin
      // On reset, clear LED register
      led_data_reg <= 32'b0;
    end else if (rd_strobe) begin
      // On read request, send the LED register value to data_out
      data_out <= led_data_reg;
    end else if (|wr_strobe) begin
      // On write request (any write strobe bit is high), latch data_in into LED register
      // Note: All 32 bits are stored, but only lower 8 bits are used for LEDs
      led_data_reg <= data_in;
    end
  end

  // Drive the LEDs using the lower 8 bits of the LED register
  assign leds = led_data_reg[7:0];

endmodule
