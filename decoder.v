`default_nettype none

// Remember to instantiate the imm in this module

module decoder (
    // Input instruction word.
    input  wire [31:0] i_inst,
    // Asserted if the instruction was decoded as a legal instruction. It is
    // important that the decoder not accept any illegal instruction
    // encodings as this could lead to undefined behavior in the processor
    // which is a safety hazard.
    output wire        o_legal,
    // Indicates that the instruction is an ebreak and should halt execution.
    output wire        o_halt,
    // First source register address.
    // For instructions that do not use a source register, this is effectively
    // a don't care because reading unused registers does not have any side
    // effects (and we don't care about power usage, really).
    output wire [ 4:0] o_rs1,
    // Second source register address.
    // Similarly to o_rs1, this is a don't care for instructions that do not
    // read a (second) source register.
    output wire [ 4:0] o_rs2,
    // Destination register address.
    // For instructions that do not write to a register, this must be set to
    // x0 so the value is discarded. This avoids the need for a separate write
    // enable since discard behavior must be present anyway.
    output wire [ 4:0] o_rd,
    // 32-bit immediate value, decoded from the instruction word. For R-type
    // instructions that do not use an immediate, this is a don't care.
    output wire [31:0] o_immediate,
    // Selects whether the first operand for the ALU is fed by the first
    // register source (rs1) or the current pc.
    // When asserted, the second operand is the immediate.
    output wire        o_op1_sel,
    // Selects whether the second operand for the ALU is fed by the second
    // register source (rs2) or the immediate.
    // When asserted, the second operand is the immediate.
    output wire        o_op2_sel,
    // Major opsel for the ALU. See ALU documentation for the encoding.
    output wire [ 2:0] o_alu_opsel,
    // Minor opsel flags for the ALU. See ALU documentation for the encoding.
    output wire        o_alu_sub,
    output wire        o_alu_unsigned,
    output wire        o_alu_arith,
    // If asserted, the instruction is a branch instruction and the PC should
    // be updated to the target address if the branch condition is met.
    output wire        o_branch,
    // If asserted, the instruction is a jump instruction and the PC should
    // be updated to the target address unconditionally.
    output wire        o_jump,
    // When asserted, the branch comparator checks for equality. When not
    // asserted, it checks for less than [unsigned].
    output wire        o_branch_equal,
    // When asserted, the branch comparator treats the less than comparison
    // operands as unsigned. This is only used when `!o_branch_equal`.
    output wire        o_branch_unsigned,
    // When asserted, the branch condition is inverted.
    // Equality -> inequality, less than -> greater than or equal.
    output wire        o_branch_invert,
    // When asserted, the instruction will load from memory.
    output wire        o_dmem_ren,
    // When asserted, the instruction will store to memory.
    output wire        o_dmem_wen,
    // This 2-bit mask selects which LSBs of the memory address should be
    // checked for alignment. This is because byte and half-word accesses need
    // only be 1-byte and 2-byte aligned, respectively.
    output wire [ 1:0] o_dmem_align,
    // These 3 bits select the size of the memory access.
    // They are effectively one-hot encoded.
    output wire        o_dmem_memb,
    output wire        o_dmem_memh,
    output wire        o_dmem_memw,
    // If asserted, the (byte or half-word) memory access is unsigned and the
    // load should be zero-extended to 32 bits instead of sign-extended.
    output wire        o_dmem_memu,
    // Selects the data to write to the destination register, one-hot.
    // [0] = ALU result
    // [1] = immediate
    // [2] = PC + 4
    // [3] = memory
    output wire [ 3:0] o_rd_sel,
    // If asserted, the PC jumps to the target address calculated by the ALU
    // rather than directly to the PC + immediate. This is used for JALR.
    output wire        o_pc_sel
);
  wire [6:0] opcode = i_inst[6:0];
  wire [4:0] rd = i_inst[11:7];
  wire [2:0] funct3 = i_inst[14:12];
  wire [4:0] rs1 = i_inst[19:15];
  wire [4:0] rs2 = i_inst[24:20];
  wire [6:0] funct7 = i_inst[31:25];

  localparam reg [6:0] OpcLui = 7'b0110111;
  localparam reg [6:0] OpcAuipc = 7'b0010111;
  localparam reg [6:0] OpcJal = 7'b1101111;
  localparam reg [6:0] OpcJalr = 7'b1100111;
  localparam reg [6:0] OpcBranch = 7'b1100011;
  localparam reg [6:0] OpcLoad = 7'b0000011;
  localparam reg [6:0] OpcStore = 7'b0100011;
  localparam reg [6:0] OpcOpImm = 7'b0010011;
  localparam reg [6:0] OpcOp = 7'b0110011;

  wire is_lui = (opcode == OpcLui);
  wire is_auipc = (opcode == OpcAuipc);
  wire is_jal = (opcode == OpcJal);

  wire is_jalr = (opcode == OpcJalr && funct3 == 3'b000);
  wire is_branch = (opcode == OpcBranch && !(funct3 == 3'b010 || funct3 == 3'b011));
  wire is_load = (opcode == OpcLoad && !(funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111));
  wire is_store = (opcode == OpcStore && (funct3 == 3'b000 ||
                funct3 == 3'b001 || funct3 == 3'b010));
  wire is_op_imm = (opcode == OpcOpImm && (funct3 != 3'b001 ||
                funct7 == 7'b0000000) && (funct3 != 3'b101 || (funct7 == 7'b0000000 ||
                funct7 == 7'b0100000)));
  wire is_op = (opcode == OpcOp && (funct7 == 7'b0000000 ||
                ((funct3 == 3'b000 || funct3 == 3'b101) && funct7 == 7'b0100000)));
  wire is_ebreak = (i_inst == 32'h00100073);
  assign o_legal = is_lui | is_auipc | is_jal | is_jalr | is_branch |
                    is_load | is_store | is_op_imm | is_op | is_ebreak;
  assign o_halt = is_ebreak;

  wire is_op_or_imm = is_op | is_op_imm;
  wire is_dmem_access = is_load | is_store;

  wire [5:0] format;
  assign format[0] = is_op;
  assign format[1] = is_jalr || is_load || is_op_imm;
  assign format[2] = is_store;
  assign format[3] = is_branch;
  assign format[4] = is_lui || is_auipc;
  assign format[5] = is_jal;

  imm immediate (
      .i_inst     (i_inst),
      .i_format   (format),
      .o_immediate(o_immediate)
  );

  assign o_rs1 = rs1;
  assign o_rs2 = rs2;
  assign o_op1_sel = is_auipc;
  assign o_op2_sel = is_op_imm | is_load | is_store | is_auipc | is_jalr;
  assign o_alu_opsel = is_op_or_imm ? funct3 : 3'b000;
  assign o_alu_sub = is_op && funct3 == 3'b000 && funct7 == 7'b0100000;
  assign o_alu_unsigned = is_branch ? funct3[1] : (is_op_or_imm && funct3 == 3'b011);
  assign o_alu_arith = is_op_or_imm && funct3 == 3'b101 && funct7 == 7'b0100000;
  assign o_branch = is_branch;
  assign o_jump = is_jal | is_jalr;
  assign o_pc_sel = is_jalr;
  assign o_branch_equal = ~funct3[2];
  assign o_branch_unsigned = funct3[1];
  assign o_branch_invert = funct3[0];

  assign o_dmem_ren = is_load;
  assign o_dmem_wen = is_store;
  assign o_dmem_memb = is_dmem_access && funct3[1:0] == 2'b00;
  assign o_dmem_memh = is_dmem_access && funct3[1:0] == 2'b01;
  assign o_dmem_memw = is_dmem_access && funct3[1:0] == 2'b10;
  assign o_dmem_memu = is_load && funct3[2];
  assign o_dmem_align = o_dmem_memw ? 2'b11 : (o_dmem_memh ? 2'b01 : 2'b00);
  assign o_rd_sel[0] = is_op_or_imm | is_auipc;
  assign o_rd_sel[1] = is_lui;
  assign o_rd_sel[2] = o_jump;
  assign o_rd_sel[3] = is_load;
  assign o_rd = (|o_rd_sel) ? rd : 5'd0;

endmodule

`default_nettype wire
