#!/usr/bin/env python3
"""
Minimal RV32I assembler for this SoC.

Assembles the instruction subset the test firmware needs (lui, addi, add, lw,
sw, beq, bne, jal) into the flat hex-word format that progmem.v expects via
$readmemh. Supports labels and two-pass resolution.

Usage:
    python asm.py <source.s> <output.hex>
    python asm.py --selftest          # verify against the known-good firmware

Rationale: the original firmware.hex was a hand-assembled blob with no record
of what it contained. Keeping the source alongside an assembler makes the test
programs reviewable and lets new ones be written without hand-encoding.
"""

import re
import sys

REGS = {f"x{i}": i for i in range(32)}


def reg(tok):
    tok = tok.strip()
    if tok not in REGS:
        raise ValueError(f"bad register: {tok!r}")
    return REGS[tok]


def imm(tok, labels=None, pc=None, relative=False):
    tok = tok.strip()
    if labels is not None and tok in labels:
        return labels[tok] - pc if relative else labels[tok]
    return int(tok, 0)


def u_type(op, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def i_type(op, f3, rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def r_type(op, f7, f3, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(op, f3, rs1, rs2, imm12):
    i = imm12 & 0xFFF
    return (((i >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | ((i & 0x1F) << 7) | op


def b_type(op, f3, rs1, rs2, off):
    i = off & 0x1FFF
    return ((((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) |
            (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
            ((((i >> 1) & 0xF) << 8)) | (((i >> 11) & 1) << 7) | op)


def j_type(op, rd, off):
    i = off & 0x1FFFFF
    return ((((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) |
            (((i >> 11) & 1) << 20) | (((i >> 12) & 0xFF) << 12) |
            (rd << 7) | op)


def assemble(text):
    # ---- pass 1: strip comments, collect labels ----
    lines, labels, pc = [], {}, 0
    for raw in text.splitlines():
        line = raw.split("#")[0].strip()
        if not line:
            continue
        while ":" in line:
            label, _, line = line.partition(":")
            labels[label.strip()] = pc
            line = line.strip()
        if line:
            lines.append((pc, line))
            pc += 4

    # ---- pass 2: encode ----
    words = []
    for pc, line in lines:
        mnem, _, rest = line.partition(" ")
        mnem = mnem.lower()
        args = [a.strip() for a in rest.split(",")] if rest.strip() else []

        if mnem == "nop":
            words.append(i_type(0x13, 0, 0, 0, 0))
        elif mnem == "lui":
            words.append(u_type(0x37, reg(args[0]), imm(args[1])))
        elif mnem == "addi":
            words.append(i_type(0x13, 0, reg(args[0]), reg(args[1]), imm(args[2])))
        elif mnem == "add":
            words.append(r_type(0x33, 0, 0, reg(args[0]), reg(args[1]), reg(args[2])))
        elif mnem in ("lw", "sw"):
            m = re.fullmatch(r"(-?\w+)\((x\d+)\)", args[1])
            if not m:
                raise ValueError(f"bad memory operand: {args[1]!r}")
            offset, base = int(m.group(1), 0), reg(m.group(2))
            if mnem == "lw":
                words.append(i_type(0x03, 2, reg(args[0]), base, offset))
            else:
                words.append(s_type(0x23, 2, base, reg(args[0]), offset))
        elif mnem in ("beq", "bne"):
            f3 = 0 if mnem == "beq" else 1
            off = imm(args[2], labels, pc, relative=True)
            words.append(b_type(0x63, f3, reg(args[0]), reg(args[1]), off))
        elif mnem == "jal":
            off = imm(args[1], labels, pc, relative=True)
            words.append(j_type(0x6F, reg(args[0]), off))
        else:
            raise ValueError(f"unsupported mnemonic: {mnem!r}")
    return words


GOLDEN_LED = """
    addi x1, x0, 5
    addi x2, x0, 7
    add  x3, x1, x2
    lui  x4, 0x10000
    sw   x3, 0(x4)
spin: jal x0, spin
    nop
    nop
"""

GOLDEN_LED_HEX = ["00500093", "00700113", "002081b3", "10000237",
                  "00322023", "0000006f", "00000013", "00000013"]


def selftest():
    got = [f"{w:08x}" for w in assemble(GOLDEN_LED)]
    ok = got == GOLDEN_LED_HEX
    for i, (g, e) in enumerate(zip(got, GOLDEN_LED_HEX)):
        print(f"  [{'ok ' if g == e else 'BAD'}] {i:2d}  got {g}  expect {e}")
    print("SELFTEST PASSED" if ok else "SELFTEST FAILED")
    return 0 if ok else 1


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        return selftest()
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    with open(sys.argv[1]) as f:
        words = assemble(f.read())
    with open(sys.argv[2], "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")
    print(f"{sys.argv[1]} -> {sys.argv[2]}  ({len(words)} instructions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
