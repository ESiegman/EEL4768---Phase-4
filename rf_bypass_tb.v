`timescale 1ns / 1ps
`default_nettype none

// Self-checking testbench for rf with BYPASS_EN = 1.
//
// What makes this different from rf_no_bypass_tb: a read of the register
// being written this cycle must return the NEW value (the write data) before
// the clock edge, except for x0, which always reads 0. An rf with bypass
// turned off fails section 4a here.
//
// Timing discipline, used everywhere below (clock period 10, posedge at
// multiples of 10, negedge at 5 past):
//   - inputs change only at a negedge (`sync` waits for one),
//   - combinational reads are checked at negedge + #1, + #2, ... and never
//     more than four reads per half cycle, so every check lands well before
//     the next posedge,
//   - a write's result is checked only after the posedge that commits it.
// Nothing is ever sampled on the posedge that commits a write.
module rf_bypass_tb;

    reg         clk;
    reg         rst;
    reg  [ 4:0] rs1_raddr;
    reg  [ 4:0] rs2_raddr;
    reg  [ 4:0] rd_waddr;
    reg  [31:0] rd_wdata;
    wire [31:0] rs1_rdata;
    wire [31:0] rs2_rdata;

    integer passed;
    integer failed;
    integer i;

    rf #(.BYPASS_EN(1)) dut (
        .i_clk       (clk),
        .i_rst       (rst),
        .i_rs1_raddr (rs1_raddr),
        .o_rs1_rdata (rs1_rdata),
        .i_rs2_raddr (rs2_raddr),
        .o_rs2_rdata (rs2_rdata),
        .i_rd_waddr  (rd_waddr),
        .i_rd_wdata  (rd_wdata)
    );

    always #5 clk = ~clk;

    task check;
        input [511:0] label;
        input [ 31:0] got;
        input [ 31:0] want;
        begin
            if (got === want) begin
                passed = passed + 1;
            end else begin
                failed = failed + 1;
                $display("[FAIL] %0s: got %h, expected %h", label, got, want);
            end
        end
    endtask

    // Drive both read addresses, settle for #1, and check both ports.
    task read2;
        input [511:0] label;
        input [  4:0] a1;
        input [ 31:0] want1;
        input [  4:0] a2;
        input [ 31:0] want2;
        begin
            rs1_raddr = a1;
            rs2_raddr = a2;
            #1;
            // Guard the timing discipline itself: a check must land in the
            // low half of the clock, between a negedge and the next posedge.
            check({label, " (testbench timing: clk low)"}, {31'd0, clk},
                  32'd0);
            check({label, " (rs1)"}, rs1_rdata, want1);
            check({label, " (rs2)"}, rs2_rdata, want2);
        end
    endtask

    // Wait for the next negedge (crossing one posedge). Inputs left as they
    // are, so whatever was being driven gets committed at that posedge.
    task sync;
        begin
            @(negedge clk);
        end
    endtask

    // Wait for the next negedge, then idle the write port and drop reset.
    task next_cycle;
        begin
            @(negedge clk);
            rd_waddr = 5'd0;
            rd_wdata = 32'd0;
            rst      = 1'b0;
        end
    endtask

    // Called at a negedge: write one register, return at the next negedge.
    task write_reg;
        input [ 4:0] addr;
        input [31:0] data;
        begin
            rd_waddr = addr;
            rd_wdata = data;
            next_cycle;
        end
    endtask

    // A distinct value for every register, so a read from the wrong address
    // is never mistaken for the right one. x1..x3 hold edge-case patterns.
    function [31:0] pat;
        input [4:0] r;
        begin
            case (r)
                5'd1:    pat = 32'hFFFFFFFF;
                5'd2:    pat = 32'h80000000;
                5'd3:    pat = 32'h00000001;
                default: pat = {3'b101, r, ~{3'b000, r}, 3'b011, r, 8'h3C};
            endcase
        end
    endfunction

    initial begin
        passed = 0;
        failed = 0;

        clk       = 1'b0;
        rst       = 1'b1;
        rs1_raddr = 5'd0;
        rs2_raddr = 5'd0;
        rd_waddr  = 5'd0;
        rd_wdata  = 32'd0;

        $display("========== rf_bypass testbench ==========");

        // Two cycles of reset, released at a negedge.
        sync;
        sync;
        rst = 1'b0;

        // --- 1. Reset clears every register ----------------------------------
        $display("--- 1. reset ---");
        write_reg(5'd1,  32'h11111111);
        write_reg(5'd7,  32'h77777777);
        write_reg(5'd16, 32'h16161616);
        write_reg(5'd31, 32'h31313131);
        read2("reset: x7/x31 written before reset", 5'd7, 32'h77777777,
              5'd31, 32'h31313131);
        sync;
        rst = 1'b1;
        next_cycle;
        for (i = 0; i < 32; i = i + 1) begin
            sync;
            read2("reset: register reads 0 after reset", i[4:0], 32'd0,
                  i[4:0], 32'd0);
        end

        // --- 2. x0 is hardwired to zero --------------------------------------
        $display("--- 2. x0 ---");
        sync;
        rd_waddr = 5'd0;
        rd_wdata = 32'hDEADBEEF;
        read2("x0: during write of DEADBEEF", 5'd0, 32'd0, 5'd0, 32'd0);
        next_cycle;
        read2("x0: after write of DEADBEEF", 5'd0, 32'd0, 5'd0, 32'd0);

        // --- 3. Every register x1..x31 holds its own value --------------------
        $display("--- 3. all registers ---");
        sync;
        for (i = 1; i < 32; i = i + 1)
            write_reg(i[4:0], pat(i[4:0]));
        for (i = 1; i < 32; i = i + 1) begin
            sync;
            read2("all regs: same register on both ports", i[4:0],
                  pat(i[4:0]), i[4:0], pat(i[4:0]));
        end
        // rs2 walks the other direction, so each port sees every register
        // while the other port reads a different one.
        for (i = 1; i < 32; i = i + 1) begin
            sync;
            read2("all regs: different registers per port", i[4:0],
                  pat(i[4:0]), 6'd32 - i[5:0], pat(6'd32 - i[5:0]));
        end
        sync;
        read2("all regs: x0 still zero", 5'd0, 32'd0, 5'd0, 32'd0);

        // --- 4. Bypass: the write port is visible on the read ports ----------
        $display("--- 4a. same-cycle read returns new value ---");
        sync;
        rd_waddr = 5'd5;
        rd_wdata = 32'hA5A5A5A5;
        read2("bypass: x5 before edge reads new", 5'd5, 32'hA5A5A5A5,
              5'd5, 32'hA5A5A5A5);
        next_cycle;
        read2("bypass: x5 after edge reads new", 5'd5, 32'hA5A5A5A5,
              5'd5, 32'hA5A5A5A5);

        sync;
        rd_waddr = 5'd17;
        rd_wdata = 32'h00000000;
        read2("bypass: x17 before edge reads new (zero)", 5'd17, 32'h00000000,
              5'd17, 32'h00000000);
        next_cycle;
        read2("bypass: x17 after edge reads new (zero)", 5'd17, 32'h00000000,
              5'd17, 32'h00000000);

        sync;
        rd_waddr = 5'd31;
        rd_wdata = 32'h0BADF00D;
        read2("bypass: x31 before edge reads new", 5'd31, 32'h0BADF00D,
              5'd31, 32'h0BADF00D);
        next_cycle;
        read2("bypass: x31 after edge reads new", 5'd31, 32'h0BADF00D,
              5'd31, 32'h0BADF00D);

        $display("--- 4b. other registers are not bypassed ---");
        sync;
        rd_waddr = 5'd8;
        rd_wdata = 32'h88888888;
        read2("bypass: x9/x7 while writing x8", 5'd9, pat(5'd9),
              5'd7, pat(5'd7));
        read2("bypass: x24/x1 while writing x8", 5'd24, pat(5'd24),
              5'd1, pat(5'd1));
        next_cycle;
        read2("bypass: x9/x7 after writing x8", 5'd9, pat(5'd9),
              5'd7, pat(5'd7));

        $display("--- 4c. bypass never leaks into x0 ---");
        sync;
        rd_waddr = 5'd0;
        rd_wdata = 32'hFFFFFFFF;
        read2("bypass: x0 while writing x0 with FFFFFFFF", 5'd0, 32'd0,
              5'd0, 32'd0);
        next_cycle;
        read2("bypass: x0 after writing x0 with FFFFFFFF", 5'd0, 32'd0,
              5'd0, 32'd0);

        $display("--- 4d. one port bypassed, the other not ---");
        sync;
        rd_waddr = 5'd1;
        rd_wdata = 32'h12345678;
        read2("bypass: rs1=x1 (being written), rs2=x2", 5'd1, 32'h12345678,
              5'd2, pat(5'd2));
        read2("bypass: rs1=x2, rs2=x1 (being written)", 5'd2, pat(5'd2),
              5'd1, 32'h12345678);
        read2("bypass: rs1=x0, rs2=x1 (being written)", 5'd0, 32'd0,
              5'd1, 32'h12345678);
        next_cycle;
        read2("bypass: x1 after edge", 5'd1, 32'h12345678, 5'd2, pat(5'd2));

        // --- 5. Ports and registers are independent ---------------------------
        $display("--- 5. independence ---");
        sync;
        read2("independence: rs1=x3, rs2=x30", 5'd3, pat(5'd3),
              5'd30, pat(5'd30));
        read2("independence: rs1=x30, rs2=x3", 5'd30, pat(5'd30),
              5'd3, pat(5'd3));
        sync;
        rd_waddr = 5'd10;
        rd_wdata = 32'hCAFEBABE;
        read2("independence: x11/x9 while writing x10", 5'd11, pat(5'd11),
              5'd9, pat(5'd9));
        next_cycle;
        read2("independence: x11/x9 after writing x10", 5'd11, pat(5'd11),
              5'd9, pat(5'd9));
        read2("independence: x10 written", 5'd10, 32'hCAFEBABE,
              5'd10, 32'hCAFEBABE);

        // --- 6. Back-to-back writes to one register: last one wins ------------
        $display("--- 6. last write wins ---");
        sync;
        rd_waddr = 5'd12;
        rd_wdata = 32'h1111AAAA;
        sync;
        rd_waddr = 5'd12;
        rd_wdata = 32'h2222BBBB;
        read2("last write: x12 during 2nd write sees 2nd value", 5'd12,
              32'h2222BBBB, 5'd12, 32'h2222BBBB);
        next_cycle;
        read2("last write: x12 after both writes", 5'd12, 32'h2222BBBB,
              5'd12, 32'h2222BBBB);

        // --- 7. Reset beats a write in the same cycle ------------------------
        $display("--- 7. reset priority ---");
        sync;
        write_reg(5'd20, 32'h20202020);
        read2("reset priority: x20 set up", 5'd20, 32'h20202020,
              5'd20, 32'h20202020);
        sync;
        rst      = 1'b1;
        rd_waddr = 5'd20;
        rd_wdata = 32'hFEEDFACE;
        next_cycle;
        read2("reset priority: x20 is 0, not the write data", 5'd20, 32'd0,
              5'd20, 32'd0);
        read2("reset priority: other registers also 0", 5'd10, 32'd0,
              5'd31, 32'd0);

        $display("============================================");
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule

`default_nettype wire
