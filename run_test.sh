#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <name> [submission_dir]" >&2
    exit 1
fi
if [[ ! "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "ERROR: result name must contain only letters, digits, dots, underscores or hyphens." >&2
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
mkdir -p "${BUILD_DIR}" "${SCRIPT_DIR}/results"
: > "${SUMMARY_FILE}"

IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
for tool in "${IVERILOG}" "${VVP}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERROR: ${tool} not found. Set IVERILOG and VVP to your simulator executables." >&2
        exit 1
    fi
done

# The phase-4 checks. Each is graded by its own <name>_tb.v, which you write
# yourself -- see README.md and example/opmux_tb.v. rf is checked twice, once
# per BYPASS_EN setting, against the same rf.v (rf_bypass_tb.v and
# rf_no_bypass_tb.v, carried over from phase 3). hart is checked three times
# against the same hart.v, one per test in section 5 of phase_4.pdf:
#   hart_no_hazard      traces/no_hazard_program.hex -> traces/no_hazard.trace
#   hart_hazard_no_fwd  traces/hazard_program.hex    -> traces/hazard_no_fwd.trace (FWD_EN=0)
#   hart_hazard_fwd     traces/hazard_program.hex    -> traces/hazard_fwd.trace    (FWD_EN=1)
read -r -a MODULES <<< "${CHECKS:-alu imm rf_bypass rf_no_bypass decoder hart_no_hazard hart_hazard_no_fwd hart_hazard_fwd}"
if [[ ${#MODULES[@]} -eq 0 ]]; then
    echo "ERROR: CHECKS must name at least one check." >&2
    exit 1
fi
for name in "${MODULES[@]}"; do
    case "${name}" in
        alu | imm | rf_bypass | rf_no_bypass | decoder | hart_no_hazard | hart_hazard_no_fwd | hart_hazard_fwd) ;;
        *) echo "ERROR: unknown check: ${name}" >&2; exit 1 ;;
    esac
done

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
report() {
    printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

for name in "${MODULES[@]}"; do
    dut_name="$(dut_for "${name}")"
    dut="${SUBMISSION_DIR}/${dut_name}.v"
    # Always use this checkout's testbenches to check the requested RTL.
    tb="${SCRIPT_DIR}/${name}_tb.v"

    if [[ ! -f "${dut}" ]]; then
        report "FAIL Verilog: ${name}  --  ${dut_name}.v not found"
        overall_status=1
        continue
    fi
    if [[ ! -s "${tb}" ]]; then
        report "FAIL Verilog: ${name}  --  ${name}_tb.v not written yet"
        overall_status=1
        continue
    fi

    log="${BUILD_DIR}/${name}.log"
    sim="${BUILD_DIR}/${name}_sim"
    TESTBENCHES=("${tb}")
    SIM_ARGS=()
    case "${name}" in
        hart_hazard_fwd)
            TESTBENCHES+=("${SCRIPT_DIR}/hart_no_hazard_tb.v") ;;
    esac
    case "${name}" in
        hart_no_hazard)
            SIM_ARGS+=("+program=${SCRIPT_DIR}/traces/no_hazard_program.hex"
                       "+trace=${SCRIPT_DIR}/traces/no_hazard.trace") ;;
        hart_hazard_no_fwd)
            SIM_ARGS+=("+program=${SCRIPT_DIR}/traces/hazard_program.hex"
                       "+trace=${SCRIPT_DIR}/traces/hazard_no_fwd.trace") ;;
        hart_hazard_fwd)
            SIM_ARGS+=("+program=${SCRIPT_DIR}/traces/hazard_program.hex"
                       "+trace=${SCRIPT_DIR}/traces/hazard_fwd.trace") ;;
    esac
    case "${name}" in
        hart_*)
            SIM_ARGS+=("+check_cycles=${HART_CHECK_CYCLES:-0}"
                       "+max_cycles=${HART_MAX_CYCLES:-250000}"
                       "+max_idle=${HART_MAX_IDLE:-1000}")
            if [[ "${VCD:-0}" == "1" ]]; then
                SIM_ARGS+=("+vcd=${BUILD_DIR}/${name}.vcd")
            fi ;;
    esac

    if ! TMPDIR="${BUILD_DIR}" "${IVERILOG}" -g2005 -s "${name}_tb" -o "${sim}" "${TESTBENCHES[@]}" "${SOURCES[@]}" > "${log}" 2>&1; then
        report "FAIL Verilog: ${name}  --  compile error, see build/${name}.log"
        overall_status=1
        continue
    fi

    ( cd "${BUILD_DIR}" && "${VVP}" "${sim}" "${SIM_ARGS[@]}" ) >> "${log}" 2>&1
    sim_status=$?

    tally=$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "${log}" | tail -1)
    verdict=$(grep -E '^(ALL TESTS PASSED|TEST FAILED)$' "${log}" | tail -1)

    if [[ "${sim_status}" -eq 0 && "${verdict}" == "ALL TESTS PASSED" ]]; then
        report "PASS Verilog: ${name}  --  ${tally:-simulation passed}"
    else
        reason="${tally:-simulation did not report a passing verdict}"
        if [[ "${sim_status}" -ne 0 ]]; then
            reason="simulator exited ${sim_status}; ${reason}"
        fi
        report "FAIL Verilog: ${name}  --  ${reason}, see build/${name}.log"
        overall_status=1
    fi
done

echo "Wrote ${SUMMARY_FILE}"
echo "Build/sim logs and waveforms: ${BUILD_DIR}"
exit "${overall_status}"
