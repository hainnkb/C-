/*
 * Copyright 2024
 *
 * Extended LR/SC instruction stream library for riscv-dv
 * 
 * Thêm vào riscv-dv bằng cách:
 *   1. Copy file này vào riscv-dv/src/
 *   2. Thêm `include "riscv_lr_sc_extended_lib.sv" vào riscv_instr_pkg.sv
 *      (ngay sau dòng `include "riscv_amo_instr_lib.sv")
 *   3. Thêm các test entry vào target testlist.yaml
 *
 * Các stream classes:
 *   - riscv_lr_sc_cas_loop_stream       : CAS retry loop pattern
 *   - riscv_lr_sc_ordering_stream       : aq/rl ordering variants
 *   - riscv_sc_fail_no_reservation_stream: SC failure (double SC)
 *   - riscv_lr_sc_stress_stream         : Multiple LR/SC pairs
 *   - riscv_lr_sc_mixed_width_stream    : W + D width mixing (RV64)
 *   - riscv_lr_sc_double_lr_stream      : Double LR invalidation
 */

// =============================================================================
// STREAM 1: LR/SC CAS Loop (retry pattern)
// Generates: label: LR -> ALU(1-4) -> SC -> BNEZ label
// =============================================================================
class riscv_lr_sc_cas_loop_stream extends riscv_amo_base_instr_stream;

  rand int unsigned num_alu_between;

  constraint legal_c {
    num_amo == 1;
    num_mixed_instr == 0;
    num_alu_between inside {[1:4]};
  }

  `uvm_object_utils(riscv_lr_sc_cas_loop_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  virtual function void gen_amo_instr();
    riscv_instr lr_instr, sc_instr, bne_instr;
    riscv_instr alu_instrs[$];
    riscv_instr_name_t lr_type, sc_type;
    riscv_reg_t last_alu_rd;
    string loop_label;

    // Select LR/SC variant
    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    loop_label = $sformatf("cas_retry_%0d", $urandom_range(0, 99999));

    // --- LR instruction ---
    lr_instr = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_instr,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    lr_instr.label = loop_label;
    lr_instr.has_label = 1'b1;
    instr_list.push_back(lr_instr);

    // --- ALU instructions between LR and SC ---
    last_alu_rd = lr_instr.rd;
    for (int i = 0; i < num_alu_between; i++) begin
      riscv_instr alu;
      alu = riscv_instr::get_rand_instr(
        .include_instr({ADDI, ADD, XORI, ORI, ANDI, SLLI, SRLI})
      );
      `DV_CHECK_RANDOMIZE_WITH_FATAL(alu,
        rs1 == last_alu_rd;
        !(rd inside {rs1_reg[0], ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      last_alu_rd = alu.rd;
      instr_list.push_back(alu);
    end

    // --- SC instruction ---
    sc_instr = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_instr,
      rs1 == rs1_reg[0];
      rs2 == last_alu_rd;
      !(rd inside {rs1_reg[0], last_alu_rd, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    instr_list.push_back(sc_instr);

    // --- BNE retry branch ---
    bne_instr = riscv_instr::get_rand_instr(.include_instr({BNE}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(bne_instr,
      rs1 == sc_instr.rd;
      rs2 == ZERO;
    )
    bne_instr.imm_str = loop_label;
    instr_list.push_back(bne_instr);
  endfunction

  // Override: no additional mixed instructions for CAS loop
  virtual function void add_mixed_instr(int instr_cnt);
    // Intentionally empty — CAS loop manages its own instruction sequence
  endfunction

endclass : riscv_lr_sc_cas_loop_stream


// =============================================================================
// STREAM 2: LR/SC with ordering bit variants (aq, rl, aqrl)
// =============================================================================
class riscv_lr_sc_ordering_stream extends riscv_amo_base_instr_stream;

  rand bit lr_aq;
  rand bit lr_rl;
  rand bit sc_aq;
  rand bit sc_rl;

  // Spec: don't set rl on LR without aq; don't set aq on SC without rl
  constraint ordering_c {
    lr_rl -> lr_aq;
    sc_aq -> sc_rl;
  }

  constraint legal_c {
    num_amo == 1;
    num_mixed_instr inside {[0:8]};
  }

  `uvm_object_utils(riscv_lr_sc_ordering_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  virtual function void gen_amo_instr();
    riscv_instr lr_instr, sc_instr;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    lr_instr = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    sc_instr = riscv_instr::get_rand_instr(.include_instr({sc_type}));

    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_instr,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_instr,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_instr.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // Apply ordering bits
    lr_instr.aq = lr_aq;
    lr_instr.rl = lr_rl;
    sc_instr.aq = sc_aq;
    sc_instr.rl = sc_rl;

    instr_list.push_back(lr_instr);
    instr_list.push_back(sc_instr);
  endfunction

  // Constrained I-only instructions between LR/SC
  virtual function void add_mixed_instr(int instr_cnt);
    riscv_instr instr;
    int i;
    setup_allowed_instr(.no_branch(1), .no_load_store(1));
    while (i < instr_cnt) begin
      instr = riscv_instr::type_id::create("instr");
      randomize_instr(instr, .include_group({RV32I, RV32C}));
      if (!(instr.category inside {SYNCH, SYSTEM})) begin
        insert_instr(instr);
        i++;
      end
    end
  endfunction

endclass : riscv_lr_sc_ordering_stream


// =============================================================================
// STREAM 3: SC failure — double SC (second SC must fail per spec)
// Generates: LR(addr) -> SC(addr) [success] -> SC(addr) [must fail]
// =============================================================================
class riscv_sc_fail_no_reservation_stream extends riscv_amo_base_instr_stream;

  constraint legal_c {
    num_amo == 1;
    num_mixed_instr == 0;
  }

  `uvm_object_utils(riscv_sc_fail_no_reservation_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  virtual function void gen_amo_instr();
    riscv_instr lr_instr, sc_instr_1, sc_instr_2;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    lr_instr = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_instr,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    sc_instr_1 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_instr_1,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_instr.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // Second SC — must fail (reservation invalidated by first SC)
    sc_instr_2 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_instr_2,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_instr.rd, sc_instr_1.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    instr_list.push_back(lr_instr);
    instr_list.push_back(sc_instr_1);
    instr_list.push_back(sc_instr_2);
  endfunction

endclass : riscv_sc_fail_no_reservation_stream


// =============================================================================
// STREAM 4: Multiple LR/SC pairs stress test
// =============================================================================
class riscv_lr_sc_stress_stream extends riscv_amo_base_instr_stream;

  rand int unsigned num_pairs;

  constraint pairs_c {
    num_pairs inside {[2:5]};
    num_amo == num_pairs;
  }

  constraint legal_c {
    num_mixed_instr inside {[0:3]};
  }

  constraint num_of_rs1_reg_c {
    solve num_pairs before num_of_rs1_reg;
    num_of_rs1_reg inside {[1:3]};
    num_of_rs1_reg <= num_pairs;
  }

  `uvm_object_utils(riscv_lr_sc_stress_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  virtual function void gen_amo_instr();
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    for (int i = 0; i < num_pairs; i++) begin
      riscv_instr lr_i, sc_i;
      int rs1_idx = i % num_of_rs1_reg;

      lr_i = riscv_instr::get_rand_instr(.include_instr({lr_type}));
      sc_i = riscv_instr::get_rand_instr(.include_instr({sc_type}));

      `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_i,
        rs1 == rs1_reg[rs1_idx];
        !(rd inside {rs1_reg, ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )

      `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_i,
        rs1 == rs1_reg[rs1_idx];
        !(rd inside {rs1_reg, ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )

      instr_list.push_back(lr_i);
      instr_list.push_back(sc_i);
    end
  endfunction

  virtual function void add_mixed_instr(int instr_cnt);
    riscv_instr instr;
    int i;
    setup_allowed_instr(.no_branch(1), .no_load_store(1));
    while (i < instr_cnt) begin
      instr = riscv_instr::type_id::create("instr");
      randomize_instr(instr, .include_group({RV32I, RV32C}));
      if (!(instr.category inside {SYNCH, SYSTEM})) begin
        insert_instr(instr);
        i++;
      end
    end
  endfunction

endclass : riscv_lr_sc_stress_stream


// =============================================================================
// STREAM 5: Mixed width LR/SC (W + D on RV64)
// =============================================================================
class riscv_lr_sc_mixed_width_stream extends riscv_amo_base_instr_stream;

  constraint legal_c {
    num_amo == 2;
    num_mixed_instr inside {[0:4]};
  }

  constraint num_of_rs1_reg_c {
    num_of_rs1_reg == 2;
  }

  `uvm_object_utils(riscv_lr_sc_mixed_width_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  virtual function void gen_amo_instr();
    riscv_instr lr_w, sc_w, lr_d, sc_d;

    // Pair 1: LR.W / SC.W
    if (RV32A inside {supported_isa} || RV64A inside {supported_isa}) begin
      lr_w = riscv_instr::get_rand_instr(.include_instr({LR_W}));
      sc_w = riscv_instr::get_rand_instr(.include_instr({SC_W}));

      `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_w,
        rs1 == rs1_reg[0];
        !(rd inside {rs1_reg, ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_w,
        rs1 == rs1_reg[0];
        !(rd inside {rs1_reg, ZERO, lr_w.rd});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      instr_list.push_back(lr_w);
      instr_list.push_back(sc_w);
    end

    // Pair 2: LR.D / SC.D (RV64 only)
    if (RV64A inside {supported_isa}) begin
      lr_d = riscv_instr::get_rand_instr(.include_instr({LR_D}));
      sc_d = riscv_instr::get_rand_instr(.include_instr({SC_D}));

      `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_d,
        rs1 == rs1_reg[1];
        !(rd inside {rs1_reg, ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_d,
        rs1 == rs1_reg[1];
        !(rd inside {rs1_reg, ZERO, lr_d.rd});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      instr_list.push_back(lr_d);
      instr_list.push_back(sc_d);
    end
  endfunction

  virtual function void add_mixed_instr(int instr_cnt);
    riscv_instr instr;
    int i;
    setup_allowed_instr(.no_branch(1), .no_load_store(1));
    while (i < instr_cnt) begin
      instr = riscv_instr::type_id::create("instr");
      randomize_instr(instr, .include_group({RV32I, RV32C}));
      if (!(instr.category inside {SYNCH, SYSTEM})) begin
        insert_instr(instr);
        i++;
      end
    end
  endfunction

endclass : riscv_lr_sc_mixed_width_stream


// =============================================================================
// STREAM 6: Double LR — second LR invalidates first reservation
// Generates: LR(addr_0) -> LR(addr_1) -> SC(addr_0) [must fail]
// =============================================================================
class riscv_lr_sc_double_lr_stream extends riscv_amo_base_instr_stream;

  constraint legal_c {
    num_amo == 1;
    num_mixed_instr == 0;
  }

  constraint num_of_rs1_reg_c {
    num_of_rs1_reg == 2;
  }

  `uvm_object_utils(riscv_lr_sc_double_lr_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  virtual function void gen_amo_instr();
    riscv_instr lr_1, lr_2, sc_1;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    // LR #1 on addr_0
    lr_1 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_1,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // LR #2 on addr_1 — invalidates reservation on addr_0
    lr_2 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_2,
      rs1 == rs1_reg[1];
      !(rd inside {rs1_reg, ZERO, lr_1.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // SC on addr_0 — MUST FAIL (reservation moved to addr_1)
    sc_1 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_1,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg, ZERO, lr_1.rd, lr_2.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    instr_list.push_back(lr_1);
    instr_list.push_back(lr_2);
    instr_list.push_back(sc_1);
  endfunction

endclass : riscv_lr_sc_double_lr_stream
