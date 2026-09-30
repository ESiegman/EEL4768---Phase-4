module rf_bypass_tb();
    reg clk;
    reg rst;
    reg [4:0] rs1_raddr;
    wire [31:0] rs1_rdata;
    reg [4:0] rs2_raddr;
    wire [31:0] rs2_rdata;
    reg [4:0] rd_waddr;
    reg [31:0] rd_wdata;
    integer i;
    integer errors;

    rf #(1) dut (
        .i_clk(clk),
        .i_rst(rst),
        .i_rs1_raddr(rs1_raddr),
        .o_rs1_rdata(rs1_rdata),
        .i_rs2_raddr(rs2_raddr),
        .o_rs2_rdata(rs2_rdata),
        .i_rd_waddr(rd_waddr),
        .i_rd_wdata(rd_wdata)
    );

    initial begin
        errors = 0;
        clk = 0;
        rst = 1;
        rs1_raddr = 5'b0;
        rs2_raddr = 5'b0;
        rd_waddr = 5'b0;
        rd_wdata = 32'b0;

        repeat (2) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // write to x0
        @(negedge clk);
        rd_waddr = 5'b00000;
        rd_wdata = 32'hDEADBEEF;
        @(posedge clk);
        @(negedge clk);
        rd_waddr = 5'b00000;
        @(posedge clk);
        if (rs1_rdata !== 32'b0) begin errors = errors + 1; $display("TEST FAILED: Write to x0 should not update register"); end

        // write to each of the other registers and read them back
        for (i = 1; i < 32; i = i + 1) begin
            // write
            @(negedge clk);
            rd_waddr = i[4:0];
            rd_wdata = {12'b0, i[4:0], i[4:0], i[4:0], i[4:0]}; // pattern
            
            // read back rs1 with bypass
            rs1_raddr = i[4:0];
            @(posedge clk);
            if (rs1_rdata !== {12'b0, i[4:0], i[4:0], i[4:0], i[4:0]}) 
                begin errors = errors + 1; $display("TEST FAILED: RS1 read back %08h for x%0d, expected %08h", rs1_rdata, i, {12'b0, i[4:0], i[4:0], i[4:0], i[4:0]}); end
                
            @(posedge clk);
            @(negedge clk);
            rd_waddr = 5'b00000;
            @(posedge clk);            

            // read back rs2
            rs2_raddr = i[4:0];
            @(posedge clk);
            if (rs2_rdata !== {12'b0, i[4:0], i[4:0], i[4:0], i[4:0]}) 
                begin errors = errors + 1; $display("TEST FAILED: RS2 read back %08h for x%0d, expected %08h", rs2_rdata, i, {12'b0, i[4:0], i[4:0], i[4:0], i[4:0]}); end
        end
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

    always #5 clk = ~clk;

endmodule