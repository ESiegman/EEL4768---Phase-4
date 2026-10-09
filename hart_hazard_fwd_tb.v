`timescale 1ns / 1ps
`default_nettype none

module hart_hazard_fwd_tb;
    hart_no_hazard_tb #(
        .FWD_EN(1),
        .BYPASS_EN(1),
        .CYCLE_TRACE(1),
        .PROGRAM_FILE("../traces/hazard_program.hex"),
        .TRACE_FILE("../traces/hazard_fwd.trace")
    ) test();
endmodule

`default_nettype wire
