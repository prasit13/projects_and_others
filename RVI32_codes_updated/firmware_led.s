# ============================================================================
# firmware_led.s  ->  firmware.hex
#
# Original bring-up program. Exercises the ALU, the register file, immediate
# generation and the memory-mapped store path by computing 5 + 7 and writing
# the result to the LED register at 0x1000_0000.
#
# Build:  python asm.py firmware_led.s firmware.hex
# ============================================================================

        addi x1, x0, 5          # x1 = 5
        addi x2, x0, 7          # x2 = 7
        add  x3, x1, x2         # x3 = 12
        lui  x4, 0x10000        # x4 = 0x1000_0000  (LED base)
        sw   x3, 0(x4)          # LED register = 12
spin:   jal  x0, spin           # halt
        nop
        nop
