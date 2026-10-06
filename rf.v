`default_nettype none

// The register file is effectively a single cycle memory with 32-bit words
// and depth 32. It has two asynchronous read ports, allowing two independent
// registers to be read at the same time combinationally, and one synchronous
// write port, allowing a register to be written to on the next clock edge.
//
// The register `x0` is hardwired to zero.
// NOTE: This can be implemented either by silently discarding writes to
// address 5'd0, or by muxing the output to zero when reading from that
// address.
module rf #
(
    // When this parameter is set to 1, "RF bypass" mode is enabled. A value
    // at the write port is seen on the read ports in the same cycle, without
    // waiting for the next clock edge (a write to x0 is never bypassed).
    // When it is 0, reads return only the stored value until the edge.
    //
    // Phase 4 instantiates rf with BYPASS_EN = 1 (phase_4.pdf section 4.4),
    // so that is the default, matching the TA skeleton. Both modes must be
    // implemented; rf_bypass_tb.v and rf_no_bypass_tb.v test one each.
    parameter BYPASS_EN = 1
) 

(
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Both read register ports are asynchronous (zero-cycle). That is, read
    // data is visible combinationally without having to wait for a clock.
    //
    // The read ports are *independent* and can read two different registers
    // (but of course, also the same register if needed).
    //
    // Register `x0` is hardwired to zero, so reading from address 5'd0
    // should always return 32'd0 on either port regardless of any writes.
    //
    // Register read port 1, with input address [0, 31] and output data.
    input  wire [ 4:0] i_rs1_raddr,
    output wire [31:0] o_rs1_rdata,
    // Register read port 2, with input address [0, 31] and output data.
    input  wire [ 4:0] i_rs2_raddr,
    output wire [31:0] o_rs2_rdata,
    
    // The register write port is synchronous. with no write enable,
    // a write to any adress other than 5'd0 happens at the next
    // clock edge.
    // A write to 5'd0 is discarded, so x0 stays zero.
    //
    // Write register address [0, 31] and input data.
    input  wire [ 4:0] i_rd_waddr,
    input  wire [31:0] i_rd_wdata
);
    // Your implementation goes under here
    // ------------------------------------
    
reg  [31:0] regs [0:31];

genvar i;
generate
    for (i = 1; i < 32; i = i + 1) begin : g_regs
    always @(posedge i_clk)
    begin
    //reset is checked first, so it wins over a write in the same cycle
        if (i_rst)
        //resets all registers to 0.
        regs[i] <= 32'd0;
        //there is no write enable: the register is written when the write
        //address selects it (address 0 selects nothing, so it means "no write")
        else if (i_rd_waddr == i)
        //when neither of the conditions are met, the register holds the value
        regs[i] <= i_rd_wdata;
    end
end
endgenerate

//rsX_stored is a 32 bit value. If the address on the read address is 0, then its 0
//otherwise, it is the whatever data is stored inside the array at the address
wire [31:0] rs1_stored = (i_rs1_raddr == 5'd0) ? 32'd0 : regs[i_rs1_raddr];
wire [31:0] rs2_stored = (i_rs2_raddr == 5'd0) ? 32'd0 : regs[i_rs2_raddr];

generate
if (BYPASS_EN != 0)
begin : g_bypass
    //bypass when reading the register being written this cycle (never x0)
    wire rs1_byp = (i_rs1_raddr == i_rd_waddr) && (i_rs1_raddr != 5'd0);
    wire rs2_byp = (i_rs2_raddr == i_rd_waddr) && (i_rs2_raddr != 5'd0);
    assign o_rs1_rdata = rs1_byp ? i_rd_wdata : rs1_stored;
    assign o_rs2_rdata = rs2_byp ? i_rd_wdata : rs2_stored;
end
else 
begin : g_no_bypass
    assign o_rs1_rdata = rs1_stored;
    assign o_rs2_rdata = rs2_stored;
end
endgenerate
endmodule

`default_nettype wire
