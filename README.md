# EEL4768---Phase-4
[![CI](https://github.com/ESiegman/EEL4768---Phase-4/actions/workflows/ci.yml/badge.svg)](https://github.com/ESiegman/EEL4768---Phase-4/actions/workflows/ci.yml)

The assignment and synthesizable Verilog rules are in
[`documentation/phase_4.pdf`](documentation/phase_4.pdf). The three CPU checks
use the supplied programs and expected traces; see [`traces/README.md`](traces/README.md).

Run from Bash with Icarus Verilog (`iverilog` and `vvp`) on your PATH:

```sh
./run_test.sh local       # all eight checks; results/local.txt and build/*.log
make test                # same suite (also requires GNU Make)
make imm                 # immediate generator only
make hart                # all three CPU configurations
make test CHECKS='imm decoder'
```

To check another directory containing RTL, use `./run_test.sh local path/to/rtl`
or `make test SUBMISSION_DIR=path/to/rtl`. Testbenches and traces come from this
checkout; non-testbench `.v` files come from the requested RTL directory.
Run the script by its full path if your current directory is elsewhere.

Override executable paths when necessary, including on Windows with Git Bash:

```sh
IVERILOG=/path/to/iverilog VVP=/path/to/vvp ./run_test.sh local
```

Each check prints PASS/FAIL, saves its full compile/simulation log, and contributes
to the runner's exit status. Missing required files, nonzero simulator exits,
and simulations without `ALL TESTS PASSED` fail. The shared hart checker supports
waveforms with `VCD=1 make hart_hazard_fwd`; unit testbenches retain their own
waveform settings.

All hart tests use `RESET_ADDR=0x00400000` and `BYPASS_EN=1`, as the assignment
requires. The no-forwarding bench preserves person 3's directed cases and uses
timing regenerated for register-file bypass; see the trace README for the
supplied trace's different timing assumptions.

The five-stage `hart.v` implementation has been merged. CPU checks currently
fail compilation because `decoder.v` does not yet expose `o_uses_rs1`,
`o_uses_rs2` and `o_is_load`, which the CPU instantiates. This decoder integration
must be completed before the CPU tests can validate the implementation.
