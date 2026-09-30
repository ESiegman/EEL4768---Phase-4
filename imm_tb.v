`timescale 1ns / 1ps
`default_nettype none

// Self-checking testbench for the RV32I immediate generator.
module imm_tb;

    reg  [31:0] inst;
    reg  [ 5:0] format;
    wire [31:0] immediate;

    integer passed;
    integer failed;

    localparam [5:0] FMT_R = 6'b000001;
    localparam [5:0] FMT_I = 6'b000010;
    localparam [5:0] FMT_S = 6'b000100;
    localparam [5:0] FMT_B = 6'b001000;
    localparam [5:0] FMT_U = 6'b010000;
    localparam [5:0] FMT_J = 6'b100000;

    imm dut (
        .i_inst      (inst),
        .i_format    (format),
        .o_immediate (immediate)
    );

    // Drive one vector and compare after combinational logic settles.
    task check;
        input [511:0] label;
        input [ 31:0] t_inst;
        input [  5:0] t_format;
        input [ 31:0] want_immediate;
        begin
            inst   = t_inst;
            format = t_format;
            #1;

            if (immediate === want_immediate) begin
                passed = passed + 1;
                $display("[PASS] %0s", label);
            end else begin
                failed = failed + 1;
                $display("[FAIL] %0s", label);
                $display("         inst=%h format=%b", t_inst, t_format);
                $display("         immediate=%h (want %h)", immediate, want_immediate);
            end
        end
    endtask

    // Reference model written directly from the RV32I immediate layouts.
    function [31:0] model_immediate;
        input [31:0] m_inst;
        input [ 5:0] m_format;
        begin
            case (m_format)
                FMT_I:   model_immediate = {{20{m_inst[31]}}, m_inst[31:20]};
                FMT_S:   model_immediate = {{20{m_inst[31]}}, m_inst[31:25],
                                             m_inst[11:7]};
                FMT_B:   model_immediate = {{19{m_inst[31]}}, m_inst[31],
                                             m_inst[7], m_inst[30:25],
                                             m_inst[11:8], 1'b0};
                FMT_U:   model_immediate = {m_inst[31:12], 12'b0};
                FMT_J:   model_immediate = {{11{m_inst[31]}}, m_inst[31],
                                             m_inst[19:12], m_inst[20],
                                             m_inst[30:21], 1'b0};
                default: model_immediate = 32'b0;
            endcase
        end
    endfunction

    integer i;
    integer seed;
    reg [31:0] random_inst;
    reg [ 5:0] random_format;
    reg [31:0] expected;

    initial begin
        $dumpfile("imm.vcd");
        $dumpvars(0, imm_tb);

        passed = 0;
        failed = 0;
        $display("========== immediate generator testbench ==========");

        // R has no immediate.  This imm.v deliberately drives zero rather
        // than leaving the output unknown.
        $display("--- R and invalid formats ---");
        check("R-type returns zero",              32'hffff_ffff, FMT_R,       32'b0);
        check("all-zero selector returns zero",   32'h1234_5678, 6'b000000,  32'b0);
        check("multi-bit selector returns zero",  32'h89ab_cdef, 6'b000110,  32'b0);
        check("all-one selector returns zero",    32'hdead_beef, 6'b111111,  32'b0);

        // I: immediate is instruction bits 31 through 20.
        $display("--- I-type ---");
        check("I: zero",                          32'h0000_0000, FMT_I, 32'h0000_0000);
        check("I: largest positive immediate",    32'h7ff1_2345, FMT_I, 32'h0000_07ff);
        check("I: negative pattern sign extends", 32'habcd_5e70, FMT_I, 32'hffff_fabc);
        check("I: most negative immediate",       32'h800f_ffff, FMT_I, 32'hffff_f800);

        // S: immediate is split between bits 31 through 25 and 11 through 7.
        $display("--- S-type ---");
        check("S: split positive pattern",        32'h5400_0a80, FMT_S, 32'h0000_0555);
        check("S: split negative pattern",        32'hfa00_0600, FMT_S, 32'hffff_ffac);
        check("S: most negative immediate",       32'h8000_0000, FMT_S, 32'hffff_f800);

        // B: immediate is split across four fields and always has bit zero.
        $display("--- B-type ---");
        check("B: split positive pattern",        32'h2a00_0580, FMT_B, 32'h0000_0aaa);
        check("B: split negative pattern",        32'hfe00_0680, FMT_B, 32'hffff_ffec);
        check("B: most negative offset",          32'h8000_0000, FMT_B, 32'hffff_f000);

        // U copies its upper field and clears the lower twelve bits.
        $display("--- U-type ---");
        check("U: ordinary upper field",          32'h1234_5abc, FMT_U, 32'h1234_5000);
        check("U: sign bit is preserved",         32'h8000_0fff, FMT_U, 32'h8000_0000);
        check("U: all upper bits set",            32'hffff_ffff, FMT_U, 32'hffff_f000);

        // J: immediate is split across four fields and always has bit zero.
        $display("--- J-type ---");
        check("J: split positive pattern",        32'h4dfa_b000, FMT_J, 32'h000a_bcde);
        check("J: split negative pattern",        32'hd56f_f000, FMT_J, 32'hffff_f556);
        check("J: most negative offset",          32'h8000_0000, FMT_J, 32'hfff0_0000);

        // Random tests exercise all six valid selectors.  A fixed seed makes
        // a failure repeatable.
        $display("--- random ---");
        seed = 32'd4768;
        for (i = 0; i < 600; i = i + 1) begin
            random_inst = $random(seed);
            case (i % 6)
                0: random_format = FMT_R;
                1: random_format = FMT_I;
                2: random_format = FMT_S;
                3: random_format = FMT_B;
                4: random_format = FMT_U;
                default: random_format = FMT_J;
            endcase

            expected = model_immediate(random_inst, random_format);
            inst   = random_inst;
            format = random_format;
            #1;

            if (immediate !== expected) begin
                failed = failed + 1;
                $display("[FAIL] random %0d: inst=%h format=%b", i,
                         random_inst, random_format);
                $display("         immediate=%h (want %h)", immediate, expected);
            end else begin
                passed = passed + 1;
            end
        end
        $display("       600 random vectors checked against the model");

        $display("===================================================");
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");

        $finish;
    end

endmodule

`default_nettype wire
