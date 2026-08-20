// ==================================================================
// Module: uart_rx
// Description: UART Receiver Module
// Receives serial data (`rx_pin`) at given `BAUD_RATE` and converts
// it to parallel 8-bit data (`rx_data`). Includes valid/data ready handshaking.
// ==================================================================

module uart_rx
#(
    parameter CLK_FRE = 27,       // Clock frequency in MHz
    parameter BAUD_RATE = 9600    // UART baud rate (bits per second)
)
(
    input clk,                    // System clock
    input rst_n,                  // Active-low reset
    output reg [7:0] rx_data,     // Received byte
    output reg rx_data_valid,     // High when rx_data is valid
    input rx_data_ready,          // Handshake: high when receiver has accepted the data
    input rx_pin                  // Serial input (UART RX line)
);

// Calculate how many clock cycles correspond to one baud tick
localparam CYCLE = CLK_FRE * 1_000_000 / BAUD_RATE;

// FSM States
localparam S_IDLE      = 1;   // Wait for start bit
localparam S_START     = 2;   // Sample start bit
localparam S_REC_BYTE  = 3;   // Receive 8 data bits
localparam S_STOP      = 4;   // Sample stop bit
localparam S_DATA      = 5;   // Wait for host to read data

reg [2:0] state, next_state;   // FSM state registers

// Used for edge detection (to detect falling edge of rx_pin)
reg rx_d0, rx_d1;
wire rx_negedge;               // High when falling edge on rx_pin detected

// Data sampling
reg [7:0] rx_bits;             // Shift register to collect serial bits
reg [15:0] cycle_cnt;          // Counts clock cycles for baud timing
reg [2:0] bit_cnt;             // Counts received bits (0 to 7)

// ----------------------------------------------------------
// Edge Detection Logic: Detect falling edge of rx_pin (start bit)
// ----------------------------------------------------------
assign rx_negedge = rx_d1 && ~rx_d0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_d0 <= 1'b0;
        rx_d1 <= 1'b0;
    end else begin
        rx_d0 <= rx_pin;
        rx_d1 <= rx_d0;
    end
end

// ----------------------------------------------------------
// FSM State Update
// ----------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= S_IDLE;
    else
        state <= next_state;
end

// ----------------------------------------------------------
// FSM Next State Logic
// ----------------------------------------------------------
always @(*) begin
    case(state)
        S_IDLE:
            next_state = rx_negedge ? S_START : S_IDLE;

        S_START:
            next_state = (cycle_cnt == CYCLE - 1) ? S_REC_BYTE : S_START;

        S_REC_BYTE:
            next_state = (cycle_cnt == CYCLE - 1 && bit_cnt == 3'd7) ? S_STOP : S_REC_BYTE;

        S_STOP:
            next_state = (cycle_cnt == (CYCLE/2 - 1)) ? S_DATA : S_STOP;

        S_DATA:
            next_state = rx_data_ready ? S_IDLE : S_DATA;

        default:
            next_state = S_IDLE;
    endcase
end

// ----------------------------------------------------------
// Output: rx_data_valid
// ----------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rx_data_valid <= 1'b0;
    else if (state == S_STOP && next_state != state)
        rx_data_valid <= 1'b1;   // Data is ready after stop bit
    else if (state == S_DATA && rx_data_ready)
        rx_data_valid <= 1'b0;   // Clear once host accepts data
end

// ----------------------------------------------------------
// Output: rx_data
// ----------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rx_data <= 8'd0;
    else if (state == S_STOP && next_state != state)
        rx_data <= rx_bits;      // Latch the full byte
end

// ----------------------------------------------------------
// Bit Counter: Tracks number of bits received (0–7)
// ----------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        bit_cnt <= 3'd0;
    else if (state == S_REC_BYTE)
        bit_cnt <= (cycle_cnt == CYCLE - 1) ? bit_cnt + 1 : bit_cnt;
    else
        bit_cnt <= 3'd0;
end

// ----------------------------------------------------------
// Baud Cycle Counter: Resets at end of each bit or state
// ----------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        cycle_cnt <= 16'd0;
    else if ((state == S_REC_BYTE && cycle_cnt == CYCLE - 1) || next_state != state)
        cycle_cnt <= 16'd0;
    else
        cycle_cnt <= cycle_cnt + 1;
end

// ----------------------------------------------------------
// Serial Bit Sampling: Sample at middle of each bit
// ----------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rx_bits <= 8'd0;
    else if (state == S_REC_BYTE && cycle_cnt == (CYCLE / 2 - 1))
        rx_bits[bit_cnt] <= rx_pin; // Sample the bit
end

endmodule
