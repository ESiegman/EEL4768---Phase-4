// The immediate generator is responsible for decoding the 32-bit
// sign-extended immediate from the incoming instruction word. It is a purely
// combinational block that is expected to be embedded in the instruction
// decoder.
module imm (
    // Input instruction word. This is used to extract the relevant immediate
    // bits and assemble them into the final immediate.
    input  wire [31:0] i_inst,
    // Instruction format, determined by the instruction decoder based on the
    // opcode. This is one-hot encoded according to the following format:
    // [0] R-type
    // [1] I-type
    // [2] S-type
    // [3] B-type
    // [4] U-type
    // [5] J-type
    // Because the R-type format does not have an immediate, the output
    // immediate can be treated as a don't-care under this case.
    input  wire [ 5:0] i_format,
    // Output 32-bit immediate, sign-extended from the immediate bitstring.
    output wire [31:0] o_immediate
);
    // Your implementation goes under here
    // ------------------------------------

    // one-hot format codes, named so the mux below reads as the format
    // table in the header rather than as six anonymous bit patterns
    // bit [0] is R, not I, R is the format with no immediate at all
    localparam [5:0] FMT_R = 6'b000001;
    localparam [5:0] FMT_I = 6'b000010;
    localparam [5:0] FMT_S = 6'b000100;
    localparam [5:0] FMT_B = 6'b001000;
    localparam [5:0] FMT_U = 6'b010000;
    localparam [5:0] FMT_J = 6'b100000;

    // I-type
    // imm[11:0] = i_inst[31:20], sign-extended.
    // 20 + 12 = 32
    wire [31:0] i_imm = {{20{i_inst[31]}}, i_inst[31:20]};

    // S-type: immediate is split so rs1 and rs2 stay in the same place as in R-type
    // imm[11:5] = i_inst[31:25], imm[4:0] = i_inst[11:7].
    // 20 + 7 + 5 = 32
    wire [31:0] s_imm = {{20{i_inst[31]}}, i_inst[31:25], i_inst[11:7]};

    // B-type
    // imm[12] = i_inst[31], imm[11] = i_inst[7], imm[10:5] = i_inst[30:25],
    // imm[4:1] = i_inst[11:8], imm[0] = 0.
    // replication is 19, not 20: imm[31:12] is 20 copies of the sign and
    // i_inst[31] below supplies one of them itself
    // 19 + 1 + 1 + 6 + 4 + 1 = 32
    wire [31:0] b_imm = {{19{i_inst[31]}}, i_inst[31], i_inst[7],
                         i_inst[30:25], i_inst[11:8], 1'b0};

    // U-type: the one format that is not sign-extended, the field is
    // already full-width
    // imm[31:12] = i_inst[31:12], imm[11:0] = 0
    // 20 + 12 = 32
    wire [31:0] u_imm = {i_inst[31:12], 12'b0};

    // J-type
    // imm[20] = i_inst[31], imm[19:12] = i_inst[19:12], imm[11] = i_inst[20],
    // imm[10:1] = i_inst[30:21], imm[0] = 0.
    // replication is 11: imm[31:20] is 12 copies of the sign and i_inst[31]
    // below supplies one of them itself
    // 11 + 1 + 8 + 1 + 10 + 1 = 32
    wire [31:0] j_imm = {{11{i_inst[31]}}, i_inst[31], i_inst[19:12],
                         i_inst[20], i_inst[30:21], 1'b0};

    // R has no immediate so the spec calls its output a don't-care, but it
    // is driven to 0 here rather than left undriven, which would propagate x
    // into the decoder. malformed (non-one-hot) selectors share the default
    reg [31:0] immediate;

    always @(*) begin
        case (i_format)
            FMT_I:   immediate = i_imm;
            FMT_S:   immediate = s_imm;
            FMT_B:   immediate = b_imm;
            FMT_U:   immediate = u_imm;
            FMT_J:   immediate = j_imm;
            FMT_R:   immediate = 32'b0;
            default: immediate = 32'b0;
        endcase
    end

    assign o_immediate = immediate;

endmodule
