ALL_CHECKS := alu imm rf_bypass rf_no_bypass decoder hart_no_hazard hart_hazard_no_fwd hart_hazard_fwd
CHECKS ?= $(ALL_CHECKS)
SUBMISSION_DIR ?= .
IVERILOG ?= iverilog
VVP ?= vvp
export IVERILOG VVP

.PHONY: help test ci hart schematics clean $(ALL_CHECKS)

help:
	@echo "make test        run your testbenches (writes results/local.txt)"
	@echo "make ci          same thing, under the name CI uses (results/ci.txt)"
	@echo "make imm         run one named check (likewise alu, decoder, rf_bypass, ...)"
	@echo "make hart        run all three hart trace tests"
	@echo "make test CHECKS='imm decoder' SUBMISSION_DIR=path/to/rtl"
	@echo "make schematics  synthesize alu/imm/rf/decoder/hart with yosys and"
	@echo "                 render gate-level SVGs with netlistsvg (build/schematics/)"
	@echo "make clean       remove results/ and build/"
	@echo
	@echo "Details:      ./run_test.sh <name> [submission_dir]"
	@echo "Write your own <check>_tb.v for alu, imm, rf_bypass, rf_no_bypass,"
	@echo "decoder, hart_no_hazard, hart_hazard_no_fwd and hart_hazard_fwd --"
	@echo "see README.md, example/opmux_tb.v and traces/README.md. There is no"
	@echo "autograder for phase 4; this only runs the testbenches you write."

test:
	@CHECKS="$(CHECKS)" ./run_test.sh local "$(SUBMISSION_DIR)"

ci:
	@CHECKS="$(CHECKS)" ./run_test.sh ci "$(SUBMISSION_DIR)"

alu imm rf_bypass rf_no_bypass decoder hart_no_hazard hart_hazard_no_fwd hart_hazard_fwd:
	@CHECKS="$@" ./run_test.sh "$@" "$(SUBMISSION_DIR)"

hart:
	@CHECKS="hart_no_hazard hart_hazard_no_fwd hart_hazard_fwd" ./run_test.sh hart "$(SUBMISSION_DIR)"

schematics:
	@./gen_schematics.sh

clean:
	rm -rf results build
