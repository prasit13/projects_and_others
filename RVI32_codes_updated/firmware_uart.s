# ============================================================================
# firmware_uart.s  ->  firmware_uart.hex
#
# UART echo. Waits for a byte to arrive on the receiver, mirrors it to the
# LEDs so the result is observable on hardware, acknowledges the receiver so
# it can accept the next byte, then transmits the same byte back out.
#
# Exercises the full poll-and-acknowledge handshake against both UART
# peripherals through ordinary loads and stores -- no I/O opcodes.
#
# Build:  python asm.py firmware_uart.s firmware_uart.hex
# ============================================================================

        lui  x1, 0x70000        # RX STATUS  (bit 0 = data valid)
        lui  x2, 0x50000        # RX DATA
        lui  x3, 0x60000        # RX CTRL    (bit 0 = ready / acknowledge)
        lui  x4, 0x10000        # LED
        lui  x5, 0x40000        # TX STATUS  (bit 0 = ready)
        lui  x6, 0x20000        # TX DATA
        lui  x7, 0x30000        # TX CTRL    (bit 0 = valid / start)
        addi x8, x0, 1          # constant 1

poll_rx:
        lw   x9, 0(x1)          # read RX status
        beq  x9, x0, poll_rx    # spin until a byte has arrived

        lw   x10, 0(x2)         # x10 = received byte
        sw   x10, 0(x4)         # mirror it to the LEDs
        sw   x8,  0(x3)         # acknowledge: RX CTRL = 1
        sw   x0,  0(x3)         # release:     RX CTRL = 0

poll_tx:
        lw   x11, 0(x5)         # read TX status
        beq  x11, x0, poll_tx   # spin until the transmitter is idle

        sw   x10, 0(x6)         # TX DATA = the received byte
        sw   x8,  0(x7)         # TX CTRL = 1  (start transmission)
        sw   x0,  0(x7)         # TX CTRL = 0  (clear valid)

spin:   jal  x0, spin           # halt
