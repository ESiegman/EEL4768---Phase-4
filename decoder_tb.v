
/
Ran 2 commands, 1 failed
The file you attached matches the hart_hazard_fwd_tb.v I sent (the only difference is a missing newline at the end, which doesn’t matter). So the testbench is done. Here’s what to do next, in order.

1. Fix decoder.v and replace decoder_tb.v (if you haven’t yet)

These are the fixes from my last message: declare the three ports, add is_store to o_uses_rs1, and swap in my decoder_tb.v. Without them, the hazard testbench can’t compile, because Person 1’s hart.v connects to those decoder ports.

2. Run everything

sh
./run_test.sh local
cat results/local.txt
You should see:

PASS Verilog: decoder  --  68 passed, 0 failed
PASS Verilog: hart_hazard_no_fwd  --  2796 passed, 0 failed
PASS Verilog: hart_hazard_fwd  --  2797 passed, 0 failed
alu, imm and both rf should pass too. hart_no_hazard will say SKIP; that’s Person 2’s file.

3. Commit and push to your branch

sh
git add decoder.v decoder_tb.v hart_hazard_fwd_tb.v scripts/gen_hazard_fwd.py
git commit -m "Person 4: decoder hazard outputs, decoder_tb, hart_hazard_fwd_tb"
git push origin person-4
4. Get it into main

On GitHub, open a pull request from person-4 into main. Main currently can’t compile either hazard testbench because Person 1’s hart.v expects your decoder outputs, so tell your group this PR fixes that. If your group doesn’t use PRs:

sh
git checkout main
git pull origin main
git merge person-4 --no-edit
git push origin main
5. What’s still left for Person 4

The directed jal/jalr, branch-flush and trap tests from hart_hazard_fwd_directed.txt. They need the script’s model extended first (it doesn’t know jal, jalr, lb, lh, sh or traps). Then they go in as a Part C after Part B. Your current testbench is complete and passing without them, so push what you have now and add Part C afterward.

Quote
1. Fix decoder.v and replace decoder_tb.v (if you haven’t yet) These are the fixes from my last message: declare the three ports, add is_store to o_uses_rs1, and swap in my decoder_tb.v. Without them, the hazard testbench can’t compile, bec
show me what to fix!

Shared 2 files, ran a command
There are three things to fix: two small edits in decoder.v, plus replacing decoder_tb.v. I attached both files already fixed. Your decoder.v keeps your comments, so you can drop them in instead of editing by hand.

Fix 1: decoder.v, line 85 (the end of the port list)

You assign the three outputs at the bottom of the file, but they were never declared as ports. Change the last port and add three new lines below it:

verilog
// before
    output wire        o_pc_sel
);

// after
    output wire        o_pc_sel,          // <- add the comma
    output wire        o_uses_rs1,
    output wire        o_uses_rs2,
    output wire        o_is_load
);
Fix 2: decoder.v, line 175 (your o_uses_rs1 line)

Add is_store. A store reads rs1 as its base address (sw x9, 0(x29) reads x29), so without it every store writes to address 0.

verilog
// before
assign o_uses_rs1 = is_op|is_op_imm|is_load|is_branch|is_jalr;

// after
assign o_uses_rs1 = is_op|is_op_imm|is_load|is_store|is_branch|is_jalr;
Fix 3: replace decoder_tb.v

Overwrite your decoder_tb.v with the attached one. Your current copy never checks the three new outputs, which is how the missing is_store got through. The new one checks them on every instruction and adds 6 false-dependency and load-use tests.

Then check:

sh
./run_test.sh local
cat results/local.txt
I ran the attached files on your branch and got:

PASS Verilog: decoder  --  68 passed, 0 failed
PASS Verilog: hart_hazard_no_fwd  --  2796 passed, 0 failed
PASS Verilog: hart_hazard_fwd  --  2797 passed, 0 failed
If you see the same, commit and push (step 3 from my last message).


Decoder
V 

Decoder tb
V 
1791514350696_image.png
1791514397378_image.png
are tghese good fo rdecoder?

Yes, both are correct. Those are exactly the two decoder.v fixes.

Ports (lines 85–89): o_pc_sel now ends with a comma, the three new outputs are declared, and o_is_load is last with no comma before );. That fixes the compile error.
Assigns: o_uses_rs1 now includes is_store, so stores read their base register again. o_uses_rs2 and o_is_load were already right.
Optionally, fix two typos in your comment: “dependencyh” → “dependency” and “doesn’t exit” → “doesn’t exist”.

Two things are left before you commit:

Replace decoder_tb.v with the one I attached. Your current one doesn’t test these three outputs.
Run the tests and confirm decoder shows 68 passed, and both hazard testbenches pass:
sh
   ./run_test.sh local
   cat results/local.txt




