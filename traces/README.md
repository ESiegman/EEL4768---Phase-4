# Phase 4 hart trace tests

The assignment is in [`../documentation/phase_4.pdf`](../documentation/phase_4.pdf).
These files supply inputs and expected results for three CPU configurations:

| Check | Program | Expected trace | FWD_EN | BYPASS_EN |
| --- | --- | --- | --- | --- |
| `hart_no_hazard` | `no_hazard_program.hex` | `no_hazard.trace` | 0 | 1 |
| `hart_hazard_no_fwd` | `hazard_program.hex` | `hazard_no_fwd.trace` | 0 | 1 |
| `hart_hazard_fwd` | `hazard_program.hex` | `hazard_fwd.trace` | 1 | 1 |

All three tests explicitly set `RESET_ADDR=0x00400000`. Register-file bypass
is enabled in both hazard configurations, as section 4.4 requires.

## Running

From the repository root, with Bash, GNU Make and Icarus Verilog available:

```sh
make hart
make hart_no_hazard
make hart_hazard_no_fwd
make hart_hazard_fwd
```

Without Make, use `CHECKS='hart_no_hazard hart_hazard_no_fwd hart_hazard_fwd'
./run_test.sh local` on one line. Logs are written under `build/`, and the
summary is written under `results/`. The runner passes absolute program and
trace paths to the shared checker, so invoking it from another directory works
too. The standalone no-forwarding bench embeds its program and expected tables.

`hart_no_hazard_tb.v` contains the shared memory models, parser and checker.
The forwarding testbench instantiates it with different parameters; its compile
command must include that shared file. The no-forwarding bench is standalone
and also runs person 3's directed program. For example:

```sh
mkdir -p build
iverilog -g2005 -s hart_hazard_fwd_tb -o build/hart_hazard_fwd_sim \
    hart_hazard_fwd_tb.v hart_no_hazard_tb.v hart.v alu.v imm.v rf.v decoder.v
vvp build/hart_hazard_fwd_sim \
    +program=traces/hazard_program.hex +trace=traces/hazard_fwd.trace
```

The shared checker accepts `+program=...`, `+trace=...`, `+max_cycles=...`,
`+max_idle=...`, `+check_cycles=1` and `+vcd=path.vcd`. Without path overrides,
its defaults assume the simulator runs from `build/`. These options do not
change the standalone no-forwarding bench's embedded tables or watchdog.

## What is checked

In the shared checker, the program image is loaded into instruction memory starting
at `0x00400000`. The testbench supplies a separate byte-addressed data memory
at `0x10010000`, with masked combinational reads and writes at rising clock
edges. Both memories are initialized deterministically. Instruction memory
holds 32,768 words and data memory holds 65,536 bytes.

Each expected instruction is compared when `o_retire_valid` asserts. Pipeline
fill, stalls and flushes can take additional cycles; they do not consume an
expected instruction. The checker compares PC, raw instruction, trap/halt,
register operands, destination write, next PC and retire-side memory signals.
For loads, it checks the selected bytes of `o_retire_dmem_rdata` against an
independent memory updated from expected stores. At halt, the live memory is
compared with that expected memory to catch missing or unexpected stores.

Live memory enables must be known and mutually exclusive; enabled accesses
must use an aligned, in-range address and a known, nonzero byte mask. An
unknown retire-valid signal, timeout, missing file, empty trace, early halt or
trace ending without a retiring `ebreak` fails the test.

The shared checker's default limits are 250,000 total cycles and 1,000 cycles
without retirement. The runner exposes these as `HART_MAX_CYCLES` and
`HART_MAX_IDLE`. The no-forwarding bench has a 2,000-cycle watchdog per part.
For example:

```sh
HART_MAX_IDLE=2000 make hart
VCD=1 make hart_hazard_fwd
```

## Trace formats and timing

`no_hazard.trace` has **12,927 records in 33 groups**. Each non-comment record
contains 15 hexadecimal columns:

```text
pc inst trap halt rs1_raddr rs1_rdata rs2_raddr rs2_rdata rd_waddr rd_wdata mem_op mem_addr mem_mask mem_wdata next_pc
```

`mem_op` is 0 for no access, 1 for a load, and 2 for a store. `x` bits are
don't-cares and are masked during comparison. Destination data is ignored
when the destination is x0; store data is checked only on selected byte lanes.
The supplied next-PC column is all don't-cares; this hazard-free program is
sequential, so the checker independently requires `pc + 4`.

The hazard traces contain `cycle=...` lines, `BUBBLE` entries, operand
reads, optional destination writes and optional `l[...]`/`s[...]` accesses.
Both traces describe the same **38 retired instructions**. The recorded runs
take 91 cycles without forwarding and 49 with forwarding. The forwarding
parser skips bubbles during functional comparison and derives branch next PCs
from the expected operands and encoded offset.

The supplied no-forwarding trace's adjacent dependencies have three bubbles,
which assumes register-file bypass is disabled. Section 4.4 requires bypass
enabled, so `scripts/gen_hazard_no_fwd.py` preserves the trace's expected values
and regenerates timing for `BYPASS_EN=1`: an adjacent RAW dependency has two
bubbles, and a taken branch still flushes two stages. Both parts of the
no-forwarding bench always check these retirement gaps, allowing any initial
pipeline-fill offset. The source trace files are unchanged. The generator also
checks the source trace against the old no-bypass model and records its extra
two bubbles after a not-taken BNE as a source discrepancy.

To validate and regenerate the no-forwarding bench's embedded tables:

```sh
python3 scripts/gen_hazard_no_fwd.py --write
```

The forwarding checker defaults to functional comparison. To compare the
supplied absolute retirement cycles too:

```sh
HART_CHECK_CYCLES=1 make hart_hazard_fwd
```

That option applies to the forwarding checker. Its functional mode does not
prove that forwarding is implemented or that the CPU has five stages; inspect
the design and use timing checks when validating pipeline performance.

## Coverage limits

The large hazard-free program covers R/I ALU operations, every supported
load/store width, upper immediates and x0 behavior. It contains no branches,
jumps or traps. The small hazard program exercises dependent ALU operations,
load-use/store dependencies, false dependencies, x0, and taken/untaken branches.
Neither program covers jumps, illegal encodings or misalignment traps.

The standalone no-forwarding bench adds 30 directed cases (197 retirements),
including load-use, load-store data/address dependencies, RAW producer
distances, false dependencies, x0, RAR/WAR/WAW and taken/untaken branches.
Directed JAL/JALR, flush and trap tests for the forwarding bench remain part of
person 4's assignment.

These are functional tests, not the assignment's RTL rule checker. Passing
them does not establish synthesizability or compliance with all coding rules.
