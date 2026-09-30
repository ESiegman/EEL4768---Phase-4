.PHONY: help test ci schematics clean

help:
	@echo "make test        run your testbenches (writes results/local.txt)"
	@echo "make ci          same thing, under the name CI uses (results/ci.txt)"
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
	@./run_test.sh local

ci:
	@./run_test.sh ci

schematics:
	@./gen_schematics.sh

clean:
	rm -rf results build
