#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <name> [submission_dir]" >&2
    exit 1
fi
SUMMARY_FILE="${SCRIPT_DIR}/results/$1.txt"
SUBMISSION_ARG="${2:-${SCRIPT_DIR}}"

if [[ ! -d "${SUBMISSION_ARG}" ]]; then
    echo "ERROR: submission directory not found: ${SUBMISSION_ARG}" >&2
    exit 1
fi
SUBMISSION_DIR="$(cd "${SUBMISSION_ARG}" && pwd)"
echo "Submission under test: ${SUBMISSION_DIR}"

BUILD_DIR="${SCRIPT_DIR}/build"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${SCRIPT_DIR}/results"
: > "${SUMMARY_FILE}"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "ERROR: iverilog not found on PATH. See README.md for install instructions." >&2
    exit 1
fi

# The phase-4 checks. Each is graded by its own <name>_tb.v, which you write
# yourself -- see README.md and example/opmux_tb.v. rf is checked twice, once
# per BYPASS_EN setting, against the same rf.v (rf_bypass_tb.v and
# rf_no_bypass_tb.v, carried over from phase 3). hart is checked three times
# against the same hart.v, one per test in section 5 of phase_4.pdf:
#   hart_no_hazard      traces/no_hazard_program.hex -> traces/no_hazard.trace
#   hart_hazard_no_fwd  traces/hazard_program.hex    -> traces/hazard_no_fwd.trace (FWD_EN=0)
#   hart_hazard_fwd     traces/hazard_program.hex    -> traces/hazard_fwd.trace    (FWD_EN=1)
MODULES=(alu imm rf_bypass rf_no_bypass decoder hart_no_hazard hart_hazard_no_fwd hart_hazard_fwd)

# Most checks share a name with the .v file they test; rf's two checks both
# target rf.v and hart's three target hart.v. No associative arrays on
# purpose -- macOS ships bash 3.2.
dut_for() {
    case "$1" in
        rf_bypass | rf_no_bypass) echo "rf" ;;
        hart_*) echo "hart" ;;
        *) echo "$1" ;;
    esac
}

# Every non-testbench .v file at the repo root is a potential dependency
# (hart instantiates alu/rf/decoder, decoder instantiates imm), so every
# module is compiled against the full set.
SOURCES=()
while IFS= read -r f; do
    SOURCES+=("${f}")
done < <(find "${SUBMISSION_DIR}" -maxdepth 1 -name '*.v' ! -name '*_tb.v' | sort)

overall_status=0

for name in "${MODULES[@]}"; do
    dut_name="$(dut_for "${name}")"
    dut="${SUBMISSION_DIR}/${dut_name}.v"
    tb="${SUBMISSION_DIR}/${name}_tb.v"

    if [[ ! -f "${dut}" ]]; then
        echo "SKIP Verilog: ${name}  --  ${dut_name}.v not found" >> "${SUMMARY_FILE}"
        continue
    fi
    if [[ ! -s "${tb}" ]]; then
        echo "SKIP Verilog: ${name}  --  ${name}_tb.v not written yet" >> "${SUMMARY_FILE}"
        continue
    fi

    log="${BUILD_DIR}/${name}.log"
    sim="${BUILD_DIR}/${name}_sim"

    if ! iverilog -s "${name}_tb" -o "${sim}" "${tb}" "${SOURCES[@]}" > "${log}" 2>&1; then
        echo "FAIL Verilog: ${name}  --  compile error, see build/${name}.log" >> "${SUMMARY_FILE}"
        overall_status=1
        continue
    fi

    ( cd "${BUILD_DIR}" && vvp "${sim}" ) >> "${log}" 2>&1

    tally=$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "${log}" | tail -1)
    verdict=$(grep -E '^(ALL TESTS PASSED|TEST FAILED)$' "${log}" | tail -1)

    if [[ "${verdict}" == "ALL TESTS PASSED" ]]; then
        echo "PASS Verilog: ${name}  --  ${tally}" >> "${SUMMARY_FILE}"
    else
        echo "FAIL Verilog: ${name}  --  ${tally:-simulation did not report a verdict, see build/${name}.log}" >> "${SUMMARY_FILE}"
        overall_status=1
    fi
done

echo "Wrote ${SUMMARY_FILE}"
echo "Build/sim logs and waveforms: ${BUILD_DIR}"
exit "${overall_status}"