Decoder tb · V
`timescale 1ns / 1ps
`default_nettype none
module decoder_tb;

  // Policy switch: the spec gives o_branch_equal / o_branch_unsigned /
  // o_branch_invert as bare funct3 formulas with no "only for branches"
  // qualifier, so by default this testbench expects them to follow funct3
  // on EVERY instruction.

  
  localparam BRANCH_FLAGS_GATED = 0;

  localparam [6:0] OPC_LUI    = 7'b0110111;
  localparam [6:0] OPC_AUIPC  = 7'b0010111;
  localparam [6:0] OPC_JAL    = 7'b1101111;
  localparam [6:0] OPC_JALR   = 7'b1100111;
  localparam [6:0] OPC_BRANCH = 7'b1100011;
  localparam [6:0] OPC_LOAD   = 7'b0000011;
  localparam [6:0] OPC_STORE  = 7'b0100011;
  localparam [6:0] OPC_OPIMM  = 7'b0010011;
  localparam [6:0] OPC_OP     = 7'b0110011;
  localparam [6:0] OPC_SYSTEM = 7'b1110011;

  localparam [6:0] F7_ZERO = 7'b0000000;
  localparam [6:0] F7_ALT  = 7'b0100000;

  // --------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------
  reg  [31:0] inst;

  wire        o_legal;
  wire        o_halt;
  wire [ 4:0] o_rs1;
  wire [ 4:0] o_rs2;
  wire [ 4:0] o_rd;
  wire [31:0] o_immediate;
  wire        o_op1_sel;
  wire        o_op2_sel;
  wire [ 2:0] o_alu_opsel;
  wire        o_alu_sub;
  wire        o_alu_unsigned;
  wire        o_alu_arith;
  wire        o_branch;
  wire        o_jump;
  wire        o_branch_equal;
  wire        o_branch_unsigned;
  wire        o_branch_invert;
  wire        o_dmem_ren;
  wire        o_dmem_wen;
  wire [ 1:0] o_dmem_align;
  wire        o_dmem_memb;
  wire        o_dmem_memh;
  wire        o_dmem_memw;
  wire        o_dmem_memu;
  wire [ 3:0] o_rd_sel;
  wire        o_pc_sel;
  wire        o_uses_rs1;
  wire        o_uses_rs2;
  wire        o_is_load;

  decoder dut (
      .i_inst           (inst),
      .o_legal          (o_legal),
      .o_halt           (o_halt),
      .o_rs1            (o_rs1),
      .o_rs2            (o_rs2),
      .o_rd             (o_rd),
      .o_immediate      (o_immediate),
      .o_op1_sel        (o_op1_sel),
      .o_op2_sel        (o_op2_sel),
      .o_alu_opsel      (o_alu_opsel),
      .o_alu_sub        (o_alu_sub),
      .o_alu_unsigned   (o_alu_unsigned),
      .o_alu_arith      (o_alu_arith),
      .o_branch         (o_branch),
      .o_jump           (o_jump),
      .o_branch_equal   (o_branch_equal),
      .o_branch_unsigned(o_branch_unsigned),
      .o_branch_invert  (o_branch_invert),
      .o_dmem_ren       (o_dmem_ren),
      .o_dmem_wen       (o_dmem_wen),
      .o_dmem_align     (o_dmem_align),
      .o_dmem_memb      (o_dmem_memb),
      .o_dmem_memh      (o_dmem_memh),
      .o_dmem_memw      (o_dmem_memw),
      .o_dmem_memu      (o_dmem_memu),
      .o_rd_sel         (o_rd_sel),
      .o_pc_sel         (o_pc_sel),
      .o_uses_rs1       (o_uses_rs1),
      .o_uses_rs2       (o_uses_rs2),
      .o_is_load        (o_is_load)
  );

  // --------------------------------------------------------------------
  // Expected values
  // --------------------------------------------------------------------
  reg        e_legal;
  reg        e_halt;
  reg [ 4:0] e_rs1;
  reg [ 4:0] e_rs2;
  reg [ 4:0] e_rd;
  reg [31:0] e_immediate;
  reg        e_imm_valid;  // 0 => immediate is a don't care for this word
  reg        e_op1_sel;
  reg        e_op2_sel;
  reg [ 2:0] e_alu_opsel;
  reg        e_alu_sub;
  reg        e_alu_unsigned;
  reg        e_alu_arith;
  reg        e_branch;
  reg        e_jump;
  reg        e_branch_equal;
  reg        e_branch_unsigned;
  reg        e_branch_invert;
  reg        e_dmem_ren;
  reg        e_dmem_wen;
  reg [ 1:0] e_dmem_align;
  reg        e_dmem_memb;
  reg        e_dmem_memh;
  reg        e_dmem_memw;
  reg        e_dmem_memu;
  reg [ 3:0] e_rd_sel;
  reg        e_pc_sel;
  reg        e_uses_rs1;
  reg        e_uses_rs2;
  reg        e_is_load;

  integer pass_count;
  integer fail_count;

  // --------------------------------------------------------------------
  // Instruction encoders (RV32I reference card layouts)
  // --------------------------------------------------------------------
  function [31:0] enc_r;
    input [6:0] f7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] f3;
    input [4:0] rd;
    input [6:0] op;
    begin
      enc_r = {f7, rs2, rs1, f3, rd, op};
    end
  endfunction

  function [31:0] enc_i;
    input [11:0] imm;
    input [ 4:0] rs1;
    input [ 2:0] f3;
    input [ 4:0] rd;
    input [ 6:0] op;
    begin
      enc_i = {imm, rs1, f3, rd, op};
    end
  endfunction

  function [31:0] enc_s;
    input [11:0] imm;
    input [ 4:0] rs2;
    input [ 4:0] rs1;
    input [ 2:0] f3;
    input [ 6:0] op;
    begin
      enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
    end
  endfunction

  function [31:0] enc_b;
    input [12:0] imm;  // imm[0] is always zero
    input [ 4:0] rs2;
    input [ 4:0] rs1;
    input [ 2:0] f3;
    input [ 6:0] op;
    begin
      enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
    end
  endfunction

  function [31:0] enc_u;
    input [31:0] imm;  // only imm[31:12] is encoded
    input [ 4:0] rd;
    input [ 6:0] op;
    begin
      enc_u = {imm[31:12], rd, op};
    end
  endfunction

  function [31:0] enc_j;
    input [20:0] imm;  // imm[0] is always zero
    input [ 4:0] rd;
    input [ 6:0] op;
    begin
      enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
    end
  endfunction

  // Sign / zero extension helpers for the expected immediate values
  function [31:0] sext12;
    input [11:0] v;
    begin
      sext12 = {{20{v[11]}}, v};
    end
  endfunction

  function [31:0] sext13;
    input [12:0] v;
    begin
      sext13 = {{19{v[12]}}, v};
    end
  endfunction

  function [31:0] sext21;
    input [20:0] v;
    begin
      sext21 = {{11{v[20]}}, v};
    end
  endfunction


  // Expectation defaults
  // Call AFTER setting `inst`. Establishes the baseline every instruction
  // shares -- illegal, no register write, no memory access -- so each test
  // only states what makes it different.
  //
  // o_rs1 and o_rs2 are unconditional field extractions per the spec, so
  // they always come straight from the instruction word.
  task expect_defaults;
    begin
      e_legal           = 1'b0;
      e_halt            = 1'b0;
      e_rs1             = inst[19:15];
      e_rs2             = inst[24:20];
      e_rd              = 5'd0;
      e_immediate       = 32'd0;
      e_imm_valid       = 1'b0;
      e_op1_sel         = 1'b0;
      e_op2_sel         = 1'b0;
      e_alu_opsel       = 3'b000;
      e_alu_sub         = 1'b0;
      e_alu_unsigned    = 1'b0;
      e_alu_arith       = 1'b0;
      e_branch          = 1'b0;
      e_jump            = 1'b0;
      e_dmem_ren        = 1'b0;
      e_dmem_wen        = 1'b0;
      e_dmem_align      = 2'b00;
      e_dmem_memb       = 1'b0;
      e_dmem_memh       = 1'b0;
      e_dmem_memw       = 1'b0;
      e_dmem_memu       = 1'b0;
      e_rd_sel          = 4'b0000;
      e_pc_sel          = 1'b0;
      e_uses_rs1        = 1'b0;
      e_uses_rs2        = 1'b0;
      e_is_load         = 1'b0;

      if (BRANCH_FLAGS_GATED) begin
        e_branch_equal    = 1'b0;
        e_branch_unsigned = 1'b0;
        e_branch_invert   = 1'b0;
      end else begin
        e_branch_equal    = ~inst[14];
        e_branch_unsigned = inst[13];
        e_branch_invert   = inst[12];
      end
    end
  endtask

  // Checker -- compares every output, every time
  task check;
    input [8*48-1:0] name;
    reg bad;
    begin
      #1;
      bad = 1'b0;

      if (o_legal           !== e_legal)           bad = 1'b1;
      if (o_halt            !== e_halt)            bad = 1'b1;
      if (o_rs1             !== e_rs1)             bad = 1'b1;
      if (o_rs2             !== e_rs2)             bad = 1'b1;
      if (o_rd              !== e_rd)              bad = 1'b1;
      if (e_imm_valid && (o_immediate !== e_immediate)) bad = 1'b1;
      if (o_op1_sel         !== e_op1_sel)         bad = 1'b1;
      if (o_op2_sel         !== e_op2_sel)         bad = 1'b1;
      if (o_alu_opsel       !== e_alu_opsel)       bad = 1'b1;
      if (o_alu_sub         !== e_alu_sub)         bad = 1'b1;
      if (o_alu_unsigned    !== e_alu_unsigned)    bad = 1'b1;
      if (o_alu_arith       !== e_alu_arith)       bad = 1'b1;
      if (o_branch          !== e_branch)          bad = 1'b1;
      if (o_jump            !== e_jump)            bad = 1'b1;
      if (o_branch_equal    !== e_branch_equal)    bad = 1'b1;
      if (o_branch_unsigned !== e_branch_unsigned) bad = 1'b1;
      if (o_branch_invert   !== e_branch_invert)   bad = 1'b1;
      if (o_dmem_ren        !== e_dmem_ren)        bad = 1'b1;
      if (o_dmem_wen        !== e_dmem_wen)        bad = 1'b1;
      if (o_dmem_align      !== e_dmem_align)      bad = 1'b1;
      if (o_dmem_memb       !== e_dmem_memb)       bad = 1'b1;
      if (o_dmem_memh       !== e_dmem_memh)       bad = 1'b1;
      if (o_dmem_memw       !== e_dmem_memw)       bad = 1'b1;
      if (o_dmem_memu       !== e_dmem_memu)       bad = 1'b1;
      if (o_rd_sel          !== e_rd_sel)          bad = 1'b1;
      if (o_pc_sel          !== e_pc_sel)          bad = 1'b1;
      if (o_uses_rs1        !== e_uses_rs1)        bad = 1'b1;
      if (o_uses_rs2        !== e_uses_rs2)        bad = 1'b1;
      if (o_is_load         !== e_is_load)         bad = 1'b1;

      if (!bad) begin
        pass_count = pass_count + 1;
        $display("[PASS] %0s", name);
      end else begin
        fail_count = fail_count + 1;
        $display("[FAIL] %0s   (inst = 32'h%08h)", name, inst);
        if (o_legal        !== e_legal)        $display("         legal:          exp=%b got=%b", e_legal, o_legal);
        if (o_halt         !== e_halt)         $display("         halt:           exp=%b got=%b", e_halt, o_halt);
        if (o_rs1          !== e_rs1)          $display("         rs1:            exp=%0d got=%0d", e_rs1, o_rs1);
        if (o_rs2          !== e_rs2)          $display("         rs2:            exp=%0d got=%0d", e_rs2, o_rs2);
        if (o_rd           !== e_rd)           $display("         rd:             exp=%0d got=%0d", e_rd, o_rd);
        if (e_imm_valid && (o_immediate !== e_immediate))
                                               $display("         immediate:      exp=32'h%08h got=32'h%08h", e_immediate, o_immediate);
        if (o_op1_sel      !== e_op1_sel)      $display("         op1_sel:        exp=%b got=%b", e_op1_sel, o_op1_sel);
        if (o_op2_sel      !== e_op2_sel)      $display("         op2_sel:        exp=%b got=%b", e_op2_sel, o_op2_sel);
        if (o_alu_opsel    !== e_alu_opsel)    $display("         alu_opsel:      exp=%b got=%b", e_alu_opsel, o_alu_opsel);
        if (o_alu_sub      !== e_alu_sub)      $display("         alu_sub:        exp=%b got=%b", e_alu_sub, o_alu_sub);
        if (o_alu_unsigned !== e_alu_unsigned) $display("         alu_unsigned:   exp=%b got=%b", e_alu_unsigned, o_alu_unsigned);
        if (o_alu_arith    !== e_alu_arith)    $display("         alu_arith:      exp=%b got=%b", e_alu_arith, o_alu_arith);
        if (o_branch       !== e_branch)       $display("         branch:         exp=%b got=%b", e_branch, o_branch);
        if (o_jump         !== e_jump)         $display("         jump:           exp=%b got=%b", e_jump, o_jump);
        if (o_branch_equal !== e_branch_equal) $display("         branch_equal:   exp=%b got=%b", e_branch_equal, o_branch_equal);
        if (o_branch_unsigned !== e_branch_unsigned) $display("         branch_unsigned:exp=%b got=%b", e_branch_unsigned, o_branch_unsigned);
        if (o_branch_invert !== e_branch_invert) $display("         branch_invert:  exp=%b got=%b", e_branch_invert, o_branch_invert);
        if (o_dmem_ren     !== e_dmem_ren)     $display("         dmem_ren:       exp=%b got=%b", e_dmem_ren, o_dmem_ren);
        if (o_dmem_wen     !== e_dmem_wen)     $display("         dmem_wen:       exp=%b got=%b", e_dmem_wen, o_dmem_wen);
        if (o_dmem_align   !== e_dmem_align)   $display("         dmem_align:     exp=%b got=%b", e_dmem_align, o_dmem_align);
        if (o_dmem_memb    !== e_dmem_memb)    $display("         dmem_memb:      exp=%b got=%b", e_dmem_memb, o_dmem_memb);
        if (o_dmem_memh    !== e_dmem_memh)    $display("         dmem_memh:      exp=%b got=%b", e_dmem_memh, o_dmem_memh);
        if (o_dmem_memw    !== e_dmem_memw)    $display("         dmem_memw:      exp=%b got=%b", e_dmem_memw, o_dmem_memw);
        if (o_dmem_memu    !== e_dmem_memu)    $display("         dmem_memu:      exp=%b got=%b", e_dmem_memu, o_dmem_memu);
        if (o_rd_sel       !== e_rd_sel)       $display("         rd_sel:         exp=%b got=%b", e_rd_sel, o_rd_sel);
        if (o_pc_sel       !== e_pc_sel)       $display("         pc_sel:         exp=%b got=%b", e_pc_sel, o_pc_sel);
        if (o_uses_rs1     !== e_uses_rs1)     $display("         uses_rs1:       exp=%b got=%b", e_uses_rs1, o_uses_rs1);
        if (o_uses_rs2     !== e_uses_rs2)     $display("         uses_rs2:       exp=%b got=%b", e_uses_rs2, o_uses_rs2);
        if (o_is_load      !== e_is_load)      $display("         is_load:        exp=%b got=%b", e_is_load, o_is_load);
      end
    end
  endtask

  // Which source registers the instruction really reads. Class-based, per
  // traces/README.md: rs1 for op, op-imm, load, store, branch and jalr; rs2
  // for op, store and branch. Everything else leaves both at the default 0.
  task expect_reads;
    input r1;
    input r2;
    begin
      e_uses_rs1 = r1;
      e_uses_rs2 = r2;
    end
  endtask

  // Shorthand for a legal register-writing instruction
  task expect_writes_rd;
    input [4:0] rd;
    input [3:0] sel;
    begin
      e_legal  = 1'b1;
      e_rd     = rd;
      e_rd_sel = sel;
    end
  endtask


  // Tests
  initial begin
    pass_count = 0;
    fail_count = 0;

    $display("========== decoder testbench ==========");

    $display("--- op (R-type) ---");
    // rd_sel = ALU result, op2_sel = 0 (rs2), alu_opsel = funct3

    inst = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_alu_opsel = 3'b000;
    expect_reads(1'b1, 1'b1);
    check("add x1, x2, x3");

    inst = enc_r(F7_ALT, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_alu_opsel = 3'b000;
    e_alu_sub   = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sub x1, x2, x3");

    inst = enc_r(F7_ZERO, 5'd7, 5'd6, 3'b001, 5'd5, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_alu_opsel = 3'b001;
    expect_reads(1'b1, 1'b1);
    check("sll x5, x6, x7");

    inst = enc_r(F7_ZERO, 5'd7, 5'd6, 3'b010, 5'd5, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_alu_opsel = 3'b010;
    expect_reads(1'b1, 1'b1);
    check("slt x5, x6, x7");

    inst = enc_r(F7_ZERO, 5'd7, 5'd6, 3'b011, 5'd5, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_alu_opsel    = 3'b011;
    e_alu_unsigned = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sltu x5, x6, x7");

    inst = enc_r(F7_ZERO, 5'd10, 5'd9, 3'b100, 5'd8, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_alu_opsel = 3'b100;
    expect_reads(1'b1, 1'b1);
    check("xor x8, x9, x10");

    inst = enc_r(F7_ZERO, 5'd10, 5'd9, 3'b101, 5'd8, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_alu_opsel = 3'b101;
    expect_reads(1'b1, 1'b1);
    check("srl x8, x9, x10");

    inst = enc_r(F7_ALT, 5'd10, 5'd9, 3'b101, 5'd8, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_alu_opsel = 3'b101;
    e_alu_arith = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sra x8, x9, x10");

    inst = enc_r(F7_ZERO, 5'd31, 5'd30, 3'b110, 5'd29, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd29, 4'b0001);
    e_alu_opsel = 3'b110;
    expect_reads(1'b1, 1'b1);
    check("or x29, x30, x31");

    inst = enc_r(F7_ZERO, 5'd31, 5'd30, 3'b111, 5'd29, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd29, 4'b0001);
    e_alu_opsel = 3'b111;
    expect_reads(1'b1, 1'b1);
    check("and x29, x30, x31");

    // rd = x0 is a legal encoding; the write is discarded by the rf, not here
    inst = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd0, OPC_OP);
    expect_defaults;
    expect_writes_rd(5'd0, 4'b0001);
    expect_reads(1'b1, 1'b1);
    check("add x0, x2, x3 (rd = x0 still legal)");

    // ================================================================
    $display("--- op-imm (I-type) ---");
    // op2_sel = 1 (immediate), rd_sel = ALU result
    // ================================================================

    inst = enc_i(12'h123, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b000;
    e_immediate = sext12(12'h123);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, 0x123");

    inst = enc_i(12'hFFF, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_immediate = sext12(12'hFFF);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, -1 (negative sign extend)");

    inst = enc_i(12'h800, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_immediate = sext12(12'h800);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, -2048 (most negative)");

    inst = enc_i(12'h7FF, 5'd2, 3'b000, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_immediate = sext12(12'h7FF);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("addi x1, x2, 2047 (most positive)");

    inst = enc_i(12'h0AA, 5'd6, 3'b010, 5'd5, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b010;
    e_immediate = sext12(12'h0AA);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("slti x5, x6, 0xAA");

    inst = enc_i(12'h0AA, 5'd6, 3'b011, 5'd5, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd5, 4'b0001);
    e_op2_sel      = 1'b1;
    e_alu_opsel    = 3'b011;
    e_alu_unsigned = 1'b1;
    e_immediate    = sext12(12'h0AA);
    e_imm_valid    = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("sltiu x5, x6, 0xAA");

    inst = enc_i(12'h0F0, 5'd9, 3'b100, 5'd8, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b100;
    e_immediate = sext12(12'h0F0);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("xori x8, x9, 0xF0");

    inst = enc_i(12'h0F0, 5'd9, 3'b110, 5'd8, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b110;
    e_immediate = sext12(12'h0F0);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("ori x8, x9, 0xF0");

    inst = enc_i(12'h0F0, 5'd9, 3'b111, 5'd8, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd8, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b111;
    e_immediate = sext12(12'h0F0);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("andi x8, x9, 0xF0");

    // Shift-immediates: funct7 occupies imm[11:5], shamt is imm[4:0]
    inst = enc_i({F7_ZERO, 5'd13}, 5'd2, 3'b001, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b001;
    e_immediate = sext12({F7_ZERO, 5'd13});
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("slli x1, x2, 13");

    inst = enc_i({F7_ZERO, 5'd13}, 5'd2, 3'b101, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b101;
    e_immediate = sext12({F7_ZERO, 5'd13});
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("srli x1, x2, 13");

    inst = enc_i({F7_ALT, 5'd13}, 5'd2, 3'b101, 5'd1, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);
    e_op2_sel   = 1'b1;
    e_alu_opsel = 3'b101;
    e_alu_arith = 1'b1;
    e_immediate = sext12({F7_ALT, 5'd13});
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("srai x1, x2, 13");

    // ================================================================
    $display("--- load (I-type) ---");
    // op2_sel = 1, alu_opsel = add (address calc), rd_sel = memory
    // ================================================================

    inst = enc_i(12'h010, 5'd2, 3'b000, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memb  = 1'b1;
    e_dmem_align = 2'b00;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_is_load = 1'b1;
    check("lb x1, 16(x2)");

    inst = enc_i(12'h010, 5'd2, 3'b001, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memh  = 1'b1;
    e_dmem_align = 2'b01;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_is_load = 1'b1;
    check("lh x1, 16(x2)");

    inst = enc_i(12'hFF0, 5'd2, 3'b010, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = sext12(12'hFF0);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_is_load = 1'b1;
    check("lw x1, -16(x2)");

    inst = enc_i(12'h010, 5'd2, 3'b100, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memb  = 1'b1;
    e_dmem_memu  = 1'b1;
    e_dmem_align = 2'b00;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_is_load = 1'b1;
    check("lbu x1, 16(x2)");

    inst = enc_i(12'h010, 5'd2, 3'b101, 5'd1, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b1000);
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memh  = 1'b1;
    e_dmem_memu  = 1'b1;
    e_dmem_align = 2'b01;
    e_immediate  = sext12(12'h010);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b0);
    e_is_load = 1'b1;
    check("lhu x1, 16(x2)");

    // ================================================================
    $display("--- store (S-type) ---");
    // rd MUST be 5'd0 even though inst[11:7] carries immediate bits
    // ================================================================

    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b000, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memb  = 1'b1;
    e_dmem_align = 2'b00;
    e_immediate  = sext12(12'h004);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sb x5, 4(x1)  [rd field nonzero -> rd must be 0]");

    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b001, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memh  = 1'b1;
    e_dmem_align = 2'b01;
    e_immediate  = sext12(12'h004);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sh x5, 4(x1)");

    inst = enc_s(12'hFFC, 5'd5, 5'd1, 3'b010, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = sext12(12'hFFC);
    e_imm_valid  = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("sw x5, -4(x1)  [negative S-type immediate]");

    $display("--- branch (B-type) ---");
    // rd MUST be 0; op2_sel = 0; pc_sel = 0 (target base is PC)

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b000, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b1;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b0;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("beq x1, x2, +16");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b001, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b1;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b1;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bne x1, x2, +16");

    inst = enc_b(13'h1FF0, 5'd2, 5'd1, 3'b100, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b0;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h1FF0);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("blt x1, x2, -16  [negative B-type immediate]");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b101, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b0;
    e_branch_invert   = 1'b1;
    e_alu_unsigned    = 1'b0;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bge x1, x2, +16");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b110, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b1;
    e_branch_invert   = 1'b0;
    e_alu_unsigned    = 1'b1;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bltu x1, x2, +16");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b111, OPC_BRANCH);
    expect_defaults;
    e_legal           = 1'b1;
    e_branch          = 1'b1;
    e_branch_equal    = 1'b0;
    e_branch_unsigned = 1'b1;
    e_branch_invert   = 1'b1;
    e_alu_unsigned    = 1'b1;
    e_immediate       = sext13(13'h010);
    e_imm_valid       = 1'b1;
    expect_reads(1'b1, 1'b1);
    check("bgeu x1, x2, +16");


    $display("--- lui / auipc (U-type) ---");


    inst = enc_u(32'hDEADB000, 5'd1, OPC_LUI);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0010);  // writeback source = immediate
    e_immediate = 32'hDEADB000;
    e_imm_valid = 1'b1;
    check("lui x1, 0xDEADB");

    inst = enc_u(32'h00001000, 5'd1, OPC_AUIPC);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0001);  // writeback source = ALU result
    e_op1_sel   = 1'b1;               // only auipc selects the PC
    e_op2_sel   = 1'b1;
    e_immediate = 32'h00001000;
    e_imm_valid = 1'b1;
    check("auipc x1, 0x1");

    // ================================================================
    $display("--- jal / jalr ---");
    // rd_sel = PC + 4 for both; pc_sel distinguishes them
    // ================================================================

    inst = enc_j(21'h00100, 5'd1, OPC_JAL);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_pc_sel    = 1'b0;               // target base = PC
    e_immediate = sext21(21'h00100);
    e_imm_valid = 1'b1;
    check("jal x1, +256");

    inst = enc_j(21'h1FFF00, 5'd1, OPC_JAL);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_immediate = sext21(21'h1FFF00);
    e_imm_valid = 1'b1;
    check("jal x1, -256  [negative J-type immediate]");

    inst = enc_i(12'h008, 5'd2, 3'b000, 5'd1, OPC_JALR);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_op2_sel   = 1'b1;
    e_pc_sel    = 1'b1;               // target base = rs1
    e_immediate = sext12(12'h008);
    e_imm_valid = 1'b1;
    expect_reads(1'b1, 1'b0);
    check("jalr x1, 8(x2)");

    // ================================================================
    $display("--- ebreak ---");
    // ================================================================

    inst = 32'h00100073;
    expect_defaults;
    e_legal = 1'b1;
    e_halt  = 1'b1;
    check("ebreak (legal, halts)");

    // ================================================================
    $display("--- hazard outputs: false dependencies and load-use ---");
    // o_rs1/o_rs2 are raw fields, so they can name a real register even when
    // the instruction never reads it. These cases pin uses_rs1/uses_rs2 low
    // exactly where a naive hazard unit would see a match.
    // ================================================================

    // phase_4.pdf 4.2.3: addi x3, x0, 1 puts imm[4:0] = 1 in the rs2 field,
    // so after add x1, x0, x2 a hazard unit comparing o_rs2 sees "x1"
    inst = enc_i(12'd1, 5'd0, 3'b000, 5'd3, OPC_OPIMM);
    expect_defaults;
    expect_writes_rd(5'd3, 4'b0001);
    expect_reads(1'b1, 1'b0);
    e_op2_sel   = 1'b1;
    e_immediate = 32'd1;
    e_imm_valid = 1'b1;
    check("addi x3, x0, 1: rs2 field = x1 but unused");

    // same trap on rs1: lui's immediate fills inst[19:15] (here x31) and
    // inst[24:20] (x31) and it reads neither
    inst = enc_u(32'hFFFFF000, 5'd7, OPC_LUI);
    expect_defaults;
    expect_writes_rd(5'd7, 4'b0010);
    e_immediate = 32'hFFFFF000;
    e_imm_valid = 1'b1;
    check("lui x7, 0xFFFFF: rs1/rs2 fields = x31, unused");

    // jal's offset bits also land in both fields
    inst = enc_j(21'h0FFFFE, 5'd1, OPC_JAL);
    expect_defaults;
    expect_writes_rd(5'd1, 4'b0100);
    e_jump      = 1'b1;
    e_immediate = sext21(21'h0FFFFE);
    e_imm_valid = 1'b1;
    check("jal x1, max offset: rs1/rs2 fields set, unused");

    // the load-use producer from phase_4.pdf 4.2.1: is_load high, and the
    // rs2 field (imm[4:0] = 4 -> x4) is not a read
    inst = enc_i(12'd4, 5'd11, 3'b010, 5'd12, OPC_LOAD);
    expect_defaults;
    expect_writes_rd(5'd12, 4'b1000);
    expect_reads(1'b1, 1'b0);
    e_is_load    = 1'b1;
    e_op2_sel    = 1'b1;
    e_dmem_ren   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = 32'd4;
    e_imm_valid  = 1'b1;
    check("lw x12, 4(x11): is_load, rs2 field unused");

    // the load-store consumer: a store reads rs2 (the data) and is not a load
    inst = enc_s(12'd8, 5'd12, 5'd10, 3'b010, OPC_STORE);
    expect_defaults;
    e_legal      = 1'b1;
    expect_reads(1'b1, 1'b1);
    e_op2_sel    = 1'b1;
    e_dmem_wen   = 1'b1;
    e_dmem_memw  = 1'b1;
    e_dmem_align = 2'b11;
    e_immediate  = 32'd8;
    e_imm_valid  = 1'b1;
    check("sw x12, 8(x10): reads rs1 and rs2, not a load");

    // an illegal load funct3 must not look like a load to the hazard unit
    inst = enc_i(12'd4, 5'd11, 3'b011, 5'd12, OPC_LOAD);
    expect_defaults;
    check("load funct3=011: not is_load, reads nothing");

    // ================================================================
    $display("--- illegal encodings ---");
    // All must give legal=0, halt=0, rd=0, and no memory/branch/jump
    // ================================================================

    // ecall is explicitly NOT legal in this decoder
    inst = 32'h00000073;
    expect_defaults;
    check("ecall (illegal here, halt must stay low)");

    // A SYSTEM word that is neither ecall nor ebreak
    inst = 32'h30200073;
    expect_defaults;
    check("mret (illegal)");

    // Undefined opcodes
    inst = 32'hFFFFFFFF;
    expect_defaults;
    check("all-ones word (illegal)");

    inst = 32'h00000000;
    expect_defaults;
    check("all-zeros word (illegal)");

    inst = enc_r(F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd1, 7'b0001011);
    expect_defaults;
    check("custom-0 opcode (illegal)");

    // op with a bad funct7 -- rd field is nonzero, so this proves the
    // illegal path forces rd to 0 rather than passing inst[11:7] through
    inst = enc_r(7'b0100001, 5'd3, 5'd2, 3'b000, 5'd1, OPC_OP);
    expect_defaults;
    check("add with funct7=0100001 (illegal, rd must be 0)");

    inst = enc_r(F7_ALT, 5'd3, 5'd2, 3'b001, 5'd1, OPC_OP);
    expect_defaults;
    check("sll with funct7=0100000 (illegal)");

    inst = enc_r(F7_ALT, 5'd3, 5'd2, 3'b111, 5'd1, OPC_OP);
    expect_defaults;
    check("and with funct7=0100000 (illegal)");

    // op-imm shift with a bad funct7
    inst = enc_i({F7_ALT, 5'd4}, 5'd2, 3'b001, 5'd1, OPC_OPIMM);
    expect_defaults;
    check("slli with funct7=0100000 (illegal)");

    inst = enc_i({7'b0100001, 5'd4}, 5'd2, 3'b101, 5'd1, OPC_OPIMM);
    expect_defaults;
    check("srli with funct7=0100001 (illegal)");

    // Undefined load widths -- confirms the memory-size bits stay low
    inst = enc_i(12'h010, 5'd2, 3'b011, 5'd1, OPC_LOAD);
    expect_defaults;
    check("load funct3=011 (illegal, no dmem_mem* set)");

    inst = enc_i(12'h010, 5'd2, 3'b110, 5'd1, OPC_LOAD);
    expect_defaults;
    check("load funct3=110 (illegal)");

    inst = enc_i(12'h010, 5'd2, 3'b111, 5'd1, OPC_LOAD);
    expect_defaults;
    check("load funct3=111 (illegal)");

    // Undefined store widths
    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b011, OPC_STORE);
    expect_defaults;
    check("store funct3=011 (illegal)");

    inst = enc_s(12'h004, 5'd5, 5'd1, 3'b111, OPC_STORE);
    expect_defaults;
    check("store funct3=111 (illegal)");

    // Reserved branch funct3 values -- nonzero rd field again
    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b010, OPC_BRANCH);
    expect_defaults;
    check("branch funct3=010 (illegal, branch must stay low)");

    inst = enc_b(13'h010, 5'd2, 5'd1, 3'b011, OPC_BRANCH);
    expect_defaults;
    check("branch funct3=011 (illegal)");

    // jalr is only defined for funct3 = 000
    inst = enc_i(12'h008, 5'd2, 3'b001, 5'd1, OPC_JALR);
    expect_defaults;
    check("jalr funct3=001 (illegal, jump must stay low)");

    inst = enc_i(12'h008, 5'd2, 3'b111, 5'd1, OPC_JALR);
    expect_defaults;
    check("jalr funct3=111 (illegal)");

    // ================================================================
    $display("=======================================");
    $display("%0d passed, %0d failed", pass_count, fail_count);
    if (fail_count == 0) $display("ALL TESTS PASSED");
    else                 $display("THERE WERE FAILURES");
    $finish;
  end

endmodule

`default_nettype wire
 
Claude finished the response
