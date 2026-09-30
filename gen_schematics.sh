#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/build/schematics"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

if ! command -v yosys >/dev/null 2>&1; then
    echo "ERROR: yosys not found on PATH." >&2
    exit 1
fi
if ! command -v netlistsvg >/dev/null 2>&1; then
    echo "ERROR: netlistsvg not found on PATH (npm i -g netlistsvg)." >&2
    exit 1
fi
# Optional: also rasterize each SVG to PNG with rsvg-convert. GitHub's job
# summary sanitizer strips <img src="data:image/svg+xml..."> (SVG data URIs
# can carry a <script>/foreignObject payload) but allows data:image/png, so
# the CI workflow inlines the PNG into the summary and keeps the SVG as the
# full-quality artifact. Skipped silently if rsvg-convert isn't installed
# (brew install librsvg / apt install librsvg2-bin).
HAVE_RSVG=0
if command -v rsvg-convert >/dev/null 2>&1; then
    HAVE_RSVG=1
fi

# Each module's own file plus any modules it instantiates. decoder embeds
# imm (see decoder.v), and hart embeds alu/rf/decoder (which embeds imm), so
# their schematics need those files in the same yosys read.
# No associative arrays here on purpose -- macOS ships bash 3.2, which
# doesn't have them, and this script also runs via `make test` locally.
module_sources() {
    case "$1" in
        decoder) echo "decoder.v imm.v" ;;
        hart)    echo "hart.v alu.v rf.v decoder.v imm.v" ;;
        *)       echo "$1.v" ;;
    esac
}

overall_status=0

for name in alu imm rf decoder hart; do
    sources=""
    missing=0
    for f in $(module_sources "${name}"); do
        if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
            missing=1
            break
        fi
        sources="${sources} ${SCRIPT_DIR}/${f}"
    done

    if [[ "${missing}" -eq 1 ]]; then
        echo "SKIP Schematic: ${name}  --  a dependency has not been written yet"
        continue
    fi

    json="${OUT_DIR}/${name}.json"
    svg="${OUT_DIR}/${name}.svg"
    log="${OUT_DIR}/${name}.yosys.log"

    yosys_script="read_verilog -sv ${sources}; hierarchy -top ${name}; proc; opt; pmuxtree; opt_clean; write_json ${json}"

    if ! yosys -p "${yosys_script}" > "${log}" 2>&1; then
        echo "FAIL Schematic: ${name}  --  yosys synthesis error, see build/schematics/${name}.yosys.log"
        overall_status=1
        continue
    fi

    if ! netlistsvg "${json}" -o "${svg}" >> "${log}" 2>&1; then
        echo "FAIL Schematic: ${name}  --  netlistsvg render error, see build/schematics/${name}.yosys.log"
        overall_status=1
        continue
    fi

    if [[ "${HAVE_RSVG}" -eq 1 ]]; then
        png="${OUT_DIR}/${name}.png"
        rsvg-convert -b white -o "${png}" "${svg}" >> "${log}" 2>&1 || true
    fi

    echo "OK   Schematic: ${name}  --  build/schematics/${name}.svg"
done

exit "${overall_status}"
