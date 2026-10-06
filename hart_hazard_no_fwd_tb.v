`timescale 1ns / 1ps
`default_nettype none

// Self-checking testbench: pipelined hart with hazard detection but NO
// forwarding (phase_4.pdf sections 4.2 and 5).
//
// One hart instance runs two programs, each from reset to `ebreak`:
//   Part A  traces/hazard_program.hex, checked against every retirement in
//           traces/hazard_no_fwd.trace (values and stall timing).
//   Part B  a directed program that isolates what the trace does not: RAW at
//           each distance, rs2-only and max(rs1, rs2) stalls, load-use,
//           load-store (data and base), false dependencies from immediate
//           bits, RAR/WAR/WAW, and taken/not-taken branches.
// Both tables live in the GENERATED block at the bottom, written by
// scripts/gen_hazard_no_fwd.py (no file I/O at sim time: vvp runs in build/).
//
// ---- Parameters ------------------------------------------------------------
// FWD_EN = 0 is what this test is about. BYPASS_EN = 0 is inferred from the
// trace and NEEDS TEAM/TA CONFIRMATION: in hazard_no_fwd.trace, a consumer
// right behind its producer gets 3 bubbles (e.g. cycles 6 -> 10, 10 -> 14,
// 14 -> 18), at distance 2 it gets 2 (20 -> 23), at 3 it gets 1 (86 -> 90),
// i.e. max(0, 4 - d). With the WB -> ID rf bypass on, the consumer could read
// in the producer's WB cycle and adjacent RAW would cost only 2 bubbles. So
// the trace looks like it was generated with FWD_EN = 0, BYPASS_EN = 0, even
// though phase_4.pdf 4.4 says Phase 4 instantiates rf with BYPASS_EN = 1.
//
// ---- Harness conventions (for hart_no_hazard_tb / hart_hazard_fwd_tb) ------
//   clock     period 10, `always #5`, clk starts low (posedge at 5, 15, ...)
//   imem      256 words at 0x00400000, combinational; outside the window it
//             returns NOP (0x00000013), since wrong-path fetches past the end
//             are legal and get flushed.
//   dmem      256 words at 0x10010000, combinational read while o_dmem_ren,
//             masked byte write on posedge while o_dmem_wen. Cleared on every
//             program load. ren && wen together, or an access outside the
//             window, is a failure. With ren low the read port returns
//             0xBAD0BAD0 so a design that skips ren cannot load real data.
//   reset     i_rst high for 2 posedges, released at a negedge.
//   cycles    cycle N is the clock period ending at the N-th posedge after
//             reset release; retire ports are sampled once per cycle, #1
//             before that posedge.
//   end       a part ends when a retirement with o_retire_halt = 1 is seen,
//             or fails after WATCHDOG cycles.
//
// ---- What is checked on each retirement ------------------------------------
// Values: pc, inst, trap == 0, halt (1 only on ebreak), rs1/rs2 addr+data when
// the instruction class reads them ("r[--]" in the trace is a don't-care),
// rd_waddr (0 when the trace has no w[] field), rd_wdata when rd != 0,
// dmem ren/wen (store: wen=1 ren=0; load: ren=1 wen=0; else both 0), and for
// a load/store its addr, mask and data on the masked lanes, next_pc equal to
// the next expected pc, and no extra or missing retirements.
// Timing (separate tally): the gap in cycles between consecutive retirements
// must equal the expected gap, which is what encodes stalls and flushes. The
// absolute cycle of the first retirement is printed as info only (the trace
// says 6; it depends on cycle-counting convention).
//
// ---- Known oddity kept as given ----------------------------------------------
// hazard_no_fwd.trace has 2 bubbles after the NOT-taken `bne` at 0x0040007c
// (cycles 80-81); hazard_fwd.trace has none there, and a generic no-forwarding
// model predicts none. Part A keeps the trace's timing (it is the TA's
// expected output); Part B's not-taken bne expects 0 bubbles. Open question.
module hart_hazard_no_fwd_tb;

    localparam FWD_EN_TB    = 0;
    localparam BYPASS_EN_TB = 0;   // see header: inferred from the trace

    localparam [31:0] IMEM_BASE  = 32'h00400000;
    localparam [31:0] DMEM_BASE  = 32'h10010000;
    localparam        IMEM_WORDS = 256;
    localparam        DMEM_WORDS = 256;
    localparam        MAX_ROWS   = 256;
    localparam        WATCHDOG   = 2000;
    localparam        MAX_FAIL_LINES    = 20;
    localparam        TRACE_FIRST_CYCLE = 6;
    localparam [31:0] NOP        = 32'h00000013;

    // ------------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------------
    reg         clk;
    reg         rst;
    wire [31:0] imem_raddr;
    wire [31:0] imem_rdata;
    wire [31:0] dmem_addr;
    wire        dmem_ren;
    wire        dmem_wen;
    wire [31:0] dmem_wdata;
    wire [ 3:0] dmem_mask;
    wire [31:0] dmem_rdata;
    wire        retire_valid;
    wire [31:0] retire_inst;
    wire        retire_trap;
    wire        retire_halt;
    wire [ 4:0] retire_rs1_raddr;
    wire [ 4:0] retire_rs2_raddr;
    wire [31:0] retire_rs1_rdata;
    wire [31:0] retire_rs2_rdata;
    wire [ 4:0] retire_rd_waddr;
    wire [31:0] retire_rd_wdata;
    wire [31:0] retire_dmem_addr;
    wire [ 3:0] retire_dmem_mask;
    wire        retire_dmem_ren;
    wire        retire_dmem_wen;
    wire [31:0] retire_dmem_rdata;
    wire [31:0] retire_dmem_wdata;
    wire [31:0] retire_pc;
    wire [31:0] retire_next_pc;

    hart #(
        .RESET_ADDR (IMEM_BASE),
        .FWD_EN     (FWD_EN_TB),
        .BYPASS_EN  (BYPASS_EN_TB)
    ) dut (
        .i_clk              (clk),
        .i_rst              (rst),
        .o_imem_raddr       (imem_raddr),
        .i_imem_rdata       (imem_rdata),
        .o_dmem_addr        (dmem_addr),
        .o_dmem_ren         (dmem_ren),
        .o_dmem_wen         (dmem_wen),
        .o_dmem_wdata       (dmem_wdata),
        .o_dmem_mask        (dmem_mask),
        .i_dmem_rdata       (dmem_rdata),
        .o_retire_valid     (retire_valid),
        .o_retire_inst      (retire_inst),
        .o_retire_trap      (retire_trap),
        .o_retire_halt      (retire_halt),
        .o_retire_rs1_raddr (retire_rs1_raddr),
        .o_retire_rs2_raddr (retire_rs2_raddr),
        .o_retire_rs1_rdata (retire_rs1_rdata),
        .o_retire_rs2_rdata (retire_rs2_rdata),
        .o_retire_rd_waddr  (retire_rd_waddr),
        .o_retire_rd_wdata  (retire_rd_wdata),
        .o_retire_dmem_addr (retire_dmem_addr),
        .o_retire_dmem_mask (retire_dmem_mask),
        .o_retire_dmem_ren  (retire_dmem_ren),
        .o_retire_dmem_wen  (retire_dmem_wen),
        .o_retire_dmem_rdata(retire_dmem_rdata),
        .o_retire_dmem_wdata(retire_dmem_wdata),
        .o_retire_pc        (retire_pc),
        .o_retire_next_pc   (retire_next_pc)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Memories
    // ------------------------------------------------------------------------
    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [31:0] dmem [0:DMEM_WORDS-1];

    wire [31:0] imem_off = imem_raddr - IMEM_BASE;
    wire        imem_hit = (imem_off < IMEM_WORDS * 4);
    assign imem_rdata = imem_hit ? imem[imem_off[9:2]] : NOP;

    wire [31:0] dmem_off = dmem_addr - DMEM_BASE;
    wire        dmem_hit = (dmem_off < DMEM_WORDS * 4);
    assign dmem_rdata = (dmem_ren === 1'b1 && dmem_hit) ? dmem[dmem_off[9:2]]
                                                         : 32'hBAD0BAD0;

    // ------------------------------------------------------------------------
    // Expected-retirement table (filled by the GENERATED load tasks)
    // ------------------------------------------------------------------------
    integer    exp_cycle    [0:MAX_ROWS-1];
    reg [31:0] exp_pc       [0:MAX_ROWS-1];
    reg [31:0] exp_inst     [0:MAX_ROWS-1];
    reg        exp_rs1_chk  [0:MAX_ROWS-1];
    reg [ 4:0] exp_rs1_addr [0:MAX_ROWS-1];
    reg [31:0] exp_rs1_data [0:MAX_ROWS-1];
    reg        exp_rs2_chk  [0:MAX_ROWS-1];
    reg [ 4:0] exp_rs2_addr [0:MAX_ROWS-1];
    reg [31:0] exp_rs2_data [0:MAX_ROWS-1];
    reg [ 4:0] exp_rd_addr  [0:MAX_ROWS-1];
    reg [31:0] exp_rd_data  [0:MAX_ROWS-1];
    reg [ 1:0] exp_mem_kind [0:MAX_ROWS-1];   // 0 none, 1 load, 2 store
    reg [31:0] exp_mem_addr [0:MAX_ROWS-1];
    reg [ 3:0] exp_mem_mask [0:MAX_ROWS-1];
    reg [31:0] exp_mem_data [0:MAX_ROWS-1];
    reg        exp_halt     [0:MAX_ROWS-1];
    integer    exp_tag      [0:MAX_ROWS-1];   // index into case_name
    integer    n_exp;
    reg [8*72-1:0] case_name [0:63];

    task set_row;
        input integer    i;
        input integer    t_cycle;
        input [31:0]     t_pc;
        input [31:0]     t_inst;
        input            t_rs1_chk;
        input [ 4:0]     t_rs1_addr;
        input [31:0]     t_rs1_data;
        input            t_rs2_chk;
        input [ 4:0]     t_rs2_addr;
        input [31:0]     t_rs2_data;
        input [ 4:0]     t_rd_addr;
        input [31:0]     t_rd_data;
        input [ 1:0]     t_mem_kind;
        input [31:0]     t_mem_addr;
        input [ 3:0]     t_mem_mask;
        input [31:0]     t_mem_data;
        input            t_halt;
        input integer    t_tag;
        begin
            exp_cycle[i]    = t_cycle;
            exp_pc[i]       = t_pc;
            exp_inst[i]     = t_inst;
            exp_rs1_chk[i]  = t_rs1_chk;
            exp_rs1_addr[i] = t_rs1_addr;
            exp_rs1_data[i] = t_rs1_data;
            exp_rs2_chk[i]  = t_rs2_chk;
            exp_rs2_addr[i] = t_rs2_addr;
            exp_rs2_data[i] = t_rs2_data;
            exp_rd_addr[i]  = t_rd_addr;
            exp_rd_data[i]  = t_rd_data;
            exp_mem_kind[i] = t_mem_kind;
            exp_mem_addr[i] = t_mem_addr;
            exp_mem_mask[i] = t_mem_mask;
            exp_mem_data[i] = t_mem_data;
            exp_halt[i]     = t_halt;
            exp_tag[i]      = t_tag;
        end
    endtask

    integer m;
    task clear_mems;
        begin
            for (m = 0; m < IMEM_WORDS; m = m + 1) imem[m] = NOP;
            for (m = 0; m < DMEM_WORDS; m = m + 1) dmem[m] = 32'd0;
            n_exp = 0;
        end
    endtask

    // ------------------------------------------------------------------------
    // Tallies and failure reporting
    // ------------------------------------------------------------------------
    integer v_pass, v_fail, t_pass, t_fail;      // current part
    integer tot_pass, tot_fail;                  // whole run
    integer fail_lines;
    reg     running;                             // a part is executing
    reg [7:0] part_id;                           // "A" or "B"
    integer cur_row;

    task note_fail;
        input [8*160-1:0] msg;
        begin
            if (fail_lines < MAX_FAIL_LINES)
                $display("[FAIL] part %s: %0s", part_id, msg);
            else if (fail_lines == MAX_FAIL_LINES)
                $display("[....] more than %0d failures; counting the rest without printing", MAX_FAIL_LINES);
            fail_lines = fail_lines + 1;
        end
    endtask

    // One value check on the retirement in row `cur_row`.
    task vcheck;
        input [8*24-1:0] field;
        input [31:0]     got;
        input [31:0]     want;
        reg [8*160-1:0]  msg;
        begin
            if (got === want) begin
                v_pass = v_pass + 1;
            end else begin
                v_fail = v_fail + 1;
                $sformat(msg, "row %0d pc %h (%0s): %0s got %h, expected %h",
                         cur_row, exp_pc[cur_row], case_name[exp_tag[cur_row]],
                         field, got, want);
                note_fail(msg);
            end
        end
    endtask

    // A value failure with no single got/expected pair.
    task vfail;
        input [8*160-1:0] msg;
        begin
            v_fail = v_fail + 1;
            note_fail(msg);
        end
    endtask

    function [31:0] lanes;
        input [3:0] mask;
        begin
            lanes = {{8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}};
        end
    endfunction

    // ------------------------------------------------------------------------
    // dmem write port and protocol checks (every posedge of a running part)
    // ------------------------------------------------------------------------
    reg [8*160-1:0] dmsg;
    always @(posedge clk) begin
        if (running && !rst) begin
            if (dmem_ren === 1'b1 && dmem_wen === 1'b1) begin
                $sformat(dmsg, "o_dmem_ren and o_dmem_wen both high at %0t (addr %h)", $time, dmem_addr);
                vfail(dmsg);
            end
            if ((dmem_ren === 1'b1 || dmem_wen === 1'b1) && !dmem_hit) begin
                $sformat(dmsg, "dmem access outside %h..%h: addr %h ren %b wen %b", DMEM_BASE, DMEM_BASE + DMEM_WORDS * 4 - 1,
                         dmem_addr, dmem_ren, dmem_wen);
                vfail(dmsg);
            end
            if (dmem_wen === 1'b1 && dmem_hit) begin
                if (dmem_mask[0]) dmem[dmem_off[9:2]][ 7: 0] <= dmem_wdata[ 7: 0];
                if (dmem_mask[1]) dmem[dmem_off[9:2]][15: 8] <= dmem_wdata[15: 8];
                if (dmem_mask[2]) dmem[dmem_off[9:2]][23:16] <= dmem_wdata[23:16];
                if (dmem_mask[3]) dmem[dmem_off[9:2]][31:24] <= dmem_wdata[31:24];
            end
        end
    end

    // ------------------------------------------------------------------------
    // Check one retirement against row k
    // ------------------------------------------------------------------------
    reg [8*160-1:0] rmsg;
    task check_retirement;
        input integer k;
        input integer cyc;
        input integer last_cyc;
        integer gap_got;
        integer gap_want;
        begin
            cur_row = k;
            if (k >= n_exp) begin
                $sformat(rmsg, "extra retirement #%0d at cycle %0d: pc %h inst %h (table has %0d rows)", k, cyc, retire_pc,
                         retire_inst, n_exp);
                vfail(rmsg);
            end else begin
                vcheck("pc",   retire_pc,   exp_pc[k]);
                vcheck("inst", retire_inst, exp_inst[k]);
                vcheck("trap", {31'd0, retire_trap}, 32'd0);
                vcheck("halt", {31'd0, retire_halt}, {31'd0, exp_halt[k]});
                if (exp_rs1_chk[k]) begin
                    vcheck("rs1_raddr", {27'd0, retire_rs1_raddr},
                           {27'd0, exp_rs1_addr[k]});
                    vcheck("rs1_rdata", retire_rs1_rdata, exp_rs1_data[k]);
                end
                if (exp_rs2_chk[k]) begin
                    vcheck("rs2_raddr", {27'd0, retire_rs2_raddr},
                           {27'd0, exp_rs2_addr[k]});
                    vcheck("rs2_rdata", retire_rs2_rdata, exp_rs2_data[k]);
                end
                vcheck("rd_waddr", {27'd0, retire_rd_waddr},
                       {27'd0, exp_rd_addr[k]});
                if (exp_rd_addr[k] != 5'd0)
                    vcheck("rd_wdata", retire_rd_wdata, exp_rd_data[k]);
                vcheck("dmem_ren", {31'd0, retire_dmem_ren},
                       {31'd0, exp_mem_kind[k] == 2'd1});
                vcheck("dmem_wen", {31'd0, retire_dmem_wen},
                       {31'd0, exp_mem_kind[k] == 2'd2});
                if (exp_mem_kind[k] != 2'd0) begin
                    vcheck("dmem_addr", retire_dmem_addr, exp_mem_addr[k]);
                    vcheck("dmem_mask", {28'd0, retire_dmem_mask},
                           {28'd0, exp_mem_mask[k]});
                end
                if (exp_mem_kind[k] == 2'd1)
                    vcheck("dmem_rdata (masked)",
                           retire_dmem_rdata & lanes(exp_mem_mask[k]),
                           exp_mem_data[k] & lanes(exp_mem_mask[k]));
                if (exp_mem_kind[k] == 2'd2)
                    vcheck("dmem_wdata (masked)",
                           retire_dmem_wdata & lanes(exp_mem_mask[k]),
                           exp_mem_data[k] & lanes(exp_mem_mask[k]));
                // next_pc must be the pc of the next expected retirement.
                // Not checked on the final ebreak (nothing retires after it).
                if (k + 1 < n_exp)
                    vcheck("next_pc", retire_next_pc, exp_pc[k + 1]);

                // ---- timing ----
                if (k == 0) begin
                    $display("[info] part %s: first retirement at cycle %0d (table/trace: %0d; offset depends on cycle counting, only gaps are checked)", part_id, cyc,
                             exp_cycle[0]);
                end else begin
                    gap_got  = cyc - last_cyc;
                    gap_want = exp_cycle[k] - exp_cycle[k - 1];
                    if (gap_got == gap_want) begin
                        t_pass = t_pass + 1;
                    end else begin
                        t_fail = t_fail + 1;
                        $sformat(rmsg, "row %0d pc %h (%0s): TIMING %0d bubble(s) before it, expected %0d",
                                 k, exp_pc[k], case_name[exp_tag[k]],
                                 gap_got - 1, gap_want - 1);
                        note_fail(rmsg);
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Run one loaded program from reset to ebreak
    // ------------------------------------------------------------------------
    integer cyc, k, last_cyc;
    reg     halted, valid_x_seen;
    reg [8*160-1:0] pmsg;

    task run_part;
        begin
            v_pass = 0; v_fail = 0; t_pass = 0; t_fail = 0;
            cur_row = 0;

            // Reset: held for 2 posedges, released at a negedge.
            rst = 1'b1;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            running = 1'b1;

            cyc = 0; k = 0; last_cyc = 0;
            halted = 1'b0; valid_x_seen = 1'b0;
            while (!halted && cyc < WATCHDOG) begin
                #4;                         // 1 time unit before the posedge
                cyc = cyc + 1;
                if (retire_valid === 1'b1) begin
                    check_retirement(k, cyc, last_cyc);
                    if (retire_halt === 1'b1)
                        halted = 1'b1;
                    last_cyc = cyc;
                    k = k + 1;
                end else if (retire_valid !== 1'b0 && !valid_x_seen) begin
                    valid_x_seen = 1'b1;
                    $sformat(pmsg, "o_retire_valid is %b at cycle %0d (undriven or X)", retire_valid, cyc);
                    vfail(pmsg);
                end
                @(negedge clk);
            end
            running = 1'b0;

            if (!halted) begin
                $sformat(pmsg, "watchdog: no halting retirement within %0d cycles (%0d of %0d rows retired)", WATCHDOG,
                         (k < n_exp) ? k : n_exp, n_exp);
                vfail(pmsg);
            end
            if (k < n_exp) begin
                $sformat(pmsg, "%0d expected retirement(s) never happened, first missing: row %0d pc %h (%0s)", n_exp - k, k,
                         exp_pc[k], case_name[exp_tag[k]]);
                vfail(pmsg);
                // Count every missing row, not just the first.
                v_fail = v_fail + (n_exp - k - 1);
            end

            $display("part %s: values %0d/%0d, timing %0d/%0d, %0d of %0d rows retired, %0d cycles", part_id, v_pass,
                     v_pass + v_fail, t_pass, t_pass + t_fail,
                     (k < n_exp) ? k : n_exp, n_exp, cyc);
            tot_pass = tot_pass + v_pass + t_pass;
            tot_fail = tot_fail + v_fail + t_fail;
        end
    endtask

    // ------------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        running = 1'b0;
        tot_pass = 0; tot_fail = 0; fail_lines = 0;
        v_pass = 0; v_fail = 0; t_pass = 0; t_fail = 0;
        n_exp = 0;
        load_case_names;

        $display("========== hart_hazard_no_fwd testbench ==========");
        $display("hart #(.FWD_EN(%0d), .BYPASS_EN(%0d)), RESET_ADDR %h",
                 FWD_EN_TB, BYPASS_EN_TB, IMEM_BASE);

        $display("--- Part A: hazard_program.hex vs hazard_no_fwd.trace ---");
        part_id = "A";
        @(negedge clk);
        rst = 1'b1;
        load_part_a;
        run_part;

        $display("--- Part B: directed hazard cases ---");
        part_id = "B";
        @(negedge clk);
        rst = 1'b1;
        load_part_b;
        run_part;

        $display("==================================================");
        $display("%0d passed, %0d failed", tot_pass, tot_fail);
        if (tot_fail == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

    // BEGIN GENERATED by scripts/gen_hazard_no_fwd.py -- do not edit by hand; rerun with --write

    localparam N_CASES = 30;
    task load_case_names;
        begin
        case_name[0] = "hazard_program.hex trace";
        case_name[1] = "setup: base pointer and source registers";
        case_name[2] = "RAW d=1 on rs1 [3]";
        case_name[3] = "RAW d=2 on rs1 and rs2 [2]";
        case_name[4] = "RAW d=3 [1]";
        case_name[5] = "RAW d=4 [0]";
        case_name[6] = "RAW d=1 on rs2 only [3]";
        case_name[7] = "RAW max rule: rs1 d=3, rs2 d=1 [3]";
        case_name[8] = "RAW max rule: rs1 d=2, rs2 d=3 [2]";
        case_name[9] = "load-use setup: store 0x1A6 to 0x20(x28)";
        case_name[10] = "load-use d=1 [3]";
        case_name[11] = "load-use d=2 [2]";
        case_name[12] = "load-store: loaded value is store data [3]";
        case_name[13] = "load-store setup: store pointer x28+0x60 to 0x24(x28)";
        case_name[14] = "load-store: loaded value is store base [3]";
        case_name[15] = "load-store: read both stored words back";
        case_name[16] = "false dep: PDF case, addi imm=1 looks like rs2=x1 [0]";
        case_name[17] = "false dep: lui bits[19:15]=bits[24:20]=x5 [0]";
        case_name[18] = "false dep: auipc bits[19:15]=bits[24:20]=x5 [0]";
        case_name[19] = "false dep: addi imm[4:0]=7 looks like rs2=x7 [0]";
        case_name[20] = "false dep: lw imm[4:0]=8 looks like rs2=x8 [0]";
        case_name[21] = "false dep: sw imm bits[11:7]=12 is not rd=x12 [0]";
        case_name[22] = "false dep: not-taken beq bits[11:7]=12 is not rd=x12 [0]";
        case_name[23] = "false dep: addi x0 then read x0 [0]";
        case_name[24] = "RAR [0]";
        case_name[25] = "WAR [0]";
        case_name[26] = "WAW [0], later read sees the second value";
        case_name[27] = "WAW follow-up: read x7 (expect 1)";
        case_name[28] = "taken beq [2 after], skipped addi never retires";
        case_name[29] = "not-taken bne, no data dependency [0]";
        case_name[30] = "end";
        end
    endtask

    // Part A: traces/hazard_program.hex, expected rows from traces/hazard_no_fwd.trace
    task load_part_a;
        begin
        clear_mems;
        imem[  0] = 32'h01400313;  // 00400000: addi x6, x0, 20
        imem[  1] = 32'h00530393;  // 00400004: addi x7, x6, 5
        imem[  2] = 32'h00700433;  // 00400008: add x8, x0, x7
        imem[  3] = 32'h008404b3;  // 0040000c: add x9, x8, x8
        imem[  4] = 32'h00600513;  // 00400010: addi x10, x0, 6
        imem[  5] = 32'h06400593;  // 00400014: addi x11, x0, 100
        imem[  6] = 32'h00350613;  // 00400018: addi x12, x10, 3
        imem[  7] = 32'h10010e37;  // 0040001c: lui x28, 0x10010
        imem[  8] = 32'h010e0e93;  // 00400020: addi x29, x28, 16
        imem[  9] = 32'h009ea023;  // 00400024: sw x9, 0(x29)
        imem[ 10] = 32'h000ea683;  // 00400028: lw x13, 0(x29)
        imem[ 11] = 32'h00168713;  // 0040002c: addi x14, x13, 1
        imem[ 12] = 32'h02c00793;  // 00400030: addi x15, x0, 44
        imem[ 13] = 32'h00fe2a23;  // 00400034: sw x15, 20(x28)
        imem[ 14] = 32'h014e2803;  // 00400038: lw x16, 20(x28)
        imem[ 15] = 32'h010e2c23;  // 0040003c: sw x16, 24(x28)
        imem[ 16] = 32'h018e2883;  // 00400040: lw x17, 24(x28)
        imem[ 17] = 32'h018e2903;  // 00400044: lw x18, 24(x28)
        imem[ 18] = 32'h00600993;  // 00400048: addi x19, x0, 6
        imem[ 19] = 32'h01390a33;  // 0040004c: add x20, x18, x19
        imem[ 20] = 32'h06300013;  // 00400050: addi x0, x0, 99
        imem[ 21] = 32'h00700a93;  // 00400054: addi x21, x0, 7
        imem[ 22] = 32'h00900b93;  // 00400058: addi x23, x0, 9
        imem[ 23] = 32'h00db8b93;  // 0040005c: addi x23, x23, 13
        imem[ 24] = 32'h000b8c33;  // 00400060: add x24, x23, x0
        imem[ 25] = 32'h00c00c93;  // 00400064: addi x25, x0, 12
        imem[ 26] = 32'h00c00d13;  // 00400068: addi x26, x0, 12
        imem[ 27] = 32'h01ac8463;  // 0040006c: beq x25, x26, +8
        imem[ 28] = 32'h03300f93;  // 00400070: addi x31, x0, 51
        imem[ 29] = 32'h01800d93;  // 00400074: addi x27, x0, 24
        imem[ 30] = 32'h01800b13;  // 00400078: addi x22, x0, 24
        imem[ 31] = 32'h016d9663;  // 0040007c: bne x27, x22, +12
        imem[ 32] = 32'h04100f93;  // 00400080: addi x31, x0, 65
        imem[ 33] = 32'h00000463;  // 00400084: beq x0, x0, +8
        imem[ 34] = 32'h04200f93;  // 00400088: addi x31, x0, 66
        imem[ 35] = 32'h02800293;  // 0040008c: addi x5, x0, 40
        imem[ 36] = 32'h06400f13;  // 00400090: addi x30, x0, 100
        imem[ 37] = 32'h0c800193;  // 00400094: addi x3, x0, 200
        imem[ 38] = 32'h00028233;  // 00400098: add x4, x5, x0
        imem[ 39] = 32'h00100073;  // 0040009c: ebreak
        n_exp = 38;
        //       row  cyc  pc            inst          rs1:chk addr data      rs2:chk addr data      rd addr data        mem kind addr mask data            halt tag
        set_row(  0,    6, 32'h00400000, 32'h01400313, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd6 , 32'h00000014, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  1,   10, 32'h00400004, 32'h00530393, 1, 5'd6 , 32'h00000014, 0, 5'd0 , 32'h00000000, 5'd7 , 32'h00000019, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  2,   14, 32'h00400008, 32'h00700433, 1, 5'd0 , 32'h00000000, 1, 5'd7 , 32'h00000019, 5'd8 , 32'h00000019, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  3,   18, 32'h0040000c, 32'h008404b3, 1, 5'd8 , 32'h00000019, 1, 5'd8 , 32'h00000019, 5'd9 , 32'h00000032, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  4,   19, 32'h00400010, 32'h00600513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h00000006, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  5,   20, 32'h00400014, 32'h06400593, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd11, 32'h00000064, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  6,   23, 32'h00400018, 32'h00350613, 1, 5'd10, 32'h00000006, 0, 5'd0 , 32'h00000000, 5'd12, 32'h00000009, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  7,   24, 32'h0040001c, 32'h10010e37, 0, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd28, 32'h10010000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  8,   28, 32'h00400020, 32'h010e0e93, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd29, 32'h10010010, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row(  9,   32, 32'h00400024, 32'h009ea023, 1, 5'd29, 32'h10010010, 1, 5'd9 , 32'h00000032, 5'd0 , 32'h00000000, 2'd2, 32'h10010010, 4'b1111, 32'h00000032, 0,  0);
        set_row( 10,   33, 32'h00400028, 32'h000ea683, 1, 5'd29, 32'h10010010, 0, 5'd0 , 32'h00000000, 5'd13, 32'h00000032, 2'd1, 32'h10010010, 4'b1111, 32'h00000032, 0,  0);
        set_row( 11,   37, 32'h0040002c, 32'h00168713, 1, 5'd13, 32'h00000032, 0, 5'd0 , 32'h00000000, 5'd14, 32'h00000033, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 12,   38, 32'h00400030, 32'h02c00793, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd15, 32'h0000002c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 13,   42, 32'h00400034, 32'h00fe2a23, 1, 5'd28, 32'h10010000, 1, 5'd15, 32'h0000002c, 5'd0 , 32'h00000000, 2'd2, 32'h10010014, 4'b1111, 32'h0000002c, 0,  0);
        set_row( 14,   43, 32'h00400038, 32'h014e2803, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd16, 32'h0000002c, 2'd1, 32'h10010014, 4'b1111, 32'h0000002c, 0,  0);
        set_row( 15,   47, 32'h0040003c, 32'h010e2c23, 1, 5'd28, 32'h10010000, 1, 5'd16, 32'h0000002c, 5'd0 , 32'h00000000, 2'd2, 32'h10010018, 4'b1111, 32'h0000002c, 0,  0);
        set_row( 16,   48, 32'h00400040, 32'h018e2883, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd17, 32'h0000002c, 2'd1, 32'h10010018, 4'b1111, 32'h0000002c, 0,  0);
        set_row( 17,   49, 32'h00400044, 32'h018e2903, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd18, 32'h0000002c, 2'd1, 32'h10010018, 4'b1111, 32'h0000002c, 0,  0);
        set_row( 18,   50, 32'h00400048, 32'h00600993, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd19, 32'h00000006, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 19,   54, 32'h0040004c, 32'h01390a33, 1, 5'd18, 32'h0000002c, 1, 5'd19, 32'h00000006, 5'd20, 32'h00000032, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 20,   55, 32'h00400050, 32'h06300013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 21,   56, 32'h00400054, 32'h00700a93, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd21, 32'h00000007, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 22,   57, 32'h00400058, 32'h00900b93, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd23, 32'h00000009, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 23,   61, 32'h0040005c, 32'h00db8b93, 1, 5'd23, 32'h00000009, 0, 5'd0 , 32'h00000000, 5'd23, 32'h00000016, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 24,   65, 32'h00400060, 32'h000b8c33, 1, 5'd23, 32'h00000016, 1, 5'd0 , 32'h00000000, 5'd24, 32'h00000016, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 25,   66, 32'h00400064, 32'h00c00c93, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd25, 32'h0000000c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 26,   67, 32'h00400068, 32'h00c00d13, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd26, 32'h0000000c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 27,   71, 32'h0040006c, 32'h01ac8463, 1, 5'd25, 32'h0000000c, 1, 5'd26, 32'h0000000c, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 28,   74, 32'h00400074, 32'h01800d93, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd27, 32'h00000018, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 29,   75, 32'h00400078, 32'h01800b13, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd22, 32'h00000018, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 30,   79, 32'h0040007c, 32'h016d9663, 1, 5'd27, 32'h00000018, 1, 5'd22, 32'h00000018, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 31,   82, 32'h00400080, 32'h04100f93, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd31, 32'h00000041, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 32,   83, 32'h00400084, 32'h00000463, 1, 5'd0 , 32'h00000000, 1, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 33,   86, 32'h0040008c, 32'h02800293, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd5 , 32'h00000028, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 34,   87, 32'h00400090, 32'h06400f13, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd30, 32'h00000064, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 35,   88, 32'h00400094, 32'h0c800193, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd3 , 32'h000000c8, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 36,   90, 32'h00400098, 32'h00028233, 1, 5'd5 , 32'h00000028, 1, 5'd0 , 32'h00000000, 5'd4 , 32'h00000028, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  0);
        set_row( 37,   91, 32'h0040009c, 32'h00100073, 0, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 1,  0);
        end
    endtask

    // Part B: directed program, expected rows from the ISS + no-fwd timing model
    task load_part_b;
        begin
        clear_mems;
        imem[  0] = 32'h00000013;  // 00400000: addi x0, x0, 0
        imem[  1] = 32'h00000013;  // 00400004: addi x0, x0, 0
        imem[  2] = 32'h00000013;  // 00400008: addi x0, x0, 0
        imem[  3] = 32'h00000013;  // 0040000c: addi x0, x0, 0
        imem[  4] = 32'h10010e37;  // 00400010: lui x28, 0x10010
        imem[  5] = 32'h22200113;  // 00400014: addi x2, x0, 546
        imem[  6] = 32'h05500293;  // 00400018: addi x5, x0, 85
        imem[  7] = 32'h06600313;  // 0040001c: addi x6, x0, 102
        imem[  8] = 32'h1a600813;  // 00400020: addi x16, x0, 422
        imem[  9] = 32'h77700993;  // 00400024: addi x19, x0, 1911
        imem[ 10] = 32'h03e00f13;  // 00400028: addi x30, x0, 62
        imem[ 11] = 32'h00000013;  // 0040002c: addi x0, x0, 0
        imem[ 12] = 32'h00000013;  // 00400030: addi x0, x0, 0
        imem[ 13] = 32'h00000013;  // 00400034: addi x0, x0, 0
        imem[ 14] = 32'h00000013;  // 00400038: addi x0, x0, 0
        imem[ 15] = 32'h00b00513;  // 0040003c: addi x10, x0, 11
        imem[ 16] = 32'h000505b3;  // 00400040: add x11, x10, x0
        imem[ 17] = 32'h00000013;  // 00400044: addi x0, x0, 0
        imem[ 18] = 32'h00000013;  // 00400048: addi x0, x0, 0
        imem[ 19] = 32'h00000013;  // 0040004c: addi x0, x0, 0
        imem[ 20] = 32'h00000013;  // 00400050: addi x0, x0, 0
        imem[ 21] = 32'h01600513;  // 00400054: addi x10, x0, 22
        imem[ 22] = 32'h00100493;  // 00400058: addi x9, x0, 1
        imem[ 23] = 32'h00a505b3;  // 0040005c: add x11, x10, x10
        imem[ 24] = 32'h00000013;  // 00400060: addi x0, x0, 0
        imem[ 25] = 32'h00000013;  // 00400064: addi x0, x0, 0
        imem[ 26] = 32'h00000013;  // 00400068: addi x0, x0, 0
        imem[ 27] = 32'h00000013;  // 0040006c: addi x0, x0, 0
        imem[ 28] = 32'h02100513;  // 00400070: addi x10, x0, 33
        imem[ 29] = 32'h00100493;  // 00400074: addi x9, x0, 1
        imem[ 30] = 32'h00200493;  // 00400078: addi x9, x0, 2
        imem[ 31] = 32'h000505b3;  // 0040007c: add x11, x10, x0
        imem[ 32] = 32'h00000013;  // 00400080: addi x0, x0, 0
        imem[ 33] = 32'h00000013;  // 00400084: addi x0, x0, 0
        imem[ 34] = 32'h00000013;  // 00400088: addi x0, x0, 0
        imem[ 35] = 32'h00000013;  // 0040008c: addi x0, x0, 0
        imem[ 36] = 32'h02c00513;  // 00400090: addi x10, x0, 44
        imem[ 37] = 32'h00100493;  // 00400094: addi x9, x0, 1
        imem[ 38] = 32'h00200493;  // 00400098: addi x9, x0, 2
        imem[ 39] = 32'h00300493;  // 0040009c: addi x9, x0, 3
        imem[ 40] = 32'h000505b3;  // 004000a0: add x11, x10, x0
        imem[ 41] = 32'h00000013;  // 004000a4: addi x0, x0, 0
        imem[ 42] = 32'h00000013;  // 004000a8: addi x0, x0, 0
        imem[ 43] = 32'h00000013;  // 004000ac: addi x0, x0, 0
        imem[ 44] = 32'h00000013;  // 004000b0: addi x0, x0, 0
        imem[ 45] = 32'h03700513;  // 004000b4: addi x10, x0, 55
        imem[ 46] = 32'h00a005b3;  // 004000b8: add x11, x0, x10
        imem[ 47] = 32'h00000013;  // 004000bc: addi x0, x0, 0
        imem[ 48] = 32'h00000013;  // 004000c0: addi x0, x0, 0
        imem[ 49] = 32'h00000013;  // 004000c4: addi x0, x0, 0
        imem[ 50] = 32'h00000013;  // 004000c8: addi x0, x0, 0
        imem[ 51] = 32'hff900613;  // 004000cc: addi x12, x0, -7
        imem[ 52] = 32'h00100493;  // 004000d0: addi x9, x0, 1
        imem[ 53] = 32'h06400693;  // 004000d4: addi x13, x0, 100
        imem[ 54] = 32'h40d60733;  // 004000d8: sub x14, x12, x13
        imem[ 55] = 32'h00000013;  // 004000dc: addi x0, x0, 0
        imem[ 56] = 32'h00000013;  // 004000e0: addi x0, x0, 0
        imem[ 57] = 32'h00000013;  // 004000e4: addi x0, x0, 0
        imem[ 58] = 32'h00000013;  // 004000e8: addi x0, x0, 0
        imem[ 59] = 32'h00500693;  // 004000ec: addi x13, x0, 5
        imem[ 60] = 32'h03200613;  // 004000f0: addi x12, x0, 50
        imem[ 61] = 32'h00100493;  // 004000f4: addi x9, x0, 1
        imem[ 62] = 32'h40d60733;  // 004000f8: sub x14, x12, x13
        imem[ 63] = 32'h00000013;  // 004000fc: addi x0, x0, 0
        imem[ 64] = 32'h00000013;  // 00400100: addi x0, x0, 0
        imem[ 65] = 32'h00000013;  // 00400104: addi x0, x0, 0
        imem[ 66] = 32'h00000013;  // 00400108: addi x0, x0, 0
        imem[ 67] = 32'h030e2023;  // 0040010c: sw x16, 32(x28)
        imem[ 68] = 32'h00000013;  // 00400110: addi x0, x0, 0
        imem[ 69] = 32'h00000013;  // 00400114: addi x0, x0, 0
        imem[ 70] = 32'h00000013;  // 00400118: addi x0, x0, 0
        imem[ 71] = 32'h00000013;  // 0040011c: addi x0, x0, 0
        imem[ 72] = 32'h020e2703;  // 00400120: lw x14, 32(x28)
        imem[ 73] = 32'h00e707b3;  // 00400124: add x15, x14, x14
        imem[ 74] = 32'h00000013;  // 00400128: addi x0, x0, 0
        imem[ 75] = 32'h00000013;  // 0040012c: addi x0, x0, 0
        imem[ 76] = 32'h00000013;  // 00400130: addi x0, x0, 0
        imem[ 77] = 32'h00000013;  // 00400134: addi x0, x0, 0
        imem[ 78] = 32'h020e2703;  // 00400138: lw x14, 32(x28)
        imem[ 79] = 32'h00100493;  // 0040013c: addi x9, x0, 1
        imem[ 80] = 32'h00e007b3;  // 00400140: add x15, x0, x14
        imem[ 81] = 32'h00000013;  // 00400144: addi x0, x0, 0
        imem[ 82] = 32'h00000013;  // 00400148: addi x0, x0, 0
        imem[ 83] = 32'h00000013;  // 0040014c: addi x0, x0, 0
        imem[ 84] = 32'h00000013;  // 00400150: addi x0, x0, 0
        imem[ 85] = 32'h020e2603;  // 00400154: lw x12, 32(x28)
        imem[ 86] = 32'h04ce2023;  // 00400158: sw x12, 64(x28)
        imem[ 87] = 32'h00000013;  // 0040015c: addi x0, x0, 0
        imem[ 88] = 32'h00000013;  // 00400160: addi x0, x0, 0
        imem[ 89] = 32'h00000013;  // 00400164: addi x0, x0, 0
        imem[ 90] = 32'h00000013;  // 00400168: addi x0, x0, 0
        imem[ 91] = 32'h060e0893;  // 0040016c: addi x17, x28, 96
        imem[ 92] = 32'h00100493;  // 00400170: addi x9, x0, 1
        imem[ 93] = 32'h00200493;  // 00400174: addi x9, x0, 2
        imem[ 94] = 32'h00300493;  // 00400178: addi x9, x0, 3
        imem[ 95] = 32'h031e2223;  // 0040017c: sw x17, 36(x28)
        imem[ 96] = 32'h00000013;  // 00400180: addi x0, x0, 0
        imem[ 97] = 32'h00000013;  // 00400184: addi x0, x0, 0
        imem[ 98] = 32'h00000013;  // 00400188: addi x0, x0, 0
        imem[ 99] = 32'h00000013;  // 0040018c: addi x0, x0, 0
        imem[100] = 32'h024e2903;  // 00400190: lw x18, 36(x28)
        imem[101] = 32'h01392023;  // 00400194: sw x19, 0(x18)
        imem[102] = 32'h00000013;  // 00400198: addi x0, x0, 0
        imem[103] = 32'h00000013;  // 0040019c: addi x0, x0, 0
        imem[104] = 32'h00000013;  // 004001a0: addi x0, x0, 0
        imem[105] = 32'h00000013;  // 004001a4: addi x0, x0, 0
        imem[106] = 32'h040e2a03;  // 004001a8: lw x20, 64(x28)
        imem[107] = 32'h060e2a83;  // 004001ac: lw x21, 96(x28)
        imem[108] = 32'h00000013;  // 004001b0: addi x0, x0, 0
        imem[109] = 32'h00000013;  // 004001b4: addi x0, x0, 0
        imem[110] = 32'h00000013;  // 004001b8: addi x0, x0, 0
        imem[111] = 32'h00000013;  // 004001bc: addi x0, x0, 0
        imem[112] = 32'h002000b3;  // 004001c0: add x1, x0, x2
        imem[113] = 32'h00100193;  // 004001c4: addi x3, x0, 1
        imem[114] = 32'h00000013;  // 004001c8: addi x0, x0, 0
        imem[115] = 32'h00000013;  // 004001cc: addi x0, x0, 0
        imem[116] = 32'h00000013;  // 004001d0: addi x0, x0, 0
        imem[117] = 32'h00000013;  // 004001d4: addi x0, x0, 0
        imem[118] = 32'h12300293;  // 004001d8: addi x5, x0, 291
        imem[119] = 32'h00528b37;  // 004001dc: lui x22, 0x528
        imem[120] = 32'h00000013;  // 004001e0: addi x0, x0, 0
        imem[121] = 32'h00000013;  // 004001e4: addi x0, x0, 0
        imem[122] = 32'h00000013;  // 004001e8: addi x0, x0, 0
        imem[123] = 32'h00000013;  // 004001ec: addi x0, x0, 0
        imem[124] = 32'h12400293;  // 004001f0: addi x5, x0, 292
        imem[125] = 32'h00528b97;  // 004001f4: auipc x23, 0x528
        imem[126] = 32'h00000013;  // 004001f8: addi x0, x0, 0
        imem[127] = 32'h00000013;  // 004001fc: addi x0, x0, 0
        imem[128] = 32'h00000013;  // 00400200: addi x0, x0, 0
        imem[129] = 32'h00000013;  // 00400204: addi x0, x0, 0
        imem[130] = 32'h07700393;  // 00400208: addi x7, x0, 119
        imem[131] = 32'h00700c13;  // 0040020c: addi x24, x0, 7
        imem[132] = 32'h00000013;  // 00400210: addi x0, x0, 0
        imem[133] = 32'h00000013;  // 00400214: addi x0, x0, 0
        imem[134] = 32'h00000013;  // 00400218: addi x0, x0, 0
        imem[135] = 32'h00000013;  // 0040021c: addi x0, x0, 0
        imem[136] = 32'h08800413;  // 00400220: addi x8, x0, 136
        imem[137] = 32'h008e2c83;  // 00400224: lw x25, 8(x28)
        imem[138] = 32'h00000013;  // 00400228: addi x0, x0, 0
        imem[139] = 32'h00000013;  // 0040022c: addi x0, x0, 0
        imem[140] = 32'h00000013;  // 00400230: addi x0, x0, 0
        imem[141] = 32'h00000013;  // 00400234: addi x0, x0, 0
        imem[142] = 32'h010e2623;  // 00400238: sw x16, 12(x28)
        imem[143] = 32'h00060d33;  // 0040023c: add x26, x12, x0
        imem[144] = 32'h00000013;  // 00400240: addi x0, x0, 0
        imem[145] = 32'h00000013;  // 00400244: addi x0, x0, 0
        imem[146] = 32'h00000013;  // 00400248: addi x0, x0, 0
        imem[147] = 32'h00000013;  // 0040024c: addi x0, x0, 0
        imem[148] = 32'h01000663;  // 00400250: beq x0, x16, +12
        imem[149] = 32'h00c00db3;  // 00400254: add x27, x0, x12
        imem[150] = 32'h00000013;  // 00400258: addi x0, x0, 0
        imem[151] = 32'h00000013;  // 0040025c: addi x0, x0, 0
        imem[152] = 32'h00000013;  // 00400260: addi x0, x0, 0
        imem[153] = 32'h00000013;  // 00400264: addi x0, x0, 0
        imem[154] = 32'h00500013;  // 00400268: addi x0, x0, 5
        imem[155] = 32'h00000eb3;  // 0040026c: add x29, x0, x0
        imem[156] = 32'h00000013;  // 00400270: addi x0, x0, 0
        imem[157] = 32'h00000013;  // 00400274: addi x0, x0, 0
        imem[158] = 32'h00000013;  // 00400278: addi x0, x0, 0
        imem[159] = 32'h00000013;  // 0040027c: addi x0, x0, 0
        imem[160] = 32'h006283b3;  // 00400280: add x7, x5, x6
        imem[161] = 32'h000284b3;  // 00400284: add x9, x5, x0
        imem[162] = 32'h00000013;  // 00400288: addi x0, x0, 0
        imem[163] = 32'h00000013;  // 0040028c: addi x0, x0, 0
        imem[164] = 32'h00000013;  // 00400290: addi x0, x0, 0
        imem[165] = 32'h00000013;  // 00400294: addi x0, x0, 0
        imem[166] = 32'h000f0433;  // 00400298: add x8, x30, x0
        imem[167] = 32'h00100f13;  // 0040029c: addi x30, x0, 1
        imem[168] = 32'h00000013;  // 004002a0: addi x0, x0, 0
        imem[169] = 32'h00000013;  // 004002a4: addi x0, x0, 0
        imem[170] = 32'h00000013;  // 004002a8: addi x0, x0, 0
        imem[171] = 32'h00000013;  // 004002ac: addi x0, x0, 0
        imem[172] = 32'h006283b3;  // 004002b0: add x7, x5, x6
        imem[173] = 32'h00100393;  // 004002b4: addi x7, x0, 1
        imem[174] = 32'h00000013;  // 004002b8: addi x0, x0, 0
        imem[175] = 32'h00000013;  // 004002bc: addi x0, x0, 0
        imem[176] = 32'h00000013;  // 004002c0: addi x0, x0, 0
        imem[177] = 32'h00000013;  // 004002c4: addi x0, x0, 0
        imem[178] = 32'h00038fb3;  // 004002c8: add x31, x7, x0
        imem[179] = 32'h00000013;  // 004002cc: addi x0, x0, 0
        imem[180] = 32'h00000013;  // 004002d0: addi x0, x0, 0
        imem[181] = 32'h00000013;  // 004002d4: addi x0, x0, 0
        imem[182] = 32'h00000013;  // 004002d8: addi x0, x0, 0
        imem[183] = 32'h00528463;  // 004002dc: beq x5, x5, +8
        imem[184] = 32'h7ff00493;  // 004002e0: addi x9, x0, 2047
        imem[185] = 32'h00100513;  // 004002e4: addi x10, x0, 1
        imem[186] = 32'h00000013;  // 004002e8: addi x0, x0, 0
        imem[187] = 32'h00000013;  // 004002ec: addi x0, x0, 0
        imem[188] = 32'h00000013;  // 004002f0: addi x0, x0, 0
        imem[189] = 32'h00000013;  // 004002f4: addi x0, x0, 0
        imem[190] = 32'h00529463;  // 004002f8: bne x5, x5, +8
        imem[191] = 32'h00200513;  // 004002fc: addi x10, x0, 2
        imem[192] = 32'h00300593;  // 00400300: addi x11, x0, 3
        imem[193] = 32'h00000013;  // 00400304: addi x0, x0, 0
        imem[194] = 32'h00000013;  // 00400308: addi x0, x0, 0
        imem[195] = 32'h00000013;  // 0040030c: addi x0, x0, 0
        imem[196] = 32'h00000013;  // 00400310: addi x0, x0, 0
        imem[197] = 32'h00100073;  // 00400314: ebreak
        n_exp = 197;
        //       row  cyc  pc            inst          rs1:chk addr data      rs2:chk addr data      rd addr data        mem kind addr mask data            halt tag
        set_row(  0,    6, 32'h00400000, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  1,    7, 32'h00400004, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  2,    8, 32'h00400008, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  3,    9, 32'h0040000c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  4,   10, 32'h00400010, 32'h10010e37, 0, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd28, 32'h10010000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  5,   11, 32'h00400014, 32'h22200113, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd2 , 32'h00000222, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  6,   12, 32'h00400018, 32'h05500293, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd5 , 32'h00000055, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  7,   13, 32'h0040001c, 32'h06600313, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd6 , 32'h00000066, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  8,   14, 32'h00400020, 32'h1a600813, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd16, 32'h000001a6, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row(  9,   15, 32'h00400024, 32'h77700993, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd19, 32'h00000777, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row( 10,   16, 32'h00400028, 32'h03e00f13, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd30, 32'h0000003e, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  1);
        set_row( 11,   17, 32'h0040002c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  2);
        set_row( 12,   18, 32'h00400030, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  2);
        set_row( 13,   19, 32'h00400034, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  2);
        set_row( 14,   20, 32'h00400038, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  2);
        set_row( 15,   21, 32'h0040003c, 32'h00b00513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h0000000b, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  2);
        set_row( 16,   25, 32'h00400040, 32'h000505b3, 1, 5'd10, 32'h0000000b, 1, 5'd0 , 32'h00000000, 5'd11, 32'h0000000b, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  2);
        set_row( 17,   26, 32'h00400044, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 18,   27, 32'h00400048, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 19,   28, 32'h0040004c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 20,   29, 32'h00400050, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 21,   30, 32'h00400054, 32'h01600513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h00000016, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 22,   31, 32'h00400058, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 23,   34, 32'h0040005c, 32'h00a505b3, 1, 5'd10, 32'h00000016, 1, 5'd10, 32'h00000016, 5'd11, 32'h0000002c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  3);
        set_row( 24,   35, 32'h00400060, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 25,   36, 32'h00400064, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 26,   37, 32'h00400068, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 27,   38, 32'h0040006c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 28,   39, 32'h00400070, 32'h02100513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h00000021, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 29,   40, 32'h00400074, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 30,   41, 32'h00400078, 32'h00200493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000002, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 31,   43, 32'h0040007c, 32'h000505b3, 1, 5'd10, 32'h00000021, 1, 5'd0 , 32'h00000000, 5'd11, 32'h00000021, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  4);
        set_row( 32,   44, 32'h00400080, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 33,   45, 32'h00400084, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 34,   46, 32'h00400088, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 35,   47, 32'h0040008c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 36,   48, 32'h00400090, 32'h02c00513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h0000002c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 37,   49, 32'h00400094, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 38,   50, 32'h00400098, 32'h00200493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000002, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 39,   51, 32'h0040009c, 32'h00300493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000003, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 40,   52, 32'h004000a0, 32'h000505b3, 1, 5'd10, 32'h0000002c, 1, 5'd0 , 32'h00000000, 5'd11, 32'h0000002c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  5);
        set_row( 41,   53, 32'h004000a4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  6);
        set_row( 42,   54, 32'h004000a8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  6);
        set_row( 43,   55, 32'h004000ac, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  6);
        set_row( 44,   56, 32'h004000b0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  6);
        set_row( 45,   57, 32'h004000b4, 32'h03700513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h00000037, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  6);
        set_row( 46,   61, 32'h004000b8, 32'h00a005b3, 1, 5'd0 , 32'h00000000, 1, 5'd10, 32'h00000037, 5'd11, 32'h00000037, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  6);
        set_row( 47,   62, 32'h004000bc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 48,   63, 32'h004000c0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 49,   64, 32'h004000c4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 50,   65, 32'h004000c8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 51,   66, 32'h004000cc, 32'hff900613, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd12, 32'hfffffff9, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 52,   67, 32'h004000d0, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 53,   68, 32'h004000d4, 32'h06400693, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd13, 32'h00000064, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 54,   72, 32'h004000d8, 32'h40d60733, 1, 5'd12, 32'hfffffff9, 1, 5'd13, 32'h00000064, 5'd14, 32'hffffff95, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  7);
        set_row( 55,   73, 32'h004000dc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 56,   74, 32'h004000e0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 57,   75, 32'h004000e4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 58,   76, 32'h004000e8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 59,   77, 32'h004000ec, 32'h00500693, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd13, 32'h00000005, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 60,   78, 32'h004000f0, 32'h03200613, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd12, 32'h00000032, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 61,   79, 32'h004000f4, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 62,   82, 32'h004000f8, 32'h40d60733, 1, 5'd12, 32'h00000032, 1, 5'd13, 32'h00000005, 5'd14, 32'h0000002d, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  8);
        set_row( 63,   83, 32'h004000fc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  9);
        set_row( 64,   84, 32'h00400100, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  9);
        set_row( 65,   85, 32'h00400104, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  9);
        set_row( 66,   86, 32'h00400108, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0,  9);
        set_row( 67,   87, 32'h0040010c, 32'h030e2023, 1, 5'd28, 32'h10010000, 1, 5'd16, 32'h000001a6, 5'd0 , 32'h00000000, 2'd2, 32'h10010020, 4'b1111, 32'h000001a6, 0,  9);
        set_row( 68,   88, 32'h00400110, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 10);
        set_row( 69,   89, 32'h00400114, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 10);
        set_row( 70,   90, 32'h00400118, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 10);
        set_row( 71,   91, 32'h0040011c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 10);
        set_row( 72,   92, 32'h00400120, 32'h020e2703, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd14, 32'h000001a6, 2'd1, 32'h10010020, 4'b1111, 32'h000001a6, 0, 10);
        set_row( 73,   96, 32'h00400124, 32'h00e707b3, 1, 5'd14, 32'h000001a6, 1, 5'd14, 32'h000001a6, 5'd15, 32'h0000034c, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 10);
        set_row( 74,   97, 32'h00400128, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 11);
        set_row( 75,   98, 32'h0040012c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 11);
        set_row( 76,   99, 32'h00400130, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 11);
        set_row( 77,  100, 32'h00400134, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 11);
        set_row( 78,  101, 32'h00400138, 32'h020e2703, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd14, 32'h000001a6, 2'd1, 32'h10010020, 4'b1111, 32'h000001a6, 0, 11);
        set_row( 79,  102, 32'h0040013c, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 11);
        set_row( 80,  105, 32'h00400140, 32'h00e007b3, 1, 5'd0 , 32'h00000000, 1, 5'd14, 32'h000001a6, 5'd15, 32'h000001a6, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 11);
        set_row( 81,  106, 32'h00400144, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 12);
        set_row( 82,  107, 32'h00400148, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 12);
        set_row( 83,  108, 32'h0040014c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 12);
        set_row( 84,  109, 32'h00400150, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 12);
        set_row( 85,  110, 32'h00400154, 32'h020e2603, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd12, 32'h000001a6, 2'd1, 32'h10010020, 4'b1111, 32'h000001a6, 0, 12);
        set_row( 86,  114, 32'h00400158, 32'h04ce2023, 1, 5'd28, 32'h10010000, 1, 5'd12, 32'h000001a6, 5'd0 , 32'h00000000, 2'd2, 32'h10010040, 4'b1111, 32'h000001a6, 0, 12);
        set_row( 87,  115, 32'h0040015c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 88,  116, 32'h00400160, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 89,  117, 32'h00400164, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 90,  118, 32'h00400168, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 91,  119, 32'h0040016c, 32'h060e0893, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd17, 32'h10010060, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 92,  120, 32'h00400170, 32'h00100493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 93,  121, 32'h00400174, 32'h00200493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000002, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 94,  122, 32'h00400178, 32'h00300493, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd9 , 32'h00000003, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 13);
        set_row( 95,  123, 32'h0040017c, 32'h031e2223, 1, 5'd28, 32'h10010000, 1, 5'd17, 32'h10010060, 5'd0 , 32'h00000000, 2'd2, 32'h10010024, 4'b1111, 32'h10010060, 0, 13);
        set_row( 96,  124, 32'h00400180, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 14);
        set_row( 97,  125, 32'h00400184, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 14);
        set_row( 98,  126, 32'h00400188, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 14);
        set_row( 99,  127, 32'h0040018c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 14);
        set_row(100,  128, 32'h00400190, 32'h024e2903, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd18, 32'h10010060, 2'd1, 32'h10010024, 4'b1111, 32'h10010060, 0, 14);
        set_row(101,  132, 32'h00400194, 32'h01392023, 1, 5'd18, 32'h10010060, 1, 5'd19, 32'h00000777, 5'd0 , 32'h00000000, 2'd2, 32'h10010060, 4'b1111, 32'h00000777, 0, 14);
        set_row(102,  133, 32'h00400198, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 15);
        set_row(103,  134, 32'h0040019c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 15);
        set_row(104,  135, 32'h004001a0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 15);
        set_row(105,  136, 32'h004001a4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 15);
        set_row(106,  137, 32'h004001a8, 32'h040e2a03, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd20, 32'h000001a6, 2'd1, 32'h10010040, 4'b1111, 32'h000001a6, 0, 15);
        set_row(107,  138, 32'h004001ac, 32'h060e2a83, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd21, 32'h00000777, 2'd1, 32'h10010060, 4'b1111, 32'h00000777, 0, 15);
        set_row(108,  139, 32'h004001b0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 16);
        set_row(109,  140, 32'h004001b4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 16);
        set_row(110,  141, 32'h004001b8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 16);
        set_row(111,  142, 32'h004001bc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 16);
        set_row(112,  143, 32'h004001c0, 32'h002000b3, 1, 5'd0 , 32'h00000000, 1, 5'd2 , 32'h00000222, 5'd1 , 32'h00000222, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 16);
        set_row(113,  144, 32'h004001c4, 32'h00100193, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd3 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 16);
        set_row(114,  145, 32'h004001c8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 17);
        set_row(115,  146, 32'h004001cc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 17);
        set_row(116,  147, 32'h004001d0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 17);
        set_row(117,  148, 32'h004001d4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 17);
        set_row(118,  149, 32'h004001d8, 32'h12300293, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd5 , 32'h00000123, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 17);
        set_row(119,  150, 32'h004001dc, 32'h00528b37, 0, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd22, 32'h00528000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 17);
        set_row(120,  151, 32'h004001e0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 18);
        set_row(121,  152, 32'h004001e4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 18);
        set_row(122,  153, 32'h004001e8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 18);
        set_row(123,  154, 32'h004001ec, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 18);
        set_row(124,  155, 32'h004001f0, 32'h12400293, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd5 , 32'h00000124, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 18);
        set_row(125,  156, 32'h004001f4, 32'h00528b97, 0, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd23, 32'h009281f4, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 18);
        set_row(126,  157, 32'h004001f8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 19);
        set_row(127,  158, 32'h004001fc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 19);
        set_row(128,  159, 32'h00400200, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 19);
        set_row(129,  160, 32'h00400204, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 19);
        set_row(130,  161, 32'h00400208, 32'h07700393, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd7 , 32'h00000077, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 19);
        set_row(131,  162, 32'h0040020c, 32'h00700c13, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd24, 32'h00000007, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 19);
        set_row(132,  163, 32'h00400210, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 20);
        set_row(133,  164, 32'h00400214, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 20);
        set_row(134,  165, 32'h00400218, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 20);
        set_row(135,  166, 32'h0040021c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 20);
        set_row(136,  167, 32'h00400220, 32'h08800413, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd8 , 32'h00000088, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 20);
        set_row(137,  168, 32'h00400224, 32'h008e2c83, 1, 5'd28, 32'h10010000, 0, 5'd0 , 32'h00000000, 5'd25, 32'h00000000, 2'd1, 32'h10010008, 4'b1111, 32'h00000000, 0, 20);
        set_row(138,  169, 32'h00400228, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 21);
        set_row(139,  170, 32'h0040022c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 21);
        set_row(140,  171, 32'h00400230, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 21);
        set_row(141,  172, 32'h00400234, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 21);
        set_row(142,  173, 32'h00400238, 32'h010e2623, 1, 5'd28, 32'h10010000, 1, 5'd16, 32'h000001a6, 5'd0 , 32'h00000000, 2'd2, 32'h1001000c, 4'b1111, 32'h000001a6, 0, 21);
        set_row(143,  174, 32'h0040023c, 32'h00060d33, 1, 5'd12, 32'h000001a6, 1, 5'd0 , 32'h00000000, 5'd26, 32'h000001a6, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 21);
        set_row(144,  175, 32'h00400240, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 22);
        set_row(145,  176, 32'h00400244, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 22);
        set_row(146,  177, 32'h00400248, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 22);
        set_row(147,  178, 32'h0040024c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 22);
        set_row(148,  179, 32'h00400250, 32'h01000663, 1, 5'd0 , 32'h00000000, 1, 5'd16, 32'h000001a6, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 22);
        set_row(149,  180, 32'h00400254, 32'h00c00db3, 1, 5'd0 , 32'h00000000, 1, 5'd12, 32'h000001a6, 5'd27, 32'h000001a6, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 22);
        set_row(150,  181, 32'h00400258, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 23);
        set_row(151,  182, 32'h0040025c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 23);
        set_row(152,  183, 32'h00400260, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 23);
        set_row(153,  184, 32'h00400264, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 23);
        set_row(154,  185, 32'h00400268, 32'h00500013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 23);
        set_row(155,  186, 32'h0040026c, 32'h00000eb3, 1, 5'd0 , 32'h00000000, 1, 5'd0 , 32'h00000000, 5'd29, 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 23);
        set_row(156,  187, 32'h00400270, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 24);
        set_row(157,  188, 32'h00400274, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 24);
        set_row(158,  189, 32'h00400278, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 24);
        set_row(159,  190, 32'h0040027c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 24);
        set_row(160,  191, 32'h00400280, 32'h006283b3, 1, 5'd5 , 32'h00000124, 1, 5'd6 , 32'h00000066, 5'd7 , 32'h0000018a, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 24);
        set_row(161,  192, 32'h00400284, 32'h000284b3, 1, 5'd5 , 32'h00000124, 1, 5'd0 , 32'h00000000, 5'd9 , 32'h00000124, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 24);
        set_row(162,  193, 32'h00400288, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 25);
        set_row(163,  194, 32'h0040028c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 25);
        set_row(164,  195, 32'h00400290, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 25);
        set_row(165,  196, 32'h00400294, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 25);
        set_row(166,  197, 32'h00400298, 32'h000f0433, 1, 5'd30, 32'h0000003e, 1, 5'd0 , 32'h00000000, 5'd8 , 32'h0000003e, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 25);
        set_row(167,  198, 32'h0040029c, 32'h00100f13, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd30, 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 25);
        set_row(168,  199, 32'h004002a0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 26);
        set_row(169,  200, 32'h004002a4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 26);
        set_row(170,  201, 32'h004002a8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 26);
        set_row(171,  202, 32'h004002ac, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 26);
        set_row(172,  203, 32'h004002b0, 32'h006283b3, 1, 5'd5 , 32'h00000124, 1, 5'd6 , 32'h00000066, 5'd7 , 32'h0000018a, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 26);
        set_row(173,  204, 32'h004002b4, 32'h00100393, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd7 , 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 26);
        set_row(174,  205, 32'h004002b8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 27);
        set_row(175,  206, 32'h004002bc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 27);
        set_row(176,  207, 32'h004002c0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 27);
        set_row(177,  208, 32'h004002c4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 27);
        set_row(178,  209, 32'h004002c8, 32'h00038fb3, 1, 5'd7 , 32'h00000001, 1, 5'd0 , 32'h00000000, 5'd31, 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 27);
        set_row(179,  210, 32'h004002cc, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 28);
        set_row(180,  211, 32'h004002d0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 28);
        set_row(181,  212, 32'h004002d4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 28);
        set_row(182,  213, 32'h004002d8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 28);
        set_row(183,  214, 32'h004002dc, 32'h00528463, 1, 5'd5 , 32'h00000124, 1, 5'd5 , 32'h00000124, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 28);
        set_row(184,  217, 32'h004002e4, 32'h00100513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h00000001, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 28);
        set_row(185,  218, 32'h004002e8, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(186,  219, 32'h004002ec, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(187,  220, 32'h004002f0, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(188,  221, 32'h004002f4, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(189,  222, 32'h004002f8, 32'h00529463, 1, 5'd5 , 32'h00000124, 1, 5'd5 , 32'h00000124, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(190,  223, 32'h004002fc, 32'h00200513, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd10, 32'h00000002, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(191,  224, 32'h00400300, 32'h00300593, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd11, 32'h00000003, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 29);
        set_row(192,  225, 32'h00400304, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 30);
        set_row(193,  226, 32'h00400308, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 30);
        set_row(194,  227, 32'h0040030c, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 30);
        set_row(195,  228, 32'h00400310, 32'h00000013, 1, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 0, 30);
        set_row(196,  229, 32'h00400314, 32'h00100073, 0, 5'd0 , 32'h00000000, 0, 5'd0 , 32'h00000000, 5'd0 , 32'h00000000, 2'd0, 32'h00000000, 4'b0000, 32'h00000000, 1, 30);
        end
    endtask

    // END GENERATED

endmodule

`default_nettype wire
