`default_nettype none

module hart #(
    // After reset, the program counter (PC) should be initialized to this
    // address and start executing instructions from there.
    parameter RESET_ADDR = 32'h00400000,
    // When set, pipeline forwarding optimizations are enabled.
    parameter FWD_EN = 1,
    // When set, register file bypassing is enabled.
    parameter BYPASS_EN = 1
) (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Instruction fetch goes through a read only instruction memory (imem)
    // port. The port accepts a 32-bit address (e.g. from the program counter)
    // per cycle and combinationally returns a 32-bit instruction word. This
    // is not representative of a realistic memory interface; it has been
    // modeled as more similar to a DFF or SRAM to simplify phase 3. In
    // later phases, you will replace this with a more realistic memory.
    //
    // 32-bit read address for the instruction memory. This is expected to be
    // 4 byte aligned - that is, the two LSBs should be zero.
    output wire [31:0] o_imem_raddr,
    // Instruction word fetched from memory, available on the same cycle.
    input  wire [31:0] i_imem_rdata,
    // Data memory accesses go through a separate read/write data memory (dmem)
    // that is shared between read (load) and write (stored). The port accepts
    // a 32-bit address, read or write enable, and mask (explained below) each
    // cycle. Reads are combinational - values are available immediately after
    // updating the address and asserting read enable. Writes occur on (and
    // are visible at) the next clock edge.
    //
    // Read/write address for the data memory. This should be 32-bit aligned
    // (i.e. the two LSB should be zero). See `o_dmem_mask` for how to perform
    // half-word and byte accesses at unaligned addresses.
    output wire [31:0] o_dmem_addr,
    // When asserted, the memory will perform a read at the aligned address
    // specified by `i_addr` and return the 32-bit word at that address
    // immediately (i.e. combinationally). It is illegal to assert this and
    // `o_dmem_wen` on the same cycle.
    output wire        o_dmem_ren,
    // When asserted, the memory will perform a write to the aligned address
    // `o_dmem_addr`. When asserted, the memory will write the bytes in
    // `o_dmem_wdata` (specified by the mask) to memory at the specified
    // address on the next rising clock edge. It is illegal to assert this and
    // `o_dmem_ren` on the same cycle.
    output wire        o_dmem_wen,
    // The 32-bit word to write to memory when `o_dmem_wen` is asserted. When
    // write enable is asserted, the byte lanes specified by the mask will be
    // written to the memory word at the aligned address at the next rising
    // clock edge. The other byte lanes of the word will be unaffected.
    output wire [31:0] o_dmem_wdata,
    // The dmem interface expects word (32 bit) aligned addresses. However,
    // WISC-25 supports byte and half-word loads and stores at unaligned and
    // 16-bit aligned addresses, respectively. To support this, the access
    // mask specifies which bytes within the 32-bit word are actually read
    // from or written to memory.
    //
    // To perform a half-word read at address 0x00001002, align `o_dmem_addr`
    // to 0x00001000, assert `o_dmem_ren`, and set the mask to 0b1100 to
    // indicate that only the upper two bytes should be read. Only the upper
    // two bytes of `i_dmem_rdata` can be assumed to have valid data; to
    // calculate the final value of the `lh[u]` instruction, shift the rdata
    // word right by 16 bits and sign/zero extend as appropriate.
    //
    // To perform a byte write at address 0x00002003, align `o_dmem_addr` to
    // `0x00002003`, assert `o_dmem_wen`, and set the mask to 0b1000 to
    // indicate that only the upper byte should be written. On the next clock
    // cycle, the upper byte of `o_dmem_wdata` will be written to memory, with
    // the other three bytes of the aligned word unaffected. Remember to shift
    // the value of the `sb` instruction left by 24 bits to place it in the
    // appropriate byte lane.
    output wire [ 3:0] o_dmem_mask,
    // The 32-bit word read from data memory. When `o_dmem_ren` is asserted,
    // this will immediately reflect the contents of memory at the specified
    // address, for the bytes enabled by the mask. When read enable is not
    // asserted, or for bytes not set in the mask, the value is undefined.
    input  wire [31:0] i_dmem_rdata,
    // The output `retire` interface is used to signal to the testbench that
    // the CPU has completed and retired an instruction. A single cycle
    // implementation will assert this every cycle; however, a pipelined
    // implementation that needs to stall (due to internal hazards or waiting
    // on memory accesses) will not assert the signal on cycles where the
    // instruction in the writeback stage is not retiring.
    //
    // Asserted when an instruction is being retired this cycle. If this is
    // not asserted, the other retire signals are ignored and may be left invalid.
    output wire        o_retire_valid,
    // The 32 bit instruction word of the instrution being retired. This
    // should be the unmodified instruction word fetched from instruction
    // memory.
    output wire [31:0] o_retire_inst,
    // Asserted if the instruction produced a trap, due to an illegal
    // instruction, unaligned data memory access, or unaligned instruction
    // address on a taken branch or jump.
    output wire        o_retire_trap,
    // Asserted if the instruction is an `ebreak` instruction used to halt the
    // processor. This is used for debugging and testing purposes to end
    // a program.
    output wire        o_retire_halt,
    // The first register address read by the instruction being retired. If
    // the instruction does not read from a register (like `lui`), this
    // should be 5'd0.
    output wire [ 4:0] o_retire_rs1_raddr,
    // The second register address read by the instruction being retired. If
    // the instruction does not read from a second register (like `addi`), this
    // should be 5'd0.
    output wire [ 4:0] o_retire_rs2_raddr,
    // The first source register data read from the register file (in the
    // decode stage) for the instruction being retired. If rs1 is 5'd0, this
    // should also be 32'd0.
    output wire [31:0] o_retire_rs1_rdata,
    // The second source register data read from the register file (in the
    // decode stage) for the instruction being retired. If rs2 is 5'd0, this
    // should also be 32'd0.
    output wire [31:0] o_retire_rs2_rdata,
    // The destination register address written by the instruction being
    // retired. If the instruction does not write to a register (like `sw`),
    // this should be 5'd0.
    output wire [ 4:0] o_retire_rd_waddr,
    // The destination register data written to the register file in the
    // writeback stage by this instruction. If rd is 5'd0, this field is
    // ignored and can be treated as a don't care.
    output wire [31:0] o_retire_rd_wdata,
    output wire [31:0] o_retire_dmem_addr,
    output wire [ 3:0] o_retire_dmem_mask,
    output wire        o_retire_dmem_ren,
    output wire        o_retire_dmem_wen,
    output wire [31:0] o_retire_dmem_rdata,
    output wire [31:0] o_retire_dmem_wdata,
    // The current program counter of the instruction being retired - i.e.
    // the instruction memory address that the instruction was fetched from.
    output wire [31:0] o_retire_pc,
    // the next program counter after the instruction is retired. For most
    // instructions, this is `o_retire_pc + 4`, but must be the branch or jump
    // target for *taken* branches and jumps.
    output wire [31:0] o_retire_next_pc

`ifdef RISCV_FORMAL
    ,`RVFI_OUTPUTS,
`endif
);

  // Your implementation goes under here
  // ------------------------------------
  // 5-stage pipeline: IF -> ID -> EX -> MEM -> WB.
  // Branches and jumps resolve in EX (2-cycle flush when taken). Hazards are
  // detected in ID; with FWD_EN, EX operands are forwarded from MEM and WB and
  // only load-use stalls. Instructions retire from WB.

  // Bubbles are filled with addi x0, x0, 0 (phase_4.pdf 4.2.4).
  localparam [31:0] NOP = 32'h00000013;

  // ---------------- Hazard / flush control (driven below) ----------------
  wire        stall;     // hold PC and IF/ID, bubble into ID/EX
  wire        redirect;  // taken branch/jump in EX: flush IF/ID and ID/EX
  wire [31:0] redirect_pc;
  wire        id_halt;   // ebreak in ID: stop fetching behind it
  reg         halted;

  // ---------------- IF ----------------
  reg  [31:0] pc;
  always @(posedge i_clk) begin
    if (i_rst) begin
      pc <= RESET_ADDR;
    end else if (redirect) begin
      pc <= redirect_pc;
    end else if (!stall && !id_halt && !halted) begin
      pc <= pc + 32'd4;
    end
  end
  assign o_imem_raddr = pc;

  // IF/ID
  reg         id_valid;
  reg  [31:0] id_pc;
  reg  [31:0] id_inst;
  always @(posedge i_clk) begin
    if (i_rst) begin
      id_valid <= 1'b0;
      id_pc    <= 32'd0;
      id_inst  <= NOP;
    end else if (redirect) begin
      id_valid <= 1'b0;
      id_inst  <= NOP;
    end else if (!stall) begin
      id_valid <= ~id_halt & ~halted;
      id_pc    <= pc;
      id_inst  <= (id_halt | halted) ? NOP : i_imem_rdata;
    end
  end

  // ---------------- ID ----------------
  wire        dec_legal;
  wire        dec_halt;
  wire [ 4:0] dec_rs1;
  wire [ 4:0] dec_rs2;
  wire [ 4:0] dec_rd;
  wire [31:0] dec_immediate;
  wire        dec_op1_sel;
  wire        dec_op2_sel;
  wire [ 2:0] dec_alu_opsel;
  wire        dec_alu_sub;
  wire        dec_alu_unsigned;
  wire        dec_alu_arith;
  wire        dec_branch;
  wire        dec_jump;
  wire        dec_branch_equal;
  wire        dec_branch_unsigned;
  wire        dec_branch_invert;
  wire        dec_dmem_ren;
  wire        dec_dmem_wen;
  wire [ 1:0] dec_dmem_align;
  wire        dec_dmem_memb;
  wire        dec_dmem_memh;
  wire        dec_dmem_memw;
  wire        dec_dmem_memu;
  wire [ 3:0] dec_rd_sel;
  wire        dec_pc_sel;
  wire        dec_uses_rs1;
  wire        dec_uses_rs2;
  wire        dec_is_load;

  decoder decoder_inst (
      .i_inst           (id_inst),
      .o_legal          (dec_legal),
      .o_halt           (dec_halt),
      .o_rs1            (dec_rs1),
      .o_rs2            (dec_rs2),
      .o_rd             (dec_rd),
      .o_immediate      (dec_immediate),
      .o_op1_sel        (dec_op1_sel),
      .o_op2_sel        (dec_op2_sel),
      .o_alu_opsel      (dec_alu_opsel),
      .o_alu_sub        (dec_alu_sub),
      .o_alu_unsigned   (dec_alu_unsigned),
      .o_alu_arith      (dec_alu_arith),
      .o_branch         (dec_branch),
      .o_jump           (dec_jump),
      .o_branch_equal   (dec_branch_equal),
      .o_branch_unsigned(dec_branch_unsigned),
      .o_branch_invert  (dec_branch_invert),
      .o_dmem_ren       (dec_dmem_ren),
      .o_dmem_wen       (dec_dmem_wen),
      .o_dmem_align     (dec_dmem_align),
      .o_dmem_memb      (dec_dmem_memb),
      .o_dmem_memh      (dec_dmem_memh),
      .o_dmem_memw      (dec_dmem_memw),
      .o_dmem_memu      (dec_dmem_memu),
      .o_rd_sel         (dec_rd_sel),
      .o_pc_sel         (dec_pc_sel),
      .o_uses_rs1       (dec_uses_rs1),
      .o_uses_rs2       (dec_uses_rs2),
      .o_is_load        (dec_is_load)
  );

  // Only read (and report) source registers the instruction actually uses,
  // so immediate bits that look like a register can't cause a false stall.
  wire [ 4:0] id_rs1 = dec_uses_rs1 ? dec_rs1 : 5'd0;
  wire [ 4:0] id_rs2 = dec_uses_rs2 ? dec_rs2 : 5'd0;
  wire [ 4:0] id_rd = dec_legal ? dec_rd : 5'd0;
  assign id_halt = id_valid & dec_halt;

  wire [31:0] rf_rs1_data, rf_rs2_data;
  wire [ 4:0] rf_rd_waddr;
  wire [31:0] rf_rd_wdata;

  rf #(
      .BYPASS_EN(BYPASS_EN)
  ) rf_instance (
      .i_clk      (i_clk),
      .i_rst      (i_rst),
      .i_rs1_raddr(id_rs1),
      .o_rs1_rdata(rf_rs1_data),
      .i_rs2_raddr(id_rs2),
      .o_rs2_rdata(rf_rs2_data),
      .i_rd_waddr (rf_rd_waddr),
      .i_rd_wdata (rf_rd_wdata)
  );

  // ID/EX
  reg         ex_valid;
  reg  [31:0] ex_pc;
  reg  [31:0] ex_inst;
  reg         ex_illegal;
  reg         ex_halt;
  reg  [ 4:0] ex_rs1;
  reg  [ 4:0] ex_rs2;
  reg  [31:0] ex_rs1_rf;
  reg  [31:0] ex_rs2_rf;
  reg  [ 4:0] ex_rd;
  reg  [31:0] ex_imm;
  reg         ex_op1_sel;
  reg         ex_op2_sel;
  reg  [ 2:0] ex_alu_opsel;
  reg         ex_alu_sub;
  reg         ex_alu_unsigned;
  reg         ex_alu_arith;
  reg         ex_branch;
  reg         ex_jump;
  reg         ex_branch_equal;
  reg         ex_branch_invert;
  reg         ex_pc_sel;
  reg         ex_is_load;
  reg         ex_dmem_ren;
  reg         ex_dmem_wen;
  reg  [ 1:0] ex_dmem_align;
  reg         ex_dmem_memb;
  reg         ex_dmem_memh;
  reg         ex_dmem_memw;
  reg         ex_dmem_memu;
  reg  [ 3:0] ex_rd_sel;

  always @(posedge i_clk) begin
    if (i_rst) begin
      ex_valid    <= 1'b0;
      ex_inst     <= NOP;
      ex_rd       <= 5'd0;
      ex_branch   <= 1'b0;
      ex_jump     <= 1'b0;
      ex_is_load  <= 1'b0;
      ex_dmem_ren <= 1'b0;
      ex_dmem_wen <= 1'b0;
    end else if (redirect || stall) begin
      ex_valid    <= 1'b0;
      ex_inst     <= NOP;
      ex_rd       <= 5'd0;
      ex_branch   <= 1'b0;
      ex_jump     <= 1'b0;
      ex_is_load  <= 1'b0;
      ex_dmem_ren <= 1'b0;
      ex_dmem_wen <= 1'b0;
    end else begin
      ex_valid         <= id_valid;
      ex_pc            <= id_pc;
      ex_inst          <= id_inst;
      ex_illegal       <= ~dec_legal;
      ex_halt          <= dec_halt;
      ex_rs1           <= id_rs1;
      ex_rs2           <= id_rs2;
      ex_rs1_rf        <= rf_rs1_data;
      ex_rs2_rf        <= rf_rs2_data;
      ex_rd            <= id_valid ? id_rd : 5'd0;
      ex_imm           <= dec_immediate;
      ex_op1_sel       <= dec_op1_sel;
      ex_op2_sel       <= dec_op2_sel;
      ex_alu_opsel     <= dec_alu_opsel;
      ex_alu_sub       <= dec_alu_sub;
      ex_alu_unsigned  <= dec_alu_unsigned;
      ex_alu_arith     <= dec_alu_arith;
      ex_branch        <= dec_branch;
      ex_jump          <= dec_jump;
      ex_branch_equal  <= dec_branch_equal;
      ex_branch_invert <= dec_branch_invert;
      ex_pc_sel        <= dec_pc_sel;
      ex_is_load       <= dec_is_load;
      ex_dmem_ren      <= dec_dmem_ren;
      ex_dmem_wen      <= dec_dmem_wen;
      ex_dmem_align    <= dec_dmem_align;
      ex_dmem_memb     <= dec_dmem_memb;
      ex_dmem_memh     <= dec_dmem_memh;
      ex_dmem_memw     <= dec_dmem_memw;
      ex_dmem_memu     <= dec_dmem_memu;
      ex_rd_sel        <= dec_rd_sel;
    end
  end

  // ---------------- EX ----------------
  // MEM/WB stage registers referenced by forwarding (declared here).
  reg         mem_valid;
  reg  [ 4:0] mem_rd;
  reg         mem_is_load;
  reg  [31:0] mem_result;
  reg         wb_valid;
  reg  [ 4:0] wb_rd;
  reg  [31:0] wb_rd_wdata;

  // Forwarding (FWD_EN): youngest producer wins, x0 is never forwarded.
  // A load in MEM can't be forwarded; the load-use stall keeps that from
  // being needed.
  wire fwd_mem_rs1 = FWD_EN && mem_valid && !mem_is_load && mem_rd != 5'd0 && mem_rd == ex_rs1;
  wire fwd_mem_rs2 = FWD_EN && mem_valid && !mem_is_load && mem_rd != 5'd0 && mem_rd == ex_rs2;
  wire fwd_wb_rs1 = FWD_EN && wb_valid && wb_rd != 5'd0 && wb_rd == ex_rs1;
  wire fwd_wb_rs2 = FWD_EN && wb_valid && wb_rd != 5'd0 && wb_rd == ex_rs2;

  wire [31:0] ex_rs1_data = fwd_mem_rs1 ? mem_result : fwd_wb_rs1 ? wb_rd_wdata : ex_rs1_rf;
  wire [31:0] ex_rs2_data = fwd_mem_rs2 ? mem_result : fwd_wb_rs2 ? wb_rd_wdata : ex_rs2_rf;

  wire [31:0] alu_op1 = ex_op1_sel ? ex_pc : ex_rs1_data;
  wire [31:0] alu_op2 = ex_op2_sel ? ex_imm : ex_rs2_data;
  wire [31:0] alu_result;
  wire        alu_eq;
  wire        alu_slt;

  alu alu_inst (
      .i_opsel   (ex_alu_opsel),
      .i_sub     (ex_alu_sub),
      .i_unsigned(ex_alu_unsigned),
      .i_arith   (ex_alu_arith),
      .i_op1     (alu_op1),
      .i_op2     (alu_op2),
      .o_result  (alu_result),
      .o_eq      (alu_eq),
      .o_slt     (alu_slt)
  );

  wire        branch_cond = ex_branch_equal ? alu_eq : alu_slt;
  wire        branch_taken = ex_branch & (branch_cond ^ ex_branch_invert);
  wire        ex_take = branch_taken | ex_jump;

  wire [31:0] ex_pc_plus_4 = ex_pc + 32'd4;
  wire [31:0] ex_target = ex_pc_sel ? {alu_result[31:1], 1'b0} : ex_pc + ex_imm;

  // Traps (phase_4.pdf 4.5.1): illegal encoding or misaligned load/store.
  // A trap never redirects; the instruction just loses its side effects.
  wire [ 1:0] byte_offset = alu_result[1:0];
  wire        data_misaligned = (ex_dmem_ren | ex_dmem_wen) & |(byte_offset & ex_dmem_align);
  wire        ex_trap = ex_illegal | data_misaligned;

  assign redirect = ex_valid & ex_take & ~ex_trap;
  assign redirect_pc = ex_target;
  wire [31:0] ex_next_pc = redirect ? ex_target : ex_pc_plus_4;

  // Non-load writeback value, known by the end of EX.
  wire [31:0] ex_result = ex_rd_sel[2] ? ex_pc_plus_4 : ex_rd_sel[1] ? ex_imm : alu_result;

  wire [ 3:0] byte_mask = (byte_offset == 2'd0) ? 4'b0001 :
                          (byte_offset == 2'd1) ? 4'b0010 :
                          (byte_offset == 2'd2) ? 4'b0100 :
                                                  4'b1000;
  wire [ 3:0] access_mask = ex_dmem_memw ? 4'b1111 :
                            ex_dmem_memh ? (byte_offset[1] ? 4'b1100 : 4'b0011) :
                            ex_dmem_memb ? byte_mask :
                                           4'b0000;
  wire [31:0] store_data = (byte_offset == 2'd0) ? ex_rs2_data :
                           (byte_offset == 2'd1) ? {ex_rs2_data[23:0], 8'b0} :
                           (byte_offset == 2'd2) ? {ex_rs2_data[15:0], 16'b0} :
                                                   {ex_rs2_data[7:0], 24'b0};

  // EX/MEM
  reg  [31:0] mem_pc;
  reg  [31:0] mem_next_pc;
  reg  [31:0] mem_inst;
  reg         mem_trap;
  reg         mem_halt;
  reg  [ 4:0] mem_rs1;
  reg  [ 4:0] mem_rs2;
  reg  [31:0] mem_rs1_data;
  reg  [31:0] mem_rs2_data;
  reg         mem_ren;
  reg         mem_wen;
  reg  [31:0] mem_addr;
  reg  [ 3:0] mem_mask;
  reg  [31:0] mem_wdata;
  reg  [ 1:0] mem_offset;
  reg         mem_memb;
  reg         mem_memh;
  reg         mem_memu;

  always @(posedge i_clk) begin
    if (i_rst) begin
      mem_valid <= 1'b0;
      mem_inst  <= NOP;
      mem_rd    <= 5'd0;
      mem_ren   <= 1'b0;
      mem_wen   <= 1'b0;
    end else if (!ex_valid) begin
      mem_valid <= 1'b0;
      mem_inst  <= NOP;
      mem_rd    <= 5'd0;
      mem_ren   <= 1'b0;
      mem_wen   <= 1'b0;
    end else begin
      mem_valid    <= 1'b1;
      mem_pc       <= ex_pc;
      mem_next_pc  <= ex_next_pc;
      mem_inst     <= ex_inst;
      mem_trap     <= ex_trap;
      mem_halt     <= ex_halt;
      mem_rs1      <= ex_rs1;
      mem_rs2      <= ex_rs2;
      mem_rs1_data <= ex_rs1_data;
      mem_rs2_data <= ex_rs2_data;
      mem_rd       <= ex_trap ? 5'd0 : ex_rd;
      mem_is_load  <= ex_is_load;
      mem_result   <= ex_result;
      mem_ren      <= ex_dmem_ren & ~ex_trap;
      mem_wen      <= ex_dmem_wen & ~ex_trap;
      mem_addr     <= {alu_result[31:2], 2'b00};
      mem_mask     <= (ex_dmem_ren | ex_dmem_wen) & ~ex_trap ? access_mask : 4'b0000;
      mem_wdata    <= store_data;
      mem_offset   <= byte_offset;
      mem_memb     <= ex_dmem_memb;
      mem_memh     <= ex_dmem_memh;
      mem_memu     <= ex_dmem_memu;
    end
  end

  // ---------------- MEM ----------------
  assign o_dmem_addr  = mem_addr;
  assign o_dmem_ren   = mem_valid & mem_ren;
  assign o_dmem_wen   = mem_valid & mem_wen;
  assign o_dmem_mask  = mem_valid ? mem_mask : 4'b0000;
  assign o_dmem_wdata = mem_wdata;

  wire [31:0] load_shifted = (mem_offset == 2'd0) ? i_dmem_rdata :
                             (mem_offset == 2'd1) ? {8'b0, i_dmem_rdata[31:8]} :
                             (mem_offset == 2'd2) ? {16'b0, i_dmem_rdata[31:16]} :
                                                    {24'b0, i_dmem_rdata[31:24]};
  wire [31:0] load_data =
      mem_memb ? {{24{~mem_memu & load_shifted[7]}},  load_shifted[7:0]} :
      mem_memh ? {{16{~mem_memu & load_shifted[15]}}, load_shifted[15:0]} :
                 i_dmem_rdata;
  wire [31:0] mem_rd_wdata = mem_is_load ? load_data : mem_result;

  // MEM/WB
  reg  [31:0] wb_pc;
  reg  [31:0] wb_next_pc;
  reg  [31:0] wb_inst;
  reg         wb_trap;
  reg         wb_halt;
  reg  [ 4:0] wb_rs1;
  reg  [ 4:0] wb_rs2;
  reg  [31:0] wb_rs1_data;
  reg  [31:0] wb_rs2_data;
  reg  [31:0] wb_dmem_addr;
  reg  [ 3:0] wb_dmem_mask;
  reg         wb_dmem_ren;
  reg         wb_dmem_wen;
  reg  [31:0] wb_dmem_rdata;
  reg  [31:0] wb_dmem_wdata;

  always @(posedge i_clk) begin
    if (i_rst) begin
      wb_valid <= 1'b0;
      wb_inst  <= NOP;
      wb_rd    <= 5'd0;
    end else if (!mem_valid) begin
      wb_valid <= 1'b0;
      wb_inst  <= NOP;
      wb_rd    <= 5'd0;
    end else begin
      wb_valid      <= 1'b1;
      wb_pc         <= mem_pc;
      wb_next_pc    <= mem_next_pc;
      wb_inst       <= mem_inst;
      wb_trap       <= mem_trap;
      wb_halt       <= mem_halt;
      wb_rs1        <= mem_rs1;
      wb_rs2        <= mem_rs2;
      wb_rs1_data   <= mem_rs1_data;
      wb_rs2_data   <= mem_rs2_data;
      wb_rd         <= mem_rd;
      wb_rd_wdata   <= mem_rd_wdata;
      wb_dmem_addr  <= mem_addr;
      wb_dmem_mask  <= mem_mask;
      wb_dmem_ren   <= mem_ren;
      wb_dmem_wen   <= mem_wen;
      wb_dmem_rdata <= i_dmem_rdata;
      wb_dmem_wdata <= mem_wdata;
    end
  end

  // ---------------- WB ----------------
  assign rf_rd_waddr = wb_valid ? wb_rd : 5'd0;
  assign rf_rd_wdata = wb_rd_wdata;

  // ---------------- Hazard detection (ID) ----------------
  // An older instruction in stage S writes a register the ID instruction reads.
  wire hz_ex = ex_valid && ex_rd != 5'd0 && (ex_rd == id_rs1 || ex_rd == id_rs2);
  wire hz_mem = mem_valid && mem_rd != 5'd0 && (mem_rd == id_rs1 || mem_rd == id_rs2);
  wire hz_wb = wb_valid && wb_rd != 5'd0 && (wb_rd == id_rs1 || wb_rd == id_rs2);

  // Without the rf bypass, the value being written back this cycle isn't
  // visible to ID yet, so wait one more cycle for it either way.
  wire wb_stall = !BYPASS_EN && hz_wb;
  wire raw_stall = FWD_EN ? (hz_ex && ex_is_load) || wb_stall : hz_ex || hz_mem || wb_stall;

  assign stall = id_valid && raw_stall;

  // Once an ebreak leaves ID, nothing behind it is fetched.
  always @(posedge i_clk) begin
    if (i_rst) begin
      halted <= 1'b0;
    end else if (id_halt && !stall && !redirect) begin
      halted <= 1'b1;
    end
  end

  // ---------------- Retire ----------------
  assign o_retire_valid      = wb_valid;
  assign o_retire_inst       = wb_inst;
  assign o_retire_trap       = wb_trap;
  assign o_retire_halt       = wb_halt;
  assign o_retire_rs1_raddr  = wb_rs1;
  assign o_retire_rs1_rdata  = wb_rs1_data;
  assign o_retire_rs2_raddr  = wb_rs2;
  assign o_retire_rs2_rdata  = wb_rs2_data;
  assign o_retire_rd_waddr   = wb_rd;
  assign o_retire_rd_wdata   = wb_rd_wdata;
  assign o_retire_dmem_addr  = wb_dmem_addr;
  assign o_retire_dmem_mask  = wb_dmem_mask;
  assign o_retire_dmem_ren   = wb_dmem_ren;
  assign o_retire_dmem_wen   = wb_dmem_wen;
  assign o_retire_dmem_rdata = wb_dmem_rdata;
  assign o_retire_dmem_wdata = wb_dmem_wdata;
  assign o_retire_pc         = wb_pc;
  assign o_retire_next_pc    = wb_next_pc;

endmodule

`default_nettype wire
