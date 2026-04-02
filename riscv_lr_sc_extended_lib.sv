/*
 * Extended LR/SC instruction stream library for riscv-dv
 *
 * Tích hợp:
 *   1. Copy file này vào riscv-dv/src/
 *   2. Thêm `include "riscv_lr_sc_extended_lib.sv" vào riscv_instr_pkg.sv
 *      (ngay sau `include "riscv_amo_instr_lib.sv")
 *   3. Thêm test entry vào target testlist.yaml
 *
 * === CƠ CHẾ LABEL/BRANCH TRONG RISCV-DV ===
 *
 * generate_instr_stream() trong riscv_instr_sequence.sv:
 *   if (instr.has_label)
 *     prefix = format_string($sformatf("%0s:", instr.label), ...);
 *   str = {prefix, instr.convert2asm()};
 *
 * => has_label + label hoạt động với BẤT KỲ string nào.
 *    Branch imm_str cũng được emit trực tiếp qua convert2asm().
 *
 * NHƯNG: directed stream bị mix_instr_stream() chèn vào main stream
 * ở random positions. Nếu sequence bị tách rời => label và branch
 * không còn liền nhau.
 *
 * GIẢI PHÁP: Đánh dấu atomic=1 cho mọi instruction trong CAS loop
 * => mix_instr_stream() sẽ KHÔNG chèn instruction vào giữa.
 *
 * Cho phần branch, riscv_instr::convert2asm() với B_FORMAT emit:
 *   $sformatf("%0s%0s, %0s, %0s", asm_str, rs1.name(), rs2.name(), get_imm())
 * trong đó get_imm() trả về imm_str nếu imm_str != "".
 * => Gán imm_str = label_name sẽ emit "bne rd, x0, label_name".
 *
 * Cho label trên LR: riscv_amo_instr::convert2asm() KHÔNG gọi super
 * nên label/has_label phải được xử lý bởi generate_instr_stream()
 * ở level trên => OK, vì generate_instr_stream() check has_label
 * TRƯỚC khi gọi convert2asm().
 */

