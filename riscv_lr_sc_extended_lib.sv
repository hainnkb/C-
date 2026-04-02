/*
 * Extended LR/SC instruction stream library for riscv-dv
 *
 * Cách tích hợp:
 *   1. Copy file này vào riscv-dv/src/
 *   2. Thêm `include "riscv_lr_sc_extended_lib.sv" vào riscv_instr_pkg.sv
 *      (ngay sau dòng `include "riscv_amo_instr_lib.sv")
 *   3. Thêm các test entry vào target testlist.yaml
 *
 * === CƠ CHẾ LABEL TRONG RISCV-DV ===
 *
 * riscv_instr_sequence::generate_instr_stream() xử lý label:
 *   - Check instr.has_label → format "{label}:" thành prefix
 *   - Nhưng label CHỈ là numeric string (ví dụ "5" → "5:")
 *   - Branch imm_str được gán "%0df" hoặc "%0db" (forward/backward)
 *   - Cơ chế này CHỈ dùng cho random branch trong cùng sequence
 *
 * Với directed stream có CAS retry loop cần named label + backward
 * branch, ta KHÔNG THỂ dùng instruction object cho phần này.
 *
 * GIẢI PHÁP: Override post_randomize() để build assembly string
 * trực tiếp, push vào instr_list thông qua pseudo instruction có
 * convert2asm() trả về raw string. HOẶC đơn giản hơn: dùng
 * riscv_pseudo_instr / riscv_instr_stream cơ chế comment để
 * inject raw assembly.
 *
 * Cách tiếp cận được dùng ở đây:
 *   - Gen LR, ALU, SC instructions bình thường (dùng object)
 *   - Sau khi gen xong, override convert2string() của stream để
 *     emit assembly có label + branch đúng cách
 *   - Quan trọng nhất: dùng field `comment` hoặc wrap trong
 *     custom class
 *
 * === THỰC TẾ ĐƠN GIẢN NHẤT ===
 * Push thẳng raw assembly string vào instr_string_list, KHÔNG
 * dùng instruction object cho LR/SC/BNE trong CAS loop.
 */

