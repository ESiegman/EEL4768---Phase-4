`default_nettype none

// The arithmetic logic unit (ALU) is responsible for performing the core
// calculations of the processor. It takes two 32-bit operands and outputs
// a 32 bit result based on the selection operation - addition, comparison,
// shift, or logical operation. This ALU is a purely combinational block, so
// you should not attempt to add any registers or pipeline it.
module alu (
    // Major operation selection.
    // 3'b000: addition/subtraction if `i_sub` asserted
    // 3'b001: shift left logical
    // 3'b010: set less than
    // 3'b011: set less than unsigned
    // 3'b100: exclusive or
    // 3'b101: shift right logical/arithmetic if `i_arith` asserted
    // 3'b110: or
    // 3'b111: and
    input  wire [ 2:0] i_opsel,
    // When asserted, addition operations should subtract instead.
    // This is only used for `i_opsel == 3'b000` (addition/subtraction).
    input  wire        i_sub,
    // When asserted, comparison operations should be treated as unsigned.
    input  wire        i_unsigned,
    // When asserted, right shifts should be treated as arithmetic instead of
    // logical. This is only used for `i_opsel == 3'b101` (shift right).
    input  wire        i_arith,
    // First 32-bit input operand.
    input  wire [31:0] i_op1,
    // Second 32-bit input operand.
    input  wire [31:0] i_op2,
    // 32-bit output result. Any carry out (from addition) should be ignored.
    output wire [31:0] o_result,
    // Equality result. This is used downstream to determine if a
    // branch should be taken.
    output wire        o_eq,
    // Set less than result. This is used downstream to determine if a
    // branch should be taken.
    output wire        o_slt
);
    // Your implementation goes under here
    // ------------------------------------

    wire [31:0] add_op2;
    wire [31:0] add_propagate;
    wire [31:0] add_generate;
    wire [31:0] add_group_p1;
    wire [31:0] add_group_g1;
    wire [31:0] add_group_p2;
    wire [31:0] add_group_g2;
    wire [31:0] add_group_p4;
    wire [31:0] add_group_g4;
    wire [31:0] add_group_p8;
    wire [31:0] add_group_g8;
    wire [31:0] add_group_p16;
    wire [31:0] add_group_g16;
    wire [31:0] carry_into;
    wire [31:0] add_sub_result;

    assign add_op2       = i_op2 ^ {32{i_sub}};
    assign add_propagate = i_op1 ^ add_op2;
    assign add_generate  = i_op1 & add_op2;

    assign add_group_g1 = add_generate |
                          (add_propagate & {add_generate[30:0], 1'b0});
    assign add_group_p1 = add_propagate &
                          {add_propagate[30:0], 1'b1};

    assign add_group_g2 = add_group_g1 |
                          (add_group_p1 & {add_group_g1[29:0], 2'b00});
    assign add_group_p2 = add_group_p1 &
                          {add_group_p1[29:0], 2'b11};

    assign add_group_g4 = add_group_g2 |
                          (add_group_p2 & {add_group_g2[27:0], 4'b0000});
    assign add_group_p4 = add_group_p2 &
                          {add_group_p2[27:0], 4'b1111};

    assign add_group_g8 = add_group_g4 |
                          (add_group_p4 & {add_group_g4[23:0], 8'b00000000});
    assign add_group_p8 = add_group_p4 &
                          {add_group_p4[23:0], 8'b11111111};

    assign add_group_g16 = add_group_g8 |
                           (add_group_p8 & {add_group_g8[15:0], 16'b0000000000000000});
    assign add_group_p16 = add_group_p8 &
                           {add_group_p8[15:0], 16'b1111111111111111};

    assign carry_into[0] = i_sub;
    assign carry_into[31:1] = add_group_g16[30:0] |
                              (add_group_p16[30:0] & {31{i_sub}});
    assign add_sub_result = add_propagate ^ carry_into;

    wire [31:0] sll_stage1;
    wire [31:0] sll_stage2;
    wire [31:0] sll_stage4;
    wire [31:0] sll_stage8;
    wire [31:0] sll_result;

    assign sll_stage1 = i_op2[0] ? {i_op1[30:0], 1'b0} : i_op1;
    assign sll_stage2 = i_op2[1] ? {sll_stage1[29:0], 2'b00} : sll_stage1;
    assign sll_stage4 = i_op2[2] ? {sll_stage2[27:0], 4'b0000} : sll_stage2;
    assign sll_stage8 = i_op2[3] ? {sll_stage4[23:0], 8'b00000000} : sll_stage4;
    assign sll_result = i_op2[4] ? {sll_stage8[15:0], 16'b0000000000000000} : sll_stage8;

    wire        right_fill;
    wire [31:0] srx_stage1;
    wire [31:0] srx_stage2;
    wire [31:0] srx_stage4;
    wire [31:0] srx_stage8;
    wire [31:0] right_shift_result;

    assign right_fill = i_arith & i_op1[31];
    assign srx_stage1 = i_op2[0] ? {right_fill, i_op1[31:1]} : i_op1;
    assign srx_stage2 = i_op2[1] ? {{2{right_fill}}, srx_stage1[31:2]} : srx_stage1;
    assign srx_stage4 = i_op2[2] ? {{4{right_fill}}, srx_stage2[31:4]} : srx_stage2;
    assign srx_stage8 = i_op2[3] ? {{8{right_fill}}, srx_stage4[31:8]} : srx_stage4;
    assign right_shift_result = i_op2[4] ? {{16{right_fill}}, srx_stage8[31:16]} : srx_stage8;

    wire [31:0] equal_bits;
    wire [31:0] equal_group1;
    wire [31:0] equal_group2;
    wire [31:0] equal_group4;
    wire [31:0] equal_group8;
    wire [31:0] equal_group16;
    wire [31:0] upper_equal;
    wire        unsigned_less;
    wire        signed_less;

    assign equal_bits = ~(i_op1 ^ i_op2);
    assign equal_group1 = equal_bits &
                          {1'b1, equal_bits[31:1]};
    assign equal_group2 = equal_group1 &
                          {2'b11, equal_group1[31:2]};
    assign equal_group4 = equal_group2 &
                          {4'b1111, equal_group2[31:4]};
    assign equal_group8 = equal_group4 &
                          {8'b11111111, equal_group4[31:8]};
    assign equal_group16 = equal_group8 &
                           {16'b1111111111111111, equal_group8[31:16]};

    assign upper_equal = {1'b1, equal_group16[31:1]};
    assign unsigned_less = |(upper_equal & ~i_op1 & i_op2);
    assign signed_less = (i_op1[31] ^ i_op2[31]) ? i_op1[31] : unsigned_less;

    assign o_eq  = ~|(i_op1 ^ i_op2);
    assign o_slt = i_unsigned ? unsigned_less : signed_less;

    reg [31:0] result;
    always @(*) begin
        case (i_opsel)
            3'b000: result = add_sub_result;
            3'b001: result = sll_result;
            3'b010: result = {31'b0, o_slt};
            3'b011: result = {31'b0, unsigned_less};
            3'b100: result = i_op1 ^ i_op2;
            3'b101: result = right_shift_result;
            3'b110: result = i_op1 | i_op2;
            default: result = i_op1 & i_op2;
        endcase
    end

    assign o_result = result;

endmodule

`default_nettype wire
