`timescale 1ns / 1ps
// ============================================================================
// tb_soc.v -- system-level self-checking testbench
//
// Runs real firmware across the assembled bus and asserts the resulting
// architectural state automatically. This is the level at which the store
// address-generation defect was found: the peripherals were correct in
// isolation and the CPU executed arithmetic correctly, but the interface
// between them was not exercised until firmware ran end to end.
//
// TEST 1  LED path      -- firmware.hex computes 5+7 and stores it to the LED
//                          region. Checks the register, the output pins, and
//                          that the LED read-back reaches cpu_rdata.
//
// TEST 2  UART echo     -- firmware_uart.hex polls the receiver, mirrors the
//                          byte to the LEDs, acknowledges, and retransmits it.
//                          The bench drives a real 9600-baud frame in and
//                          decodes the frame that comes back out.
//
// Run:  iverilog -I. -o tb_soc.out tb_soc.v top.v && vvp tb_soc.out
// ============================================================================

module tb_soc;

  // Bit period in clock cycles: 27 MHz / 9600 baud, matching the defaults in
  // uart_tx.v and uart_rx.v.
  localparam integer BIT_CLKS = 27_000_000 / 9600;   // 2812
  localparam [7:0]   TEST_BYTE = 8'h5A;

  reg clk = 1'b0;
  always #5 clk = ~clk;                              // 100 MHz simulation clock

  integer errors = 0;
  integer checks = 0;

  task check;
    input [255:0] label;
    input [31:0]  got;
    input [31:0]  exp;
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("  [FAIL] %0s : got %08h, expected %08h", label, got, exp);
      end else begin
        $display("  [ PASS] %0s", label);
      end
    end
  endtask

  // --------------------------------------------------------------------
  // DUT 1 : LED bring-up firmware
  // --------------------------------------------------------------------
  reg  led_rst = 1'b0;                               // active LOW at this port
  wire [5:0] led_pins;
  top #(.MEM_FILE("firmware.hex")) dut_led (
    .rst(led_rst), .clk(clk), .uart_rx(1'b1),
    .uart_tx(), .LEDS(led_pins)
  );

  // Continuously verify the LED read-back reaches the CPU whenever the LED
  // region is addressed. Before the fix this fell through to 32'h0.
  reg led_readback_seen = 1'b0;
  always @(posedge clk) begin
    if (dut_led.isLED) begin
      led_readback_seen <= 1'b1;
      if (dut_led.cpu_rdata !== dut_led.led_rdata) begin
        errors = errors + 1;
        $display("  [FAIL] LED read-back: cpu_rdata=%08h != led_rdata=%08h",
                 dut_led.cpu_rdata, dut_led.led_rdata);
      end
    end
  end

  // --------------------------------------------------------------------
  // DUT 2 : UART echo firmware
  // --------------------------------------------------------------------
  reg  uart_rst  = 1'b0;                             // active LOW at this port
  reg  serial_in = 1'b1;                             // idle high
  wire serial_out;
  wire [5:0] uart_pins;
  top #(.MEM_FILE("firmware_uart.hex")) dut_uart (
    .rst(uart_rst), .clk(clk), .uart_rx(serial_in),
    .uart_tx(serial_out), .LEDS(uart_pins)
  );

  // These tasks run concurrently inside a fork/join below, so they must be
  // `automatic`: a static task would share its loop counter between the two
  // threads and corrupt both.
  task automatic wait_clks;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  // Drive one 8N1 frame into the receiver, LSB first.
  task automatic send_frame;
    input [7:0] b;
    integer i;
    begin
      serial_in = 1'b0;                              // start bit
      wait_clks(BIT_CLKS);
      for (i = 0; i < 8; i = i + 1) begin
        serial_in = b[i];
        wait_clks(BIT_CLKS);
      end
      serial_in = 1'b1;                              // stop bit
      wait_clks(BIT_CLKS);
    end
  endtask

  // Wait for a start bit on the transmitter and recover the byte by sampling
  // at the midpoint of each bit period.
  task automatic recv_frame;
    output [7:0] b;
    integer i;
    begin
      b = 8'h00;
      @(negedge serial_out);                         // start bit edge
      wait_clks(BIT_CLKS + BIT_CLKS/2);              // centre of data bit 0
      for (i = 0; i < 8; i = i + 1) begin
        b[i] = serial_out;
        if (i < 7) wait_clks(BIT_CLKS);
      end
    end
  endtask

  // --------------------------------------------------------------------
  // Stimulus
  // --------------------------------------------------------------------
  reg [7:0] echoed;

  initial begin
    $display("");
    $display("==========================================================");
    $display(" RV32I SoC -- system-level testbench");
    $display(" %0d clocks per bit (27 MHz / 9600 baud)", BIT_CLKS);
    $display("==========================================================");

    // ---- TEST 1 : LED path ------------------------------------------
    $display("\n---- TEST 1: LED store path (firmware.hex) ----");
    led_rst = 1'b0;
    wait_clks(4);
    led_rst = 1'b1;                                  // release reset
    wait_clks(80);                                   // 6 instructions, worst case

    check("LED register holds 5 + 7",      dut_led.led0.led_data_reg, 32'd12);
    check("LED pins show active-low 12",   {26'b0, led_pins},         32'b110011);
    check("store decoded to LED region",   {31'b0, led_readback_seen}, 32'd1);

    // ---- TEST 2 : UART echo -----------------------------------------
    $display("\n---- TEST 2: UART echo (firmware_uart.hex) ----");
    uart_rst = 1'b0;
    wait_clks(4);
    uart_rst = 1'b1;
    wait_clks(20);

    $display("  driving 0x%02h into uart_rx ...", TEST_BYTE);

    // The firmware can begin retransmitting while the inbound stop bit is
    // still on the wire, so the transmit line must be watched from before the
    // echo starts -- otherwise the receiver task latches a mid-frame edge and
    // recovers a rotated byte.
    fork
      recv_frame(echoed);
      begin
        send_frame(TEST_BYTE);
        // Firmware needs a few instructions to poll, read, mirror, acknowledge.
        wait_clks(400);
        check("received byte mirrored to LEDs",
              dut_uart.led0.led_data_reg, {24'h0, TEST_BYTE});
        $display("  waiting for uart_tx to echo it back ...");
      end
    join

    $display("  recovered 0x%02h from uart_tx", echoed);
    check("echoed byte matches", {24'h0, echoed}, {24'h0, TEST_BYTE});

    // ---- summary -----------------------------------------------------
    $display("");
    $display("==========================================================");
    $display(" checks run : %0d", checks);
    $display(" failures   : %0d", errors);
    if (errors == 0) $display(" RESULT     : *** ALL TESTS PASSED ***");
    else             $display(" RESULT     : *** %0d TEST(S) FAILED ***", errors);
    $display("==========================================================");
    $display("");
    $finish;
  end

  // Watchdog: two full frames plus firmware overhead is well under 200 000
  // clocks, so anything beyond that means the DUT is stuck.
  initial begin
    #(10 * 200000);
    $display("[FATAL] watchdog expired -- DUT appears hung");
    $display(" RESULT     : *** WATCHDOG TIMEOUT ***");
    $finish;
  end

endmodule
