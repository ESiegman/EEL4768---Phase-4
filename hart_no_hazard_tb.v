`timescale 1ns / 1ps
`default_nettype none

// Shared checker used by the forwarding top with its own program/trace
// paths and FWD_EN setting. The no-forwarding bench is standalone.
module hart_no_hazard_tb #(
    parameter FWD_EN = 0,
    parameter BYPASS_EN = 1,
    parameter CYCLE_TRACE = 0,
    parameter PROGRAM_FILE = "../traces/no_hazard_program.hex",
    parameter TRACE_FILE = "../traces/no_hazard.trace"
);
    localparam [31:0] RESET_ADDR = 32'h00400000;
    localparam [31:0] DATA_BASE = 32'h10010000;
    localparam IMEM_WORDS = 32768;
    localparam DMEM_BYTES = 65536;
    localparam LINE_BYTES = 512;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, imem_data;
    wire [31:0] dmem_addr, dmem_wdata;
    reg  [31:0] dmem_rdata;
    wire [3:0] dmem_mask;
    wire dmem_ren, dmem_wen;
    wire valid, trap, halt, retire_ren, retire_wen;
    wire [31:0] inst, pc, next_pc, rs1_data, rs2_data, rd_data;
    wire [4:0] rs1_addr, rs2_addr, rd_addr;
    wire [31:0] retire_addr, retire_wdata, retire_rdata;
    wire [3:0] retire_mask;

    hart #(.RESET_ADDR(RESET_ADDR), .FWD_EN(FWD_EN), .BYPASS_EN(BYPASS_EN)) dut (
        .i_clk(clk), .i_rst(rst),
        .o_imem_raddr(imem_addr), .i_imem_rdata(imem_data),
        .o_dmem_addr(dmem_addr), .o_dmem_ren(dmem_ren), .o_dmem_wen(dmem_wen),
        .o_dmem_wdata(dmem_wdata), .o_dmem_mask(dmem_mask), .i_dmem_rdata(dmem_rdata),
        .o_retire_valid(valid), .o_retire_inst(inst), .o_retire_trap(trap),
        .o_retire_halt(halt), .o_retire_rs1_raddr(rs1_addr),
        .o_retire_rs2_raddr(rs2_addr), .o_retire_rs1_rdata(rs1_data),
        .o_retire_rs2_rdata(rs2_data), .o_retire_rd_waddr(rd_addr),
        .o_retire_rd_wdata(rd_data), .o_retire_dmem_addr(retire_addr),
        .o_retire_dmem_mask(retire_mask), .o_retire_dmem_ren(retire_ren),
        .o_retire_dmem_wen(retire_wen), .o_retire_dmem_rdata(retire_rdata),
        .o_retire_dmem_wdata(retire_wdata), .o_retire_pc(pc),
        .o_retire_next_pc(next_pc)
    );

    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [7:0] dmem [0:DMEM_BYTES-1];
    // Updated from expected stores at retirement, independently of live DUT writes.
    reg [7:0] expected_memory [0:DMEM_BYTES-1];
    wire memory_address_ok = (dmem_addr >= DATA_BASE) &&
                            (dmem_addr <= DATA_BASE + DMEM_BYTES - 4) &&
                            (dmem_addr[1:0] == 0);
    assign imem_data = (imem_addr >= RESET_ADDR &&
                       imem_addr < RESET_ADDR + 4*IMEM_WORDS &&
                       imem_addr[1:0] == 0) ?
                       imem[(imem_addr-RESET_ADDR) >> 2] : 32'h00000013;

    integer read_lane, write_lane;
    // Every memory update toggles this event bit. An explicit sensitivity
    // list avoids elaborating a 65,536-element always @* sensitivity set.
    reg memory_epoch = 0;
    always @(dmem_ren or dmem_addr or dmem_mask or memory_address_ok or memory_epoch) begin
        dmem_rdata = 32'hxxxxxxxx;
        if (dmem_ren === 1'b1 && memory_address_ok === 1'b1)
            for (read_lane = 0; read_lane < 4; read_lane = read_lane + 1)
                if (dmem_mask[read_lane])
                    dmem_rdata[8*read_lane +: 8] = dmem[dmem_addr-DATA_BASE+read_lane];
    end
    always @(posedge clk) begin
        if (!rst && dmem_wen === 1'b1 && memory_address_ok === 1'b1) begin
            for (write_lane = 0; write_lane < 4; write_lane = write_lane + 1)
                if (dmem_mask[write_lane])
                    dmem[dmem_addr-DATA_BASE+write_lane] <= dmem_wdata[8*write_lane +: 8];
            memory_epoch <= ~memory_epoch;
        end
    end

    integer passed = 0, failed = 0, cycles = 0, vectors = 0;
    integer max_cycles = 250000, max_idle = 1000, check_cycles = 0;
    integer fd, program_fd, line_length, scan_count, program_words;
    integer i, j, ignored, trace_cycle, parsed_rs1, parsed_rs2, parsed_rd;
    integer idle_cycles;
    reg bad, found, done;
    reg [8*LINE_BYTES-1:0] line;
    reg [8*LINE_BYTES-1:0] suffix;
    reg [8*512-1:0] program_path, trace_path, wave_path;
    reg [8*32-1:0] tag;
    reg [31:0] program_word;
    reg [31:0] e_pc, e_inst, e_rs1_data, e_rs2_data, e_rd_data;
    reg [31:0] e_mem_addr, e_mem_wdata, e_mem_rdata, e_next_pc;
    reg [4:0] e_rs1_addr, e_rs2_addr, e_rd_addr;
    reg e_trap, e_halt;
    reg [1:0] e_mem_op;
    reg [3:0] e_mem_mask;
    reg [31:0] branch_offset;
    reg branch_taken;

    task finish_test;
        begin
            $display("%0d passed, %0d failed", passed, failed);
            if (failed == 0) $display("ALL TESTS PASSED");
            else $display("TEST FAILED");
            $finish;
        end
    endtask

    task abort_test;
        input [8*160-1:0] reason;
        begin
            failed = failed + 1;
            $display("[FAIL] %0s (vector %0d, cycle %0d)", reason, vectors+1, cycles);
            finish_test;
        end
    endtask

    // x bits in an expected field are don't-cares. Known bits must match
    // exactly, so an x/z on a required DUT output always fails.
    task check_field;
        input [8*32-1:0] label;
        input [31:0] actual;
        input [31:0] expected;
        reg [31:0] mask;
        integer bit_index;
        begin
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
                mask[bit_index] = (expected[bit_index] === 1'b0 ||
                                   expected[bit_index] === 1'b1);
            if ((actual & mask) !== (expected & mask)) begin
                bad = 1;
                if (failed < 20)
                    $display("[FAIL] vector %0d pc=%h %0s: got %h, expected %h",
                             vectors+1, e_pc, label, actual, expected);
            end
        end
    endtask

    function [7:0] character;
        input integer position;
        begin character = line[8*(line_length-position)-1 -: 8]; end
    endfunction

    function [8*LINE_BYTES-1:0] tail_at;
        input integer position;
        integer shift;
        begin
            shift = 8*(LINE_BYTES-line_length+position);
            tail_at = (line << shift) >> shift;
        end
    endfunction

    task read_vector;
        begin
            found = 0;
            while (!found && !$feof(fd)) begin
                line_length = $fgets(line, fd);
                i = 0;
                while (i < line_length && (character(i) == " " ||
                       character(i) == 9 || character(i) == 10 || character(i) == 13)) i = i+1;
                if (i < line_length && character(i) != "#") begin
                    e_mem_rdata = 32'hxxxxxxxx;
                    if (!CYCLE_TRACE) begin
                        scan_count = $sscanf(line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                            e_pc, e_inst, e_trap, e_halt, e_rs1_addr, e_rs1_data,
                            e_rs2_addr, e_rs2_data, e_rd_addr, e_rd_data, e_mem_op,
                            e_mem_addr, e_mem_mask, e_mem_wdata, e_next_pc);
                        if (scan_count != 15) abort_test("malformed 15-column trace record");
                        found = 1;
                    end else begin
                        scan_count = $sscanf(line, "cycle=%d %s", trace_cycle, tag);
                        if (scan_count == 2 && tag != "BUBBLE") begin
                            // The printed unused operands r[--]=-------- mean
                            // register zero and data zero on the retire interface.
                            for (j = 0; j < line_length; j = j+1)
                                if (character(j) == "-") line[8*(line_length-j)-1 -: 8] = "0";
                            scan_count = $sscanf(line,
                                "cycle=%d [%h] %h r[%d]=%h r[%d]=%h",
                                trace_cycle, e_pc, e_inst, parsed_rs1, e_rs1_data,
                                parsed_rs2, e_rs2_data);
                            if (scan_count != 7) abort_test("malformed cycle trace record");
                            e_rs1_addr = parsed_rs1;
                            e_rs2_addr = parsed_rs2;
                            e_rd_addr = 0;
                            e_rd_data = 32'hxxxxxxxx;
                            e_mem_op = 0;
                            e_mem_addr = 32'hxxxxxxxx;
                            e_mem_mask = 4'hx;
                            e_mem_wdata = 32'hxxxxxxxx;
                            e_trap = 0;
                            e_halt = (e_inst == 32'h00100073);
                            e_next_pc = 32'hxxxxxxxx;
                            for (j = 0; j < line_length-1; j = j+1) begin
                                if (character(j+1) == "[") begin
                                    suffix = tail_at(j);
                                    case (character(j))
                                        "w": begin
                                            scan_count = $sscanf(suffix, "w[%d]=%h", parsed_rd, e_rd_data);
                                            if (scan_count != 2) abort_test("malformed register write");
                                            e_rd_addr = parsed_rd;
                                        end
                                        "s": begin
                                            scan_count = $sscanf(suffix, "s[%h,%b]=%h", e_mem_addr, e_mem_mask, e_mem_wdata);
                                            if (scan_count != 3) abort_test("malformed store");
                                            e_mem_op = 2;
                                        end
                                        "l": begin
                                            scan_count = $sscanf(suffix, "l[%h,%b]=%h", e_mem_addr, e_mem_mask, e_mem_rdata);
                                            if (scan_count != 3) abort_test("malformed load");
                                            e_mem_op = 1;
                                        end
                                    endcase
                                end
                            end
                            found = 1;
                        end else if (scan_count != 2) begin
                            scan_count = $sscanf(line, "Program halted after %d cycles.", ignored);
                            if (scan_count != 1) abort_test("unrecognized cycle trace line");
                        end
                    end
                end
            end
        end
    endtask

    task wait_for_retirement;
        begin
            idle_cycles = 0;
            done = 0;
            while (!done) begin
                @(negedge clk);
                cycles = cycles+1;
                idle_cycles = idle_cycles+1;
                if (valid !== 1'b0 && valid !== 1'b1) abort_test("o_retire_valid is x/z; hart may be unimplemented");
                if (dmem_ren !== 1'b0 && dmem_ren !== 1'b1) abort_test("o_dmem_ren is x/z");
                if (dmem_wen !== 1'b0 && dmem_wen !== 1'b1) abort_test("o_dmem_wen is x/z");
                if (dmem_ren && dmem_wen) abort_test("simultaneous data memory read and write");
                if ((dmem_ren || dmem_wen) &&
                    (memory_address_ok !== 1'b1 || (^dmem_mask) === 1'bx || dmem_mask == 0))
                    abort_test("invalid live memory address or byte mask");
                done = (valid === 1'b1);
                if (cycles > max_cycles || idle_cycles > max_idle) abort_test("timeout waiting for instruction retirement");
            end
        end
    endtask

    task check_vector;
        begin
            bad = 0;
            // Neither supplied program has jumps or traps. Infer next_pc
            // independently where the column trace leaves it unspecified.
            if ((^e_next_pc) === 1'bx) begin
                e_next_pc = e_pc+4;
                if (e_inst[6:0] == 7'b1100011) begin
                    branch_offset = {{19{e_inst[31]}}, e_inst[31], e_inst[7],
                                     e_inst[30:25], e_inst[11:8], 1'b0};
                    case (e_inst[14:12])
                        0: branch_taken = (e_rs1_data == e_rs2_data);
                        1: branch_taken = (e_rs1_data != e_rs2_data);
                        4: branch_taken = ($signed(e_rs1_data) < $signed(e_rs2_data));
                        5: branch_taken = ($signed(e_rs1_data) >= $signed(e_rs2_data));
                        6: branch_taken = (e_rs1_data < e_rs2_data);
                        7: branch_taken = (e_rs1_data >= e_rs2_data);
                        default: branch_taken = 0;
                    endcase
                    if (branch_taken) e_next_pc = e_pc+branch_offset;
                end
            end
            check_field("pc", pc, e_pc);
            check_field("instruction", inst, e_inst);
            check_field("trap", {31'b0, trap}, {31'b0, e_trap});
            check_field("halt", {31'b0, halt}, {31'b0, e_halt});
            check_field("rs1 address", {27'b0, rs1_addr}, {27'b0, e_rs1_addr});
            check_field("rs1 data", rs1_data, e_rs1_data);
            check_field("rs2 address", {27'b0, rs2_addr}, {27'b0, e_rs2_addr});
            check_field("rs2 data", rs2_data, e_rs2_data);
            check_field("rd address", {27'b0, rd_addr}, {27'b0, e_rd_addr});
            if (e_rd_addr != 0) check_field("rd data", rd_data, e_rd_data);
            check_field("memory read enable", {31'b0, retire_ren}, e_mem_op == 1);
            check_field("memory write enable", {31'b0, retire_wen}, e_mem_op == 2);
            check_field("next pc", next_pc, e_next_pc);
            if (CYCLE_TRACE && check_cycles) check_field("retirement cycle", cycles, trace_cycle);
            if (e_mem_op != 0) begin
                if (e_mem_addr < DATA_BASE || e_mem_addr > DATA_BASE+DMEM_BYTES-4 || e_mem_addr[1:0] != 0)
                    abort_test("expected memory address outside the testbench memory");
                check_field("memory address", retire_addr, e_mem_addr);
                check_field("memory mask", {28'b0, retire_mask}, {28'b0, e_mem_mask});
                for (j = 0; j < 4; j = j+1) begin
                    if (e_mem_mask[j]) begin
                        if (e_mem_op == 2) begin
                            check_field("store byte", {24'b0, retire_wdata[8*j +: 8]}, {24'b0, e_mem_wdata[8*j +: 8]});
                            expected_memory[e_mem_addr-DATA_BASE+j] = e_mem_wdata[8*j +: 8];
                        end else begin
                            check_field("load byte", {24'b0, retire_rdata[8*j +: 8]},
                                        {24'b0, expected_memory[e_mem_addr-DATA_BASE+j]});
                        end
                    end
                end
                if (e_mem_op == 1) check_field("recorded load data", retire_rdata, e_mem_rdata);
            end
            vectors = vectors+1;
            if (bad) failed = failed+1;
            else passed = passed+1;
        end
    endtask

    initial begin
        program_path = PROGRAM_FILE;
        trace_path = TRACE_FILE;
        ignored = $value$plusargs("program=%s", program_path);
        ignored = $value$plusargs("trace=%s", trace_path);
        ignored = $value$plusargs("max_cycles=%d", max_cycles);
        ignored = $value$plusargs("max_idle=%d", max_idle);
        ignored = $value$plusargs("check_cycles=%d", check_cycles);
        if ($value$plusargs("vcd=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(0);
        end
        $display("Hart trace test: FWD_EN=%0d BYPASS_EN=%0d", FWD_EN, BYPASS_EN);
        $display("Program: %0s\nTrace: %0s", program_path, trace_path);
        for (i = 0; i < IMEM_WORDS; i = i+1) imem[i] = 32'h00000013;
        for (i = 0; i < DMEM_BYTES; i = i+1) begin
            dmem[i] = 0;
            expected_memory[i] = 0;
        end
        program_fd = $fopen(program_path, "r");
        if (program_fd == 0) abort_test("cannot open program image");
        program_words = 0;
        while (!$feof(program_fd)) begin
            line_length = $fgets(line, program_fd);
            scan_count = 0;
            if (line_length != 0) scan_count = $sscanf(line, "%h", program_word);
            if (scan_count == 1) begin
                if (program_words >= IMEM_WORDS) abort_test("program image is too large");
                imem[program_words] = program_word;
                program_words = program_words+1;
            end
        end
        $fclose(program_fd);
        if (program_words == 0) abort_test("program image is empty");
        fd = $fopen(trace_path, "r");
        if (fd == 0) abort_test("cannot open expected trace");
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 0;
        read_vector;
        while (found) begin
            wait_for_retirement;
            check_vector;
            if (halt === 1'b1) begin
                read_vector;
                if (found) abort_test("hart halted before the end of the trace");
                done = 0;
                for (i = 0; i < DMEM_BYTES; i = i+1)
                    if (dmem[i] !== expected_memory[i]) done = 1;
                if (done) abort_test("live data memory does not match expected stores");
            end else begin
                read_vector;
                if (!found) abort_test("trace ended without a retiring ebreak");
            end
        end
        $fclose(fd);
        if (vectors == 0) abort_test("trace contains no instructions");
        $display("Checked %0d retired instructions in %0d cycles.", vectors, cycles);
        finish_test;
    end
endmodule

`default_nettype wire