// =============================================================================
// STREAM 1: LR/SC CAS Loop
//
// Output:
//   la       rs1, amo_region+offset
//   lr_sc_cas_XXXX:
//     lr.w   rd_lr, (rs1)
//     addi   rd_new, rd_lr, 1    # (1-4 ALU instrs)
//     sc.w   rd_sc, rd_new, (rs1)
//     bne    rd_sc, x0, lr_sc_cas_XXXX
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
    riscv_instr        lr_handle, sc_handle, bne_handle;
    riscv_instr_name_t lr_type, sc_type;
    riscv_reg_t        last_rd;
    string             loop_label;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    loop_label = $sformatf("lr_sc_cas_%0d", $urandom_range(0, 99999));

    // ──── LR ────
    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_handle,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    // Đánh label lên LR — generate_instr_stream() sẽ emit "lr_sc_cas_XXXX:"
    lr_handle.label     = loop_label;
    lr_handle.has_label = 1'b1;
    lr_handle.atomic    = 1'b1;
    instr_list.push_back(lr_handle);
    last_rd = lr_handle.rd;

    // ──── ALU (base I-set only, spec §13.3) ────
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
      alu.atomic = 1'b1;
      instr_list.push_back(alu);
    end

    // ──── SC ────
    sc_handle = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_handle,
      rs1 == rs1_reg[0];
      rs2 == last_rd;
      !(rd inside {rs1_reg[0], last_rd, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    sc_handle.atomic = 1'b1;
    instr_list.push_back(sc_handle);

    // ──── BNE backward → LR ────
    // convert2asm() cho B_FORMAT emit: "bne rs1, rs2, <imm_str>"
    // Gán imm_str = loop_label => "bne rd_sc, x0, lr_sc_cas_XXXX"
    bne_handle = riscv_instr::get_rand_instr(.include_instr({BNE}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(bne_handle,
      rs1 == sc_handle.rd;
      rs2 == ZERO;
    )
    bne_handle.imm_str = loop_label;
    bne_handle.atomic  = 1'b1;
    instr_list.push_back(bne_handle);
  endfunction

  // Không thêm mixed instructions — CAS loop phải là tight sequence
  virtual function void add_mixed_instr(int instr_cnt);
  endfunction

endclass : riscv_lr_sc_cas_loop_stream


// =============================================================================
// STREAM 2: LR/SC ordering bit variants (aq, rl, aqrl)
// =============================================================================
class riscv_lr_sc_ordering_stream extends riscv_amo_base_instr_stream;

  rand bit lr_aq;
  rand bit lr_rl;
  rand bit sc_aq;
  rand bit sc_rl;

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
    riscv_instr       lr_handle, sc_handle;
    riscv_amo_instr   lr_amo, sc_amo;
    riscv_instr_name_t lr_type, sc_type;

    if (RV64A inside {supported_isa}) begin
      lr_type = LR_D;  sc_type = SC_D;
    end else begin
      lr_type = LR_W;  sc_type = SC_W;
    end

    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    if (!$cast(lr_amo, lr_handle))
      `uvm_fatal(`gfn, "Failed to cast LR to riscv_amo_instr")
    if (lr_aq && lr_rl) lr_amo.aq_rl_c.constraint_mode(0);
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_amo,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      aq == lr_aq; rl == lr_rl;
    )

    sc_handle = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    if (!$cast(sc_amo, sc_handle))
      `uvm_fatal(`gfn, "Failed to cast SC to riscv_amo_instr")
    if (sc_aq && sc_rl) sc_amo.aq_rl_c.constraint_mode(0);
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_amo,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_amo.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      aq == sc_aq; rl == sc_rl;
    )

    instr_list.push_back(lr_amo);
    instr_list.push_back(sc_amo);
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

endclass : riscv_lr_sc_ordering_stream


// =============================================================================
// STREAM 3: SC failure — double SC
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

    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_handle,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    sc_handle_1 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_handle_1,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO, lr_handle.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

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
// STREAM 4: Multiple LR/SC pairs stress
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
// STREAM 5: Mixed width W + D (RV64)
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
    if (RV32A inside {supported_isa} || RV64A inside {supported_isa}) begin
      lr_w = riscv_instr::get_rand_instr(.include_instr({LR_W}));
      sc_w = riscv_instr::get_rand_instr(.include_instr({SC_W}));
      `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_w,
        rs1 == rs1_reg[0]; !(rd inside {rs1_reg, ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_w,
        rs1 == rs1_reg[0]; !(rd inside {rs1_reg, ZERO, lr_w.rd});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      instr_list.push_back(lr_w);
      instr_list.push_back(sc_w);
    end
    if (RV64A inside {supported_isa}) begin
      lr_d = riscv_instr::get_rand_instr(.include_instr({LR_D}));
      sc_d = riscv_instr::get_rand_instr(.include_instr({SC_D}));
      `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_d,
        rs1 == rs1_reg[1]; !(rd inside {rs1_reg, ZERO});
        if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
        if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      )
      `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_d,
        rs1 == rs1_reg[1]; !(rd inside {rs1_reg, ZERO, lr_d.rd});
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
// STREAM 6: Double LR invalidation
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
    lr_1 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_1,
      rs1 == rs1_reg[0]; !(rd inside {rs1_reg, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    lr_2 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_2,
      rs1 == rs1_reg[1]; !(rd inside {rs1_reg, ZERO, lr_1.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    sc_1 = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(sc_1,
      rs1 == rs1_reg[0]; !(rd inside {rs1_reg, ZERO, lr_1.rd, lr_2.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )
    instr_list.push_back(lr_1);
    instr_list.push_back(lr_2);
    instr_list.push_back(sc_1);
  endfunction

endclass : riscv_lr_sc_double_lr_stream
