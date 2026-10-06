#!/usr/bin/env python3
"""Generate the data tables embedded in hart_hazard_no_fwd_tb.v.

Standard library only. Run from anywhere:

    python3 scripts/gen_hazard_no_fwd.py             # validate, print report
    python3 scripts/gen_hazard_no_fwd.py --write     # ...and rewrite the
                                                     # GENERATED block in the tb
    python3 scripts/gen_hazard_no_fwd.py --emit-mock OUT.v [--mutant NAME]
                                                     # replay model of `hart`
                                                     # for testing the tb itself
                                                     # (never commit OUT.v)

What it does:
  1. Parses traces/hazard_program.hex and traces/hazard_no_fwd.trace into
     expected-retirement rows (Part A of the testbench).
  2. Contains a tiny RV32I encoder/decoder and ISS for the opcodes the tests
     use (addi add sub lui auipc lw sw beq bne ebreak), plus a timing model
     of a 5-stage pipeline with no forwarding and no rf bypass:
       - a consumer may retire no earlier than 4 cycles after the most recent
         producer of each register it actually reads, i.e. max(0, 4 - d)
         bubbles at distance d (3, 2, 1, 0),
       - 2 bubbles after a taken branch (resolved in EX),
       - in order, one retirement per cycle at most.
     "Reads rs1 / reads rs2 / writes rd" come from the decoded instruction
     class, never from raw bit fields, and writes to x0 produce nothing.
  3. Re-encodes every word in hazard_program.hex and checks it round-trips.
  4. Runs ISS + timing model on hazard_program.hex and diffs the result
     against hazard_no_fwd.trace, every cycle and every field.
  5. Builds the directed program (Part B) and its expected table from the
     same ISS + timing model, and emits Verilog for both parts.
"""

import argparse
import difflib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEX_PATH = os.path.join(ROOT, "traces", "hazard_program.hex")
TRACE_PATH = os.path.join(ROOT, "traces", "hazard_no_fwd.trace")
TB_PATH = os.path.join(ROOT, "hart_hazard_no_fwd_tb.v")

IMEM_BASE = 0x00400000
DMEM_BASE = 0x10010000
DMEM_WORDS = 256
FIRST_RETIRE_CYCLE = 6   # where hazard_no_fwd.trace puts its first retirement
EBREAK = 0x00100073
NOP = 0x00000013          # addi x0, x0, 0

BEGIN_MARK = "// BEGIN GENERATED"
END_MARK = "// END GENERATED"

M32 = 0xFFFFFFFF


# ---------------------------------------------------------------------------
# Encoder / decoder
# ---------------------------------------------------------------------------