// =============================================================================
// STREAM 1: LR/SC CAS Loop (retry pattern)
//
// Cách hoạt động: KHÔNG dùng gen_amo_instr() cho LR/SC/BNE.
// Thay vào đó, override post_randomize() để build raw assembly:
//
//   la         rs1, amo_region+offset
//   lr_sc_cas_XXXX:
//     lr.w     rd_lr, (rs1)
//     addi     rd_new, rd_lr, 1
//     sc.w     rd_sc, rd_new, (rs1)
//     bnez     rd_sc, lr_sc_cas_XXXX
//
// Toàn bộ sequence là raw string → không bị framework xáo trộn.
// =============================================================================
class riscv_lr_sc_cas_loop_stream extends riscv_mem_access_stream;

  rand riscv_reg_t addr_reg;
  rand riscv_reg_t rd_lr;
  rand riscv_reg_t rd_new;
  rand riscv_reg_t rd_sc;
  rand int unsigned num_alu_between;
  rand int unsigned data_page_id;
  int unsigned max_data_page_id;
  rand int offset;
  int unsigned max_offset;

  constraint reg_c {
    unique {addr_reg, rd_lr, rd_new, rd_sc};
    !(addr_reg inside {cfg.reserved_regs, ZERO});
    !(rd_lr    inside {cfg.reserved_regs, ZERO});
    !(rd_new   inside {cfg.reserved_regs, ZERO});
    !(rd_sc    inside {cfg.reserved_regs, ZERO});
    addr_reg != rd_lr;
    addr_reg != rd_new;
    addr_reg != rd_sc;
    rd_lr    != rd_sc;
    rd_new   != rd_sc;
  }

  constraint alu_c {
    num_alu_between inside {[1:4]};
  }

  constraint addr_c {
    offset inside {[0 : max_offset - 1]};
    if (XLEN == 32) { offset % 4 == 0; }
    else            { offset % 8 == 0; }
  }

  `uvm_object_utils(riscv_lr_sc_cas_loop_stream)

  function new(string name = "");
    super.new(name);
  endfunction

  function void pre_randomize();
    data_page = cfg.amo_region;
    max_data_page_id = data_page.size();
    data_page_id = $urandom_range(0, max_data_page_id - 1);
    max_offset = data_page[data_page_id].size_in_bytes;
  endfunction

  function void post_randomize();
    string loop_label;
    string lr_mnemonic, sc_mnemonic;
    string asm_lines[$];
    riscv_reg_t last_rd;

    loop_label = $sformatf("lr_sc_cas_%0d", $urandom_range(0, 99999));

    if (RV64A inside {supported_isa}) begin
      lr_mnemonic = "lr.d";
      sc_mnemonic = "sc.d";
    end else begin
      lr_mnemonic = "lr.w";
      sc_mnemonic = "sc.w";
    end

    // --- la addr_reg, amo_region+offset ---
    asm_lines.push_back($sformatf("la %0s, %0s+%0d",
      addr_reg.name(), cfg.amo_region[data_page_id].name, offset));

    // --- label: lr rd_lr, (addr_reg) ---
    asm_lines.push_back($sformatf("%0s: %0s %0s, (%0s)",
      loop_label, lr_mnemonic, rd_lr.name(), addr_reg.name()));

    // --- ALU instructions (base I-set only, per spec §13.3) ---
    last_rd = rd_lr;
    for (int i = 0; i < num_alu_between; i++) begin
      riscv_reg_t dest;
      // Tùy vào iteration, dùng rd_new hoặc tạo chain
      dest = (i == num_alu_between - 1) ? rd_new : rd_lr;
      asm_lines.push_back($sformatf("addi %0s, %0s, %0d",
        dest.name(), last_rd.name(), i + 1));
      last_rd = dest;
    end

    // --- sc rd_sc, rd_new, (addr_reg) ---
    asm_lines.push_back($sformatf("%0s %0s, %0s, (%0s)",
      sc_mnemonic, rd_sc.name(), rd_new.name(), addr_reg.name()));

    // --- bnez rd_sc, loop_label (backward branch tới LR) ---
    asm_lines.push_back($sformatf("bnez %0s, %0s",
      rd_sc.name(), loop_label));

    // Push raw asm vào instr_string_list (KHÔNG dùng instr_list)
    foreach (asm_lines[i]) begin
      instr_string_list.push_back(asm_lines[i]);
    end

    // Không gọi super.post_randomize() vì không dùng instr_list
  endfunction

endclass : riscv_lr_sc_cas_loop_stream


// =============================================================================
// STREAM 2: LR/SC with ordering bit variants (aq, rl, aqrl)
//
// Dùng $cast(riscv_amo_instr) để truy cập aq/rl
// Dùng constraint_mode(0) trên aq_rl_c để cho phép aqrl
// =============================================================================
class riscv_lr_sc_ordering_stream extends riscv_amo_base_instr_stream;

  rand bit lr_aq;
  rand bit lr_rl;
  rand bit sc_aq;
  rand bit sc_rl;

  // Spec §13.2:
  //   "Software should not set rl on LR unless aq is also set"
  //   "nor should software set aq on SC unless rl is also set"
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

    // === LR ===
    lr_handle = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    if (!$cast(lr_amo, lr_handle))
      `uvm_fatal(`gfn, "Failed to cast LR to riscv_amo_instr")

    if (lr_aq && lr_rl)
      lr_amo.aq_rl_c.constraint_mode(0);

    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_amo,
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg[0], ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
      aq == lr_aq;
      rl == lr_rl;
    )

    // === SC ===
    sc_handle = riscv_instr::get_rand_instr(.include_instr({sc_type}));
    if (!$cast(sc_amo, sc_handle))
      `uvm_fatal(`gfn, "Failed to cast SC to riscv_amo_instr")

    if (sc_aq && sc_rl)
      sc_amo.aq_rl_c.constraint_mode(0);

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
      rs1 == rs1_reg[0];
      !(rd inside {rs1_reg, ZERO});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

    lr_2 = riscv_instr::get_rand_instr(.include_instr({lr_type}));
    `DV_CHECK_RANDOMIZE_WITH_FATAL(lr_2,
      rs1 == rs1_reg[1];
      !(rd inside {rs1_reg, ZERO, lr_1.rd});
      if (reserved_rd.size() > 0) { !(rd inside {reserved_rd}); }
      if (cfg.reserved_regs.size() > 0) { !(rd inside {cfg.reserved_regs}); }
    )

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
