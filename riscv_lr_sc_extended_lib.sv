/*
 * Copyright 2024
 *
 * Extended LR/SC instruction stream library for riscv-dv
 *
 * Cách tích hợp:
 *   1. Copy file này vào riscv-dv/src/
 *   2. Thêm `include "riscv_lr_sc_extended_lib.sv" vào riscv_instr_pkg.sv
 *      (ngay sau dòng `include "riscv_amo_instr_lib.sv")
 *   3. Thêm các test entry vào target testlist.yaml
 *
 * LƯU Ý QUAN TRỌNG VỀ CLASS HIERARCHY:
 *
 *   riscv_instr              <- base class, KHÔNG có member aq/rl
 *     └── riscv_amo_instr    <- sub-class, CÓ: rand bit aq; rand bit rl;
 *                               constraint aq_rl_c { (aq && rl) == 0; }
 *
 *   - get_rand_instr() trả về handle kiểu riscv_instr (base)
 *   - LR/SC thực tế là riscv_amo_instr object
 *   - Phải dùng $cast() để truy cập aq/rl
 *   - Constraint mặc định: (aq && rl) == 0 => không cho phép aqrl
 *     Muốn gen aqrl phải gọi: handle.aq_rl_c.constraint_mode(0)
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
    riscv_instr        lr_handle, sc_handle, bne_instr;
    riscv_instr_name_t lr_type, sc_type;
    riscv_reg_t        last_rd;
    string             loop_label;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    loop_label = $sformatf("cas_retry_%0d", $urandom_range(0, 99999));

    // --- LR instruction ---
    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_handle,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    lr_handle.label = loop_label;
    lr_handle.has_label = 1'b1;
    instr_list.push_back(lr_handle);
    last_rd = lr_handle.rd;

    // --- ALU instructions between LR and SC (constrained I-set only) ---
    for (int i = 0; i < num_alu_between; i++) begin
      riscv_instr alu;
      alu = riscv_instr::get_rand_instr(
        .include_instr({ADDI, ADD, XORI, ORI, ANDI, SLLI, SRLI})
      );
      `DV_CHECK_RANDOMIZE_WITH_FATAL(alu,
        rs1 == last_rd;
        !(rd inside {rs1_reg[0], ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      last_rd = alu.rd;
      instr_list.push_back(alu);
    end

    // --- SC instruction ---
    sc_handle = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_handle,
      rs1 == rs1_reg[0];
      rs2 == last_rd;
      !(rd inside {rs1_reg[0], last_rd, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    instr_list.push_back(sc_handle);

    // --- BNE retry branch ---
    bne_instr = riscv_instr::get_rand_instr(.include_instr({BNE}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(bne_instr,
      rs1 == sc_handle.rd;
      rs2 == ZERO;
    )
    bne_instr.imm_str = loop_label;
    instr_list.push_back(bne_instr);
  endfunction

  // CAS loop tự quản lý instruction sequence, không cần mixed
  virtual function void add_mixed_instr(int instr_cnt);
  endfunction

endclass : riscv_lr_sc_cas_loop_stream


// =============================================================================
// STREAM 2: LR/SC with ordering bit variants (aq, rl, aqrl)
//
// Dùng $cast(riscv_amo_instr, handle) để truy cập aq/rl
// Dùng constraint_mode(0) trên aq_rl_c để cho phép aqrl
// =============================================================================
class riscv_lr_sc_ordering_stream extends riscv_amo_base_instr_stream;

  rand bit lr_aq;
  rand bit lr_rl;
  rand bit sc_aq;
  rand bit sc_rl;

  // Spec §13.2:
  //   "Software should not set the rl bit on an LR instruction unless
  //    the aq bit is also set"
  //   "nor should software set the aq bit on an SC instruction unless
  //    the rl bit is also set"
  constraint ordering_c {
    lr_rl -> lr_aq;    // lr có rl => phải có aq  (cho phép: 00, 10, 11)
    sc_aq -> sc_rl;    // sc có aq => phải có rl  (cho phép: 00, 01, 11)
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
    riscv_instr       lr_handle, sc_handle;
    riscv_amo_instr   lr_amo, sc_amo;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    // === LR instruction ===
    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));

    // CRITICAL: $cast từ base riscv_instr sang riscv_amo_instr
    if (!$cast(lr_amo, lr_handle)) begin
      `uvm_fatal(`gfn, "Failed to cast LR instruction to riscv_amo_instr")
    end

    // Nếu cần aqrl (aq=1 VÀ rl=1), phải tắt constraint mặc định
    // riscv_amo_instr::aq_rl_c constraint { (aq && rl) == 0 }
    if (lr_aq && lr_rl) begin
      lr_amo.aq_rl_c.constraint_mode(0);
    end

    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_amo,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      aq == lr_aq;
      rl == lr_rl;
    )

    // === SC instruction ===
    sc_handle = riscv_instr::get_rand_instr(.include_instr({sc_type}));

    if (!$cast(sc_amo, sc_handle)) begin
      `uvm_fatal(`gfn, "Failed to cast SC instruction to riscv_amo_instr")
    end

    if (sc_aq && sc_rl) begin
      sc_amo.aq_rl_c.constraint_mode(0);
    end

    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_amo,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_amo.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      aq == sc_aq;
      rl == sc_rl;
    )

    instr_list.push_back(lr_amo);
    instr_list.push_back(sc_amo);
  endfunction

  // Constrained I-only instructions between LR/SC (per spec §13.3)
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
// Spec §13.2: "An SC must fail if there is another SC (to any address)
//              between the LR and itself in program order."
// Generates: LR(addr) -> SC(addr) [may succeed] -> SC(addr) [MUST fail]
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
    riscv_instr        lr_handle, sc_handle_1, sc_handle_2;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    // LR
    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_handle,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // SC #1 — consumes & invalidates reservation
    sc_handle_1 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_handle_1,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_handle.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // SC #2 — MUST FAIL
    sc_handle_2 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_handle_2,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_handle.rd, sc_handle_1.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    instr_list.push_back(lr_handle);
    instr_list.push_back(sc_handle_1);
    instr_list.push_back(sc_handle_2);
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
// Spec §13.2: "a hart can only hold one reservation at a time"
// Generates: LR(addr_0) -> LR(addr_1) -> SC(addr_0) [MUST fail]
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
    riscv_instr        lr_1, lr_2, sc_1;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    // LR #1 on addr_0 — sets reservation
    lr_1 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_1,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // LR #2 on addr_1 — overwrites reservation
    lr_2 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_2,
      rs1 == rs1_reg[1];
      !(rd inside {rs1_reg, ZERO, lr_1.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    // SC on addr_0 — MUST FAIL (reservation now on addr_1)
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