# Instruction classes: which operands an instruction *architecturally* uses.
#                reads_rs1 reads_rs2 writes_rd
CLASS = {
    "addi":   (True,  False, True),
    "add":    (True,  True,  True),
    "sub":    (True,  True,  True),
    "lui":    (False, False, True),
    "auipc":  (False, False, True),
    "lw":     (True,  False, True),
    "sw":     (True,  True,  False),
    "beq":    (True,  True,  False),
    "bne":    (True,  True,  False),
    "ebreak": (False, False, False),
}


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def encode(op, rd=0, rs1=0, rs2=0, imm=0):
    if op in ("add", "sub"):
        f7 = 0x20 if op == "sub" else 0
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
    if op == "addi":
        assert -2048 <= imm < 2048
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13
    if op == "lw":
        assert -2048 <= imm < 2048
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03
    if op == "sw":
        assert -2048 <= imm < 2048
        i = imm & 0xFFF
        return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | \
               ((i & 0x1F) << 7) | 0x23
    if op in ("beq", "bne"):
        assert imm % 2 == 0 and -4096 <= imm < 4096
        i = imm & 0x1FFF
        f3 = 1 if op == "bne" else 0
        return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | \
               (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
               (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | 0x63
    if op in ("lui", "auipc"):
        assert 0 <= imm < (1 << 20)
        return (imm << 12) | (rd << 7) | (0x37 if op == "lui" else 0x17)
    if op == "ebreak":
        return EBREAK
    raise ValueError("cannot encode " + op)


def decode(w):
    """Return (op, rd, rs1, rs2, imm) with unused fields set to 0."""
    opc = w & 0x7F
    rd = (w >> 7) & 0x1F
    f3 = (w >> 12) & 7
    rs1 = (w >> 15) & 0x1F
    rs2 = (w >> 20) & 0x1F
    f7 = w >> 25
    if opc == 0x33 and f3 == 0 and f7 in (0, 0x20):
        return ("sub" if f7 else "add", rd, rs1, rs2, 0)
    if opc == 0x13 and f3 == 0:
        return ("addi", rd, rs1, 0, sext(w >> 20, 12))
    if opc == 0x03 and f3 == 2:
        return ("lw", rd, rs1, 0, sext(w >> 20, 12))
    if opc == 0x23 and f3 == 2:
        return ("sw", 0, rs1, rs2, sext(((w >> 25) << 5) | rd, 12))
    if opc == 0x63 and f3 in (0, 1):
        imm = (((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | \
              (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1)
        return ("bne" if f3 else "beq", 0, rs1, rs2, sext(imm, 13))
    if opc in (0x37, 0x17):
        return ("lui" if opc == 0x37 else "auipc", rd, 0, 0, w >> 12)
    if w == EBREAK:
        return ("ebreak", 0, 0, 0, 0)
    raise ValueError("unsupported instruction %08x" % w)


def disasm(w):
    op, rd, rs1, rs2, imm = decode(w)
    if op in ("add", "sub"):
        return "%s x%d, x%d, x%d" % (op, rd, rs1, rs2)
    if op == "addi":
        return "addi x%d, x%d, %d" % (rd, rs1, imm)
    if op == "lw":
        return "lw x%d, %d(x%d)" % (rd, imm, rs1)
    if op == "sw":
        return "sw x%d, %d(x%d)" % (rs2, imm, rs1)
    if op in ("beq", "bne"):
        return "%s x%d, x%d, %+d" % (op, rs1, rs2, imm)
    if op in ("lui", "auipc"):
        return "%s x%d, 0x%x" % (op, rd, imm)
    return op


# ---------------------------------------------------------------------------
# ISS + timing model
# ---------------------------------------------------------------------------

class Row:
    """One expected retirement. Field names mirror the testbench arrays."""
    __slots__ = ("cycle", "pc", "inst", "rs1_chk", "rs1_addr", "rs1_data",
                 "rs2_chk", "rs2_addr", "rs2_data", "rd_addr", "rd_data",
                 "mem_kind", "mem_addr", "mem_mask", "mem_data", "halt",
                 "next_pc", "tag")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k, 0))

    def key(self):
        """Fields that the trace text can express (for row-by-row compare)."""
        return (self.cycle, self.pc, self.inst,
                self.rs1_chk, self.rs1_addr if self.rs1_chk else 0,
                self.rs1_data if self.rs1_chk else 0,
                self.rs2_chk, self.rs2_addr if self.rs2_chk else 0,
                self.rs2_data if self.rs2_chk else 0,
                self.rd_addr, self.rd_data if self.rd_addr else 0,
                self.mem_kind, self.mem_addr, self.mem_mask, self.mem_data,
                self.halt)


def run_model(words, tags=None, first_cycle=FIRST_RETIRE_CYCLE,
              max_retire=10000):
    """Execute `words` (loaded at IMEM_BASE) and return the retirement rows.

    Timing (no forwarding, no rf bypass): register values are written in WB
    and read in ID, three stages earlier, so a consumer's ID must come after
    its producer's WB:  retire(consumer) >= retire(producer) + 4.
    A taken branch resolves in EX and flushes two younger instructions:
    retire(next) >= retire(branch) + 3.
    """
    regs = [0] * 32
    mem = {}
    pc = IMEM_BASE
    rows = []
    last_writer_cycle = {}        # reg -> retire cycle of its latest producer
    prev_cycle = None
    prev_taken = False
    while len(rows) < max_retire:
        idx = (pc - IMEM_BASE) >> 2
        if not 0 <= idx < len(words):
            raise RuntimeError("model ran off the program at pc %08x" % pc)
        w = words[idx]
        op, rd, rs1, rs2, imm = decode(w)
        r1, r2, wr = CLASS[op]

        # ---- timing --------------------------------------------------------
        if prev_cycle is None:
            cycle = first_cycle
        else:
            cycle = prev_cycle + 1
            if prev_taken:
                cycle = max(cycle, prev_cycle + 3)
            for used, reg in ((r1, rs1), (r2, rs2)):
                if used and reg != 0 and reg in last_writer_cycle:
                    cycle = max(cycle, last_writer_cycle[reg] + 4)

        # ---- values --------------------------------------------------------
        a = regs[rs1] if r1 else 0
        b = regs[rs2] if r2 else 0
        row = Row(cycle=cycle, pc=pc, inst=w,
                  rs1_chk=int(r1), rs1_addr=rs1 if r1 else 0, rs1_data=a,
                  rs2_chk=int(r2), rs2_addr=rs2 if r2 else 0, rs2_data=b,
                  halt=int(op == "ebreak"),
                  tag=tags[idx] if tags else 0)
        next_pc = (pc + 4) & M32
        result = None
        taken = False
        if op == "add":
            result = (a + b) & M32
        elif op == "sub":
            result = (a - b) & M32
        elif op == "addi":
            result = (a + imm) & M32
        elif op == "lui":
            result = (imm << 12) & M32
        elif op == "auipc":
            result = (pc + (imm << 12)) & M32
        elif op == "lw":
            addr = (a + imm) & M32
            assert addr & 3 == 0, "misaligned lw at pc %08x" % pc
            assert DMEM_BASE <= addr < DMEM_BASE + 4 * DMEM_WORDS
            result = mem.get(addr, 0)
            row.mem_kind, row.mem_addr = 1, addr
            row.mem_mask, row.mem_data = 0xF, result
        elif op == "sw":
            addr = (a + imm) & M32
            assert addr & 3 == 0, "misaligned sw at pc %08x" % pc
            assert DMEM_BASE <= addr < DMEM_BASE + 4 * DMEM_WORDS
            mem[addr] = b
            row.mem_kind, row.mem_addr = 2, addr
            row.mem_mask, row.mem_data = 0xF, b
        elif op in ("beq", "bne"):
            taken = (a == b) if op == "beq" else (a != b)
            if taken:
                next_pc = (pc + imm) & M32
        if wr and rd != 0:
            regs[rd] = result
            row.rd_addr, row.rd_data = rd, result
            last_writer_cycle[rd] = cycle
        row.next_pc = next_pc
        rows.append(row)

        prev_cycle = cycle
        prev_taken = taken
        pc = next_pc
        if op == "ebreak":
            return rows
    raise RuntimeError("program did not reach ebreak")


# ---------------------------------------------------------------------------
# Trace I/O
# ---------------------------------------------------------------------------

def read_hex(path):
    with open(path) as f:
        return [int(t, 16) for t in f.read().split()]


def parse_trace(path):
    """Return (rows, halt_cycle) from a cycle-accurate hazard trace."""
    rows = []
    halt_cycle = None
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("Program halted after"):
                halt_cycle = int(line.split()[3])
                continue
            head, _, rest = line.partition(" ")
            cycle = int(head.split("=")[1])
            if rest == "BUBBLE":
                continue
            # [pc] inst r[a]=d r[a]=d [w[a]=d] [s|l[A,M]=D]
            tok = rest.replace("r[ ", "r[").replace("w[ ", "w[").split()
            pc = int(tok[0].strip("[]"), 16)
            inst = int(tok[1], 16)
            row = Row(cycle=cycle, pc=pc, inst=inst,
                      halt=int(inst == EBREAK))
            for n, t in enumerate(tok[2:4]):
                a, d = t[2:].split("]=")
                chk = a != "--"
                if n == 0:
                    row.rs1_chk = int(chk)
                    row.rs1_addr = int(a) if chk else 0
                    row.rs1_data = int(d, 16) if chk else 0
                else:
                    row.rs2_chk = int(chk)
                    row.rs2_addr = int(a) if chk else 0
                    row.rs2_data = int(d, 16) if chk else 0
            for t in tok[4:]:
                kind = t[0]
                body, d = t[2:].split("]=")
                if kind == "w":
                    row.rd_addr, row.rd_data = int(body), int(d, 16)
                elif kind in "sl":
                    addr, mask = body.split(",")
                    row.mem_kind = 1 if kind == "l" else 2
                    row.mem_addr = int(addr, 16)
                    row.mem_mask = int(mask, 2)
                    row.mem_data = int(d, 16)
                else:
                    raise ValueError("bad trace token %r" % t)
            rows.append(row)
    for i, r in enumerate(rows):
        r.next_pc = rows[i + 1].pc if i + 1 < len(rows) else (r.pc + 4) & M32
    return rows, halt_cycle


def format_trace(rows):
    """Render rows in the hazard_*.trace text format, bubbles included."""
    out = []
    by_cycle = {r.cycle: r for r in rows}
    for c in range(1, rows[-1].cycle + 1):
        r = by_cycle.get(c)
        if r is None:
            out.append("cycle=%05d BUBBLE" % c)
            continue
        f = ["cycle=%05d" % c, "[%08x]" % r.pc, "%08x" % r.inst]
        for chk, a, d in ((r.rs1_chk, r.rs1_addr, r.rs1_data),
                          (r.rs2_chk, r.rs2_addr, r.rs2_data)):
            f.append("r[%2d]=%08x" % (a, d) if chk else "r[--]=--------")
        if r.rd_addr:
            f.append("w[%2d]=%08x" % (r.rd_addr, r.rd_data))
        if r.mem_kind:
            f.append("%s[%08x,%s]=%08x" % ("l" if r.mem_kind == 1 else "s",
                                           r.mem_addr,
                                           format(r.mem_mask, "04b"),
                                           r.mem_data))
        out.append(" ".join(f))
    out.append("Program halted after %d cycles." % rows[-1].cycle)
    return out


# ---------------------------------------------------------------------------
# Part B: directed program
# ---------------------------------------------------------------------------

def nop():
    return ("addi", 0, 0, 0, 0)


def I(op, rd=0, rs1=0, rs2=0, imm=0):
    return (op, rd, rs1, rs2, imm)


def directed_program():
    """Return a list of (case_name, [instructions]) blocks.

    Every case is preceded by 4 NOPs so no case can see a producer from the
    one before it. Expected bubbles under the no-fwd model in [brackets].
    Register roles: x28 = DMEM_BASE pointer, x9 = filler destination that is
    never read by the case it sits in.
    """
    P = 4
    cases = []

    def case(name, body):
        cases.append((name, [nop()] * P + body))

    case("setup: base pointer and source registers", [
        I("lui", rd=28, imm=DMEM_BASE >> 12),        # x28 = 0x10010000
        I("addi", rd=2, imm=0x222),
        I("addi", rd=5, imm=0x55),
        I("addi", rd=6, imm=0x66),
        I("addi", rd=16, imm=0x1A6),
        I("addi", rd=19, imm=0x777),
        I("addi", rd=30, imm=0x3E),
    ])

    # 1. RAW distance --------------------------------------------------------
    case("RAW d=1 on rs1 [3]", [
        I("addi", rd=10, imm=11),
        I("add", rd=11, rs1=10, rs2=0),
    ])
    case("RAW d=2 on rs1 and rs2 [2]", [
        I("addi", rd=10, imm=22),
        I("addi", rd=9, imm=1),
        I("add", rd=11, rs1=10, rs2=10),
    ])
    case("RAW d=3 [1]", [
        I("addi", rd=10, imm=33),
        I("addi", rd=9, imm=1),
        I("addi", rd=9, imm=2),
        I("add", rd=11, rs1=10, rs2=0),
    ])
    case("RAW d=4 [0]", [
        I("addi", rd=10, imm=44),
        I("addi", rd=9, imm=1),
        I("addi", rd=9, imm=2),
        I("addi", rd=9, imm=3),
        I("add", rd=11, rs1=10, rs2=0),
    ])
    case("RAW d=1 on rs2 only [3]", [
        I("addi", rd=10, imm=55),
        I("add", rd=11, rs1=0, rs2=10),
    ])
    case("RAW max rule: rs1 d=3, rs2 d=1 [3]", [
        I("addi", rd=12, imm=-7),
        I("addi", rd=9, imm=1),
        I("addi", rd=13, imm=100),
        I("sub", rd=14, rs1=12, rs2=13),
    ])
    case("RAW max rule: rs1 d=2, rs2 d=3 [2]", [
        I("addi", rd=13, imm=5),
        I("addi", rd=12, imm=50),
        I("addi", rd=9, imm=1),
        I("sub", rd=14, rs1=12, rs2=13),
    ])

    # 2. Load-use ------------------------------------------------------------
    case("load-use setup: store 0x1A6 to 0x20(x28)", [
        I("sw", rs1=28, rs2=16, imm=0x20),
    ])
    case("load-use d=1 [3]", [
        I("lw", rd=14, rs1=28, imm=0x20),
        I("add", rd=15, rs1=14, rs2=14),
    ])
    case("load-use d=2 [2]", [
        I("lw", rd=14, rs1=28, imm=0x20),
        I("addi", rd=9, imm=1),
        I("add", rd=15, rs1=0, rs2=14),
    ])

    # 3. Load-store ----------------------------------------------------------
    case("load-store: loaded value is store data [3]", [
        I("lw", rd=12, rs1=28, imm=0x20),
        I("sw", rs1=28, rs2=12, imm=0x40),
    ])
    case("load-store setup: store pointer x28+0x60 to 0x24(x28)", [
        I("addi", rd=17, rs1=28, imm=0x60),
        I("addi", rd=9, imm=1),
        I("addi", rd=9, imm=2),
        I("addi", rd=9, imm=3),
        I("sw", rs1=28, rs2=17, imm=0x24),
    ])
    case("load-store: loaded value is store base [3]", [
        I("lw", rd=18, rs1=28, imm=0x24),
        I("sw", rs1=18, rs2=19, imm=0),
    ])
    case("load-store: read both stored words back", [
        I("lw", rd=20, rs1=28, imm=0x40),
        I("lw", rd=21, rs1=28, imm=0x60),
    ])

    # 4. False dependencies (all [0]) ---------------------------------------
    case("false dep: PDF case, addi imm=1 looks like rs2=x1 [0]", [
        I("add", rd=1, rs1=0, rs2=2),
        I("addi", rd=3, rs1=0, imm=1),
    ])
    # U-immediate 0x528: bits[19:15] = 5 and bits[24:20] = 5
    case("false dep: lui bits[19:15]=bits[24:20]=x5 [0]", [
        I("addi", rd=5, imm=0x123),
        I("lui", rd=22, imm=0x528),
    ])
    case("false dep: auipc bits[19:15]=bits[24:20]=x5 [0]", [
        I("addi", rd=5, imm=0x124),
        I("auipc", rd=23, imm=0x528),
    ])
    case("false dep: addi imm[4:0]=7 looks like rs2=x7 [0]", [
        I("addi", rd=7, imm=0x77),
        I("addi", rd=24, rs1=0, imm=7),
    ])
    case("false dep: lw imm[4:0]=8 looks like rs2=x8 [0]", [
        I("addi", rd=8, imm=0x88),
        I("lw", rd=25, rs1=28, imm=8),
    ])
    case("false dep: sw imm bits[11:7]=12 is not rd=x12 [0]", [
        I("sw", rs1=28, rs2=16, imm=12),
        I("add", rd=26, rs1=12, rs2=0),
    ])
    case("false dep: not-taken beq bits[11:7]=12 is not rd=x12 [0]", [
        I("beq", rs1=0, rs2=16, imm=12),
        I("add", rd=27, rs1=0, rs2=12),
    ])
    case("false dep: addi x0 then read x0 [0]", [
        I("addi", rd=0, rs1=0, imm=5),
        I("add", rd=29, rs1=0, rs2=0),
    ])

    # 5. No-hazard classes (all [0]) ----------------------------------------
    case("RAR [0]", [
        I("add", rd=7, rs1=5, rs2=6),
        I("add", rd=9, rs1=5, rs2=0),
    ])
    case("WAR [0]", [
        I("add", rd=8, rs1=30, rs2=0),
        I("addi", rd=30, rs1=0, imm=1),
    ])
    case("WAW [0], later read sees the second value", [
        I("add", rd=7, rs1=5, rs2=6),
        I("addi", rd=7, rs1=0, imm=1),
    ])
    case("WAW follow-up: read x7 (expect 1)", [
        I("add", rd=31, rs1=7, rs2=0),
    ])

    # 6. Branches ------------------------------------------------------------
    case("taken beq [2 after], skipped addi never retires", [
        I("beq", rs1=5, rs2=5, imm=8),
        I("addi", rd=9, imm=0x7FF),          # skipped
        I("addi", rd=10, imm=1),
    ])
    case("not-taken bne, no data dependency [0]", [
        I("bne", rs1=5, rs2=5, imm=8),
        I("addi", rd=10, imm=2),
        I("addi", rd=11, imm=3),
    ])

    case("end", [I("ebreak")])
    return cases


def build_directed():
    cases = directed_program()
    names, words, tags = [], [], []
    for n, (name, body) in enumerate(cases):
        names.append(name)
        for ins in body:
            words.append(encode(*ins))
            tags.append(n + 1)            # tag 0 is Part A
    return names, words, tags


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_encoder(words):
    ok = True
    good = 0
    seen = set()
    for i, w in enumerate(words):
        op, rd, rs1, rs2, imm = decode(w)
        seen.add(op)
        back = encode(op, rd, rs1, rs2, imm)
        good += back == w
        if back != w:
            ok = False
            print("  ENCODER MISMATCH at word %d: %08x -> %s -> %08x"
                  % (i, w, disasm(w), back))
    print("encoder: %d/%d words of hazard_program.hex round-trip (%s)"
          % (good, len(words), " ".join(sorted(seen))))
    return ok


def validate_model(words, trace_rows, halt_cycle):
    model = run_model(words)
    ok = True
    print("model: %d retirements, halts at cycle %d; trace: %d retirements, "
          "halts at cycle %d" % (len(model), model[-1].cycle,
                                 len(trace_rows), halt_cycle))

    # Values: every field, row by row, ignoring the absolute cycle.
    if len(model) != len(trace_rows):
        print("  VALUE MISMATCH: retirement count differs")
        ok = False
    for m, t in zip(model, trace_rows):
        if m.key()[1:] != t.key()[1:]:
            ok = False
            print("  VALUE MISMATCH at pc %08x:\n    model %s\n    trace %s"
                  % (t.pc, m.key()[1:], t.key()[1:]))
    print("values: %s" % ("every field of every retirement matches"
                          if ok else "MISMATCH (see above)"))

    # Timing: gap between consecutive retirements.
    gap_bad = []
    for i in range(1, min(len(model), len(trace_rows))):
        mg = model[i].cycle - model[i - 1].cycle
        tg = trace_rows[i].cycle - trace_rows[i - 1].cycle
        if mg != tg:
            gap_bad.append((trace_rows[i - 1], trace_rows[i], mg, tg))
    print("timing: %d/%d retirement gaps match"
          % (len(trace_rows) - 1 - len(gap_bad), len(trace_rows) - 1))
    for prev, cur, mg, tg in gap_bad:
        print("  GAP MISMATCH %08x (%s) -> %08x: model %d bubble(s), "
              "trace %d bubble(s) (trace cycles %d -> %d)"
              % (prev.pc, disasm(prev.inst), cur.pc, mg - 1, tg - 1,
                 prev.cycle, cur.cycle))

    # Literal cycle-by-cycle diff in trace format.
    with open(TRACE_PATH) as f:
        trace_text = [l.rstrip("\n") for l in f if l.strip()]
    diff = list(difflib.unified_diff(trace_text, format_trace(model),
                                     "hazard_no_fwd.trace", "model", n=1,
                                     lineterm=""))
    if diff:
        print("cycle-by-cycle diff (trace -> model):")
        for l in diff:
            print("  " + l)
    else:
        print("cycle-by-cycle diff: identical")
    return ok, gap_bad


# ---------------------------------------------------------------------------
# Verilog emission
# ---------------------------------------------------------------------------

def v_row(i, r):
    return ("        set_row(%3d, %4d, 32'h%08x, 32'h%08x, %d, 5'd%-2d, 32'h%08x, "
            "%d, 5'd%-2d, 32'h%08x, 5'd%-2d, 32'h%08x, 2'd%d, 32'h%08x, "
            "4'b%s, 32'h%08x, %d, %2d);"
            % (i, r.cycle, r.pc, r.inst, r.rs1_chk, r.rs1_addr, r.rs1_data,
               r.rs2_chk, r.rs2_addr, r.rs2_data, r.rd_addr, r.rd_data,
               r.mem_kind, r.mem_addr, format(r.mem_mask, "04b"), r.mem_data,
               r.halt, r.tag))


def emit_load_task(name, comment, words, rows):
    out = ["    // %s" % comment,
           "    task %s;" % name, "        begin",
           "        clear_mems;"]
    for i, w in enumerate(words):
        try:
            d = disasm(w)
        except ValueError:
            d = "?"
        out.append("        imem[%3d] = 32'h%08x;  // %08x: %s"
                   % (i, w, IMEM_BASE + 4 * i, d))
    out.append("        n_exp = %d;" % len(rows))
    out.append("        //       row  cyc  pc            inst          "
               "rs1:chk addr data      rs2:chk addr data      rd addr data    "
               "    mem kind addr mask data            halt tag")
    for i, r in enumerate(rows):
        out.append(v_row(i, r))
    out += ["        end", "    endtask", ""]
    return out


def emit_tb_block(trace_words, trace_rows, b_names, b_words, b_rows):
    out = [BEGIN_MARK + " by scripts/gen_hazard_no_fwd.py -- do not edit by"
           " hand; rerun with --write",
           ""]
    out.append("    localparam N_CASES = %d;" % len(b_names))
    out += ["    task load_case_names;", "        begin",
            "        case_name[0] = \"hazard_program.hex trace\";"]
    for i, n in enumerate(b_names):
        out.append("        case_name[%d] = \"%s\";" % (i + 1, n))
    out += ["        end", "    endtask", ""]
    out += emit_load_task(
        "load_part_a",
        "Part A: traces/hazard_program.hex, expected rows from "
        "traces/hazard_no_fwd.trace",
        trace_words, trace_rows)
    out += emit_load_task(
        "load_part_b",
        "Part B: directed program, expected rows from the ISS + no-fwd "
        "timing model",
        b_words, b_rows)
    out.append("    " + END_MARK)
    return out


def write_tb(block):
    with open(TB_PATH) as f:
        text = f.read()
    b = text.index(BEGIN_MARK)
    b = text.rindex("\n", 0, b) + 1
    e = text.index(END_MARK, b)
    e = text.index("\n", e) + 1
    new = text[:b] + "    " + "\n".join(block).lstrip() + "\n" + text[e:]
    with open(TB_PATH, "w", newline="\n") as f:
        f.write(new)


# ---------------------------------------------------------------------------
# Mock hart (for validating the testbench only; never commit its output)
# ---------------------------------------------------------------------------

MUTANTS = ("none", "wrong_wdata", "extra_bubble", "missing_bubble",
           "no_halt", "trap_stuck", "skip_retire", "wrong_store_mask")


def mutate(rows, mutant):
    rows = [Row(**{k: getattr(r, k) for k in Row.__slots__}) for r in rows]
    mid = len(rows) // 2
    if mutant == "wrong_wdata":
        r = next(r for r in rows[mid:] if r.rd_addr)
        r.rd_data ^= 0x00000100
    elif mutant == "extra_bubble":
        for r in rows[mid:]:
            r.cycle += 1
    elif mutant == "missing_bubble":
        k = next(i for i in range(mid, len(rows))
                 if rows[i].cycle - rows[i - 1].cycle > 1)
        for r in rows[k:]:
            r.cycle -= 1
    elif mutant == "no_halt":
        for r in rows:
            r.halt = 0
    elif mutant == "skip_retire":
        del rows[mid]
        for i in range(mid - 1, mid):
            rows[i].next_pc = rows[i + 1].pc
    elif mutant == "wrong_store_mask":
        r = next(r for r in rows if r.mem_kind == 2)
        r.mem_mask = 0x7
    return rows


def emit_mock(path, parts, mutant):
    """A `hart` that ignores its inputs and replays the expected rows.

    It counts resets to know which part it is in, and counts cycles since the
    last reset so that row `cycle` N is driven during the N-th cycle the
    testbench samples (i.e. while the cycle counter reads N - 1).
    """
    lines = []
    w = lines.append
    total = sum(len(p) for p in parts)
    w("`default_nettype none")
    w("// MOCK hart generated by scripts/gen_hazard_no_fwd.py, mutant=%s." % mutant)
    w("// Testbench validation only. Never commit this file.")
    w("module hart #(parameter RESET_ADDR = 32'h00000000, parameter FWD_EN = 1,")
    w("              parameter BYPASS_EN = 1) (")
    w("    input  wire i_clk, input wire i_rst,")
    w("    output wire [31:0] o_imem_raddr, input wire [31:0] i_imem_rdata,")
    w("    output wire [31:0] o_dmem_addr, output wire o_dmem_ren, output wire o_dmem_wen,")
    w("    output wire [31:0] o_dmem_wdata, output wire [3:0] o_dmem_mask,")
    w("    input  wire [31:0] i_dmem_rdata,")
    w("    output wire o_retire_valid, output wire [31:0] o_retire_inst,")
    w("    output wire o_retire_trap, output wire o_retire_halt,")
    w("    output wire [4:0] o_retire_rs1_raddr, output wire [4:0] o_retire_rs2_raddr,")
    w("    output wire [31:0] o_retire_rs1_rdata, output wire [31:0] o_retire_rs2_rdata,")
    w("    output wire [4:0] o_retire_rd_waddr, output wire [31:0] o_retire_rd_wdata,")
    w("    output wire [31:0] o_retire_dmem_addr, output wire [3:0] o_retire_dmem_mask,")
    w("    output wire o_retire_dmem_ren, output wire o_retire_dmem_wen,")
    w("    output wire [31:0] o_retire_dmem_rdata, output wire [31:0] o_retire_dmem_wdata,")
    w("    output wire [31:0] o_retire_pc, output wire [31:0] o_retire_next_pc);")
    w("    localparam N = %d;" % total)
    for nm, wd in (("cyc", 32), ("pc", 32), ("inst", 32), ("r1a", 5),
                   ("r1d", 32), ("r2a", 5), ("r2d", 32), ("rda", 5),
                   ("rdd", 32), ("mk", 2), ("ma", 32), ("mm", 4),
                   ("md", 32), ("hl", 1), ("np", 32), ("part", 2)):
        w("    reg [%d:0] t_%s [0:N-1];" % (wd - 1, nm))
    w("    initial begin")
    i = 0
    for p, rows in enumerate(parts):
        for r in rows:
            w("        t_cyc[%d]=%d; t_pc[%d]=32'h%08x; t_inst[%d]=32'h%08x; "
              "t_r1a[%d]=%d; t_r1d[%d]=32'h%08x; t_r2a[%d]=%d; t_r2d[%d]=32'h%08x; "
              "t_rda[%d]=%d; t_rdd[%d]=32'h%08x; t_mk[%d]=%d; t_ma[%d]=32'h%08x; "
              "t_mm[%d]=%d; t_md[%d]=32'h%08x; t_hl[%d]=%d; t_np[%d]=32'h%08x; "
              "t_part[%d]=%d;"
              % (i, r.cycle, i, r.pc, i, r.inst, i, r.rs1_addr, i, r.rs1_data,
                 i, r.rs2_addr, i, r.rs2_data, i, r.rd_addr, i, r.rd_data,
                 i, r.mem_kind, i, r.mem_addr, i, r.mem_mask, i, r.mem_data,
                 i, r.halt, i, r.next_pc, i, p + 1))
            i += 1
    w("    end")
    w("    reg [1:0]  part;   // 1 = Part A, 2 = Part B (counts reset releases)")
    w("    reg        in_rst;")
    w("    reg [31:0] cnt;    // cycles since reset release")
    w("    reg [31:0] k;      // next row to replay")
    w("    initial begin part = 0; in_rst = 0; cnt = 0; k = 0; end")
    w("    always @(posedge i_clk) begin")
    w("        if (i_rst) begin")
    w("            in_rst <= 1'b1; cnt <= 0;")
    w("        end else begin")
    w("            if (in_rst) begin")
    w("                part <= part + 1'b1; in_rst <= 1'b0;")
    w("                k <= (part == 0) ? 0 : %d;" % len(parts[0]))
    w("            end else if (o_retire_valid) begin")
    w("                k <= k + 1;")
    w("            end")
    w("            cnt <= cnt + 1;")
    w("        end")
    w("    end")
    w("    wire live = !i_rst && !in_rst && (k < N) && (t_part[k] == part);")
    w("    assign o_retire_valid = live && (t_cyc[k] == cnt + 1);")
    w("    assign o_retire_inst = t_inst[k];")
    w("    assign o_retire_trap = %s;" % ("1'b1" if mutant == "trap_stuck" else "1'b0"))
    w("    assign o_retire_halt = t_hl[k];")
    w("    assign o_retire_rs1_raddr = t_r1a[k];")
    w("    assign o_retire_rs1_rdata = t_r1d[k];")
    w("    assign o_retire_rs2_raddr = t_r2a[k];")
    w("    assign o_retire_rs2_rdata = t_r2d[k];")
    w("    assign o_retire_rd_waddr = t_rda[k];")
    w("    assign o_retire_rd_wdata = t_rdd[k];")
    w("    assign o_retire_dmem_addr = t_ma[k];")
    w("    assign o_retire_dmem_mask = t_mm[k];")
    w("    assign o_retire_dmem_ren = (t_mk[k] == 2'd1);")
    w("    assign o_retire_dmem_wen = (t_mk[k] == 2'd2);")
    w("    assign o_retire_dmem_rdata = t_md[k];")
    w("    assign o_retire_dmem_wdata = t_md[k];")
    w("    assign o_retire_pc = t_pc[k];")
    w("    assign o_retire_next_pc = t_np[k];")
    w("    assign o_imem_raddr = RESET_ADDR;")
    w("    assign o_dmem_addr = 32'h0;")
    w("    assign o_dmem_ren = 1'b0;")
    w("    assign o_dmem_wen = 1'b0;")
    w("    assign o_dmem_wdata = 32'h0;")
    w("    assign o_dmem_mask = 4'h0;")
    w("endmodule")
    w("`default_nettype wire")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--write", action="store_true",
                    help="rewrite the GENERATED block in hart_hazard_no_fwd_tb.v")
    ap.add_argument("--emit-mock", metavar="PATH",
                    help="write a replay `hart` for testing the testbench")
    ap.add_argument("--mutant", choices=MUTANTS, default="none")
    ap.add_argument("--mutant-part", choices=("A", "B"), default="A")
    ap.add_argument("--list-b", action="store_true",
                    help="print the Part B program with expected timing")
    args = ap.parse_args()

    words = read_hex(HEX_PATH)
    trace_rows, halt_cycle = parse_trace(TRACE_PATH)
    print("hazard_program.hex: %d words; hazard_no_fwd.trace: %d retirements, "
          "%d bubbles, halts at cycle %d"
          % (len(words), len(trace_rows), halt_cycle - len(trace_rows),
             halt_cycle))

    enc_ok = validate_encoder(words)
    val_ok, gap_bad = validate_model(words, trace_rows, halt_cycle)

    b_names, b_words, b_tags = build_directed()
    for wd in b_words:   # every directed word must round-trip too
        op, rd, rs1, rs2, imm = decode(wd)
        assert encode(op, rd, rs1, rs2, imm) == wd
    b_rows = run_model(b_words, b_tags)
    print("Part B: %d words, %d retirements, %d cases, halts at cycle %d"
          % (len(b_words), len(b_rows), len(b_names), b_rows[-1].cycle))

    if args.list_b:
        prev = None
        for r in b_rows:
            gap = "" if prev is None else "+%d bubble(s)" % (r.cycle - prev - 1)
            print("  %5d %08x %08x  %-26s %-14s %s"
                  % (r.cycle, r.pc, r.inst, disasm(r.inst), gap,
                     b_names[r.tag - 1]))
            prev = r.cycle

    if not enc_ok or not val_ok:
        print("VALIDATION FAILED: not emitting anything")
        return 1
    if gap_bad:
        print("NOTE: the timing model does not reproduce the gap(s) above. The "
              "testbench keeps the trace's timing for Part A as given; this "
              "needs a team/TA answer, not a special case in the model.")

    if args.write:
        write_tb(emit_tb_block(words, trace_rows, b_names, b_words, b_rows))
        print("wrote GENERATED block in %s" % os.path.relpath(TB_PATH, ROOT))

    if args.emit_mock:
        a, b = trace_rows, b_rows
        if args.mutant_part == "A":
            a = mutate(a, args.mutant)
        else:
            b = mutate(b, args.mutant)
        emit_mock(args.emit_mock, [a, b], args.mutant)
        print("wrote mock hart (mutant=%s, part %s) to %s"
              % (args.mutant, args.mutant_part, args.emit_mock))
    return 0


if __name__ == "__main__":
    sys.exit(main())
