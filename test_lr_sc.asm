# =============================================================================
# RISC-V A Extension - LR/SC (Load-Reserved / Store-Conditional) Test Suite
# =============================================================================
# Target: RV32I + A extension (Zalrsc)
# Assembler: GNU as (riscv32-unknown-elf-as hoặc riscv64-unknown-elf-as)
#
# Quy ước test:
#   - Mỗi test case có nhãn test_N
#   - Kết quả PASS: ghi 1 vào a0 rồi nhảy tới pass_N
#   - Kết quả FAIL: ghi 0 vào a0 rồi nhảy tới fail_N
#   - Cuối chương trình: a0 = tổng số test PASS
#   - Dùng ecall (a7=93, a0=exit_code) để kết thúc (Linux convention)
#
# Biên dịch (ví dụ):
#   riscv32-unknown-elf-gcc -march=rv32ia -mabi=ilp32 -nostdlib \
#       -Ttext=0x80000000 -o test_lr_sc test_lr_sc.S
#
# Chạy trên simulator (ví dụ Spike):
#   spike --isa=rv32ia pk test_lr_sc
# =============================================================================

    .section .data
    .balign 4
shared_var:     .word 0         # Biến dùng chung cho các test LR/SC
scratch_var:    .word 0         # Biến scratch (dùng để invalidate reservation)
result_var:     .word 0         # Biến lưu kết quả phụ

    .section .text
    .globl _start
    .balign 4

_start:
    li      s0, 0               # s0 = bộ đếm test PASS
    li      s1, 0               # s1 = bộ đếm tổng số test

# =============================================================================
# TEST 1: LR.W cơ bản - đọc giá trị từ bộ nhớ
# Mong đợi: rd nhận được giá trị tại địa chỉ [rs1]
# =============================================================================
test_1:
    addi    s1, s1, 1           # tăng tổng số test

    la      t0, shared_var
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)           # shared_var = 0xDEADBEEF

    lr.w    t2, (t0)            # t2 = LR.W(shared_var)

    bne     t2, t1, fail_1      # Nếu t2 != 0xDEADBEEF => FAIL
    addi    s0, s0, 1           # PASS
    j       test_2
fail_1:
    nop

# =============================================================================
# TEST 2: LR.W + SC.W thành công (không bị gián đoạn)
# Mong đợi: SC.W trả về 0 (thành công), giá trị mới được ghi vào bộ nhớ
# =============================================================================
test_2:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 42
    sw      t1, 0(t0)           # shared_var = 42

    lr.w    t2, (t0)            # t2 = 42, đặt reservation
    addi    t3, t2, 1           # t3 = 43 (giá trị mới)
    sc.w    t4, t3, (t0)        # Cố gắng ghi 43 vào shared_var

    bnez    t4, fail_2          # t4 != 0 => SC thất bại => FAIL
    lw      t5, 0(t0)
    li      t6, 43
    bne     t5, t6, fail_2      # Kiểm tra bộ nhớ thực sự = 43
    addi    s0, s0, 1           # PASS
    j       test_3
fail_2:
    nop

# =============================================================================
# TEST 3: SC.W thất bại khi không có LR.W trước đó
# (Trên hầu hết implementation, SC.W sẽ fail nếu không có reservation hợp lệ)
# Mong đợi: SC.W trả về giá trị khác 0 (thất bại)
# =============================================================================
test_3:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 100
    sw      t1, 0(t0)           # shared_var = 100

    # Invalidate reservation bằng SC.W tới scratch
    la      t5, scratch_var
    lr.w    t6, (t5)
    sc.w    t6, t6, (t5)        # Hoàn tất SC => reservation bị xóa

    # Giờ thử SC.W tới shared_var mà không có LR.W
    li      t2, 200
    sc.w    t3, t2, (t0)        # Không có reservation => phải FAIL

    beqz    t3, fail_3          # t3 == 0 => SC thành công bất ngờ => FAIL
    lw      t4, 0(t0)
    li      t6, 100
    bne     t4, t6, fail_3      # Bộ nhớ phải giữ nguyên = 100
    addi    s0, s0, 1           # PASS
    j       test_4
fail_3:
    nop

# =============================================================================
# TEST 4: SC.W thất bại khi có SW (store thường) xen giữa LR và SC
# Theo spec: SC phải fail nếu có store tới reservation set giữa LR và SC
# (Trên single-hart, điều này không bắt buộc, nhưng nhiều impl vẫn fail)
# Mong đợi: SC.W có thể fail (test kiểm tra cả hai trường hợp)
# =============================================================================
test_4:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 0xAAAA
    sw      t1, 0(t0)           # shared_var = 0xAAAA

    lr.w    t2, (t0)            # t2 = 0xAAAA, đặt reservation
    li      t3, 0xBBBB
    sw      t3, 0(t0)           # Store thường xen vào => có thể phá reservation
    li      t4, 0xCCCC
    sc.w    t5, t4, (t0)        # SC.W sau khi bị gián đoạn

    # Trên nhiều implementation, SC sẽ fail (t5 != 0)
    # Nhưng spec không bắt buộc fail trên single-hart store
    # => Test này chỉ kiểm tra tính nhất quán:
    #    Nếu SC thành công (t5==0): bộ nhớ phải = 0xCCCC
    #    Nếu SC thất bại (t5!=0): bộ nhớ phải = 0xBBBB (từ SW)

    lw      t6, 0(t0)
    beqz    t5, sc4_success
    # SC failed => bộ nhớ phải là 0xBBBB
    li      a1, 0xBBBB
    bne     t6, a1, fail_4
    j       pass_4
sc4_success:
    # SC succeeded => bộ nhớ phải là 0xCCCC
    li      a1, 0xCCCC
    bne     t6, a1, fail_4
pass_4:
    addi    s0, s0, 1           # PASS
    j       test_5
fail_4:
    nop

# =============================================================================
# TEST 5: SC.W thất bại khi SC tới địa chỉ khác với LR
# Mong đợi: SC.W trả về khác 0 (thất bại)
# =============================================================================
test_5:
    addi    s1, s1, 1

    la      t0, shared_var
    la      t1, scratch_var
    li      t2, 50
    sw      t2, 0(t0)           # shared_var = 50
    li      t3, 60
    sw      t3, 0(t1)           # scratch_var = 60

    lr.w    t4, (t0)            # LR trên shared_var
    li      t5, 99
    sc.w    t6, t5, (t1)        # SC trên scratch_var (địa chỉ khác!) => phải FAIL

    beqz    t6, fail_5          # t6 == 0 => SC thành công bất ngờ => FAIL
    lw      a1, 0(t1)
    li      a2, 60
    bne     a1, a2, fail_5      # scratch_var phải giữ nguyên = 60
    addi    s0, s0, 1           # PASS
    j       test_6
fail_5:
    nop

# =============================================================================
# TEST 6: LR.W mới sẽ invalidate reservation cũ
# Thực hiện LR.W hai lần, rồi SC.W tới địa chỉ đầu tiên => phải FAIL
# =============================================================================
test_6:
    addi    s1, s1, 1

    la      t0, shared_var
    la      t1, scratch_var
    li      t2, 10
    sw      t2, 0(t0)           # shared_var = 10
    li      t3, 20
    sw      t3, 0(t1)           # scratch_var = 20

    lr.w    t4, (t0)            # LR trên shared_var (reservation #1)
    lr.w    t5, (t1)            # LR trên scratch_var (reservation #2, xóa #1)
    li      t6, 30
    sc.w    a1, t6, (t0)        # SC trên shared_var => phải FAIL (reservation ở scratch_var)

    beqz    a1, fail_6          # a1 == 0 => SC thành công bất ngờ => FAIL
    lw      a2, 0(t0)
    li      a3, 10
    bne     a2, a3, fail_6      # shared_var phải giữ nguyên = 10
    addi    s0, s0, 1           # PASS
    j       test_7
fail_6:
    nop

# =============================================================================
# TEST 7: LR.W/SC.W vòng lặp CAS (Compare-And-Swap pattern)
# Mô phỏng atomic add: shared_var += 5
# Mong đợi: Sau vòng lặp, shared_var tăng đúng 5
# =============================================================================
test_7:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 100
    sw      t1, 0(t0)           # shared_var = 100

    # Atomic add 5 pattern
cas_retry_7:
    lr.w    t2, (t0)            # t2 = giá trị hiện tại
    addi    t3, t2, 5           # t3 = giá trị mới (+5)
    sc.w    t4, t3, (t0)        # Cố gắng ghi
    bnez    t4, cas_retry_7     # Nếu SC fail => thử lại

    lw      t5, 0(t0)
    li      t6, 105
    bne     t5, t6, fail_7      # shared_var phải = 105
    addi    s0, s0, 1           # PASS
    j       test_8
fail_7:
    nop

# =============================================================================
# TEST 8: Spinlock acquire/release bằng LR/SC
# Mô phỏng: lock -> critical section -> unlock
# =============================================================================
test_8:
    addi    s1, s1, 1

    la      t0, shared_var
    sw      zero, 0(t0)         # shared_var = 0 (unlocked)

    # --- Acquire lock ---
spin_lock_8:
    lr.w.aq t1, (t0)            # LR với acquire ordering
    bnez    t1, spin_lock_8     # Nếu lock != 0 => đã bị khóa => thử lại
    li      t2, 1
    sc.w    t3, t2, (t0)        # Cố ghi 1 (locked)
    bnez    t3, spin_lock_8     # SC fail => thử lại

    # --- Critical section ---
    la      t4, result_var
    li      t5, 0x12345678
    sw      t5, 0(t4)           # Ghi giá trị trong critical section

    # --- Release lock ---
    sc.w.rl t6, zero, (t0)     # Thử unlock bằng SC.RL (sẽ fail vì ko có LR)
    # Cách đúng: dùng AMOSWAP hoặc SW thường để unlock
    sw      zero, 0(t0)         # Unlock bằng store thường

    # Kiểm tra
    lw      a1, 0(t4)
    li      a2, 0x12345678
    bne     a1, a2, fail_8
    lw      a3, 0(t0)
    bnez    a3, fail_8          # Lock phải = 0 (unlocked)
    addi    s0, s0, 1           # PASS
    j       test_9
fail_8:
    nop

# =============================================================================
# TEST 9: LR.W/SC.W với ordering bits (aq/rl)
# Kiểm tra LR.W.AQ và SC.W.RL hoạt động đúng
# =============================================================================
test_9:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 500
    sw      t1, 0(t0)           # shared_var = 500

    lr.w.aq   t2, (t0)         # LR với acquire
    addi      t3, t2, 10       # t3 = 510
    sc.w.rl   t4, t3, (t0)     # SC với release

    bnez    t4, fail_9          # SC phải thành công
    lw      t5, 0(t0)
    li      t6, 510
    bne     t5, t6, fail_9      # shared_var phải = 510
    addi    s0, s0, 1           # PASS
    j       test_10
fail_9:
    nop

# =============================================================================
# TEST 10: LR.W.AQRL + SC.W.AQRL (sequentially consistent)
# =============================================================================
test_10:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 999
    sw      t1, 0(t0)           # shared_var = 999

    lr.w.aqrl t2, (t0)         # LR sequentially consistent
    addi      t3, t2, 1        # t3 = 1000
    sc.w.aqrl t4, t3, (t0)     # SC sequentially consistent

    bnez    t4, fail_10
    lw      t5, 0(t0)
    li      t6, 1000
    bne     t5, t6, fail_10     # shared_var phải = 1000
    addi    s0, s0, 1           # PASS
    j       test_11
fail_10:
    nop

# =============================================================================
# TEST 11: Atomic swap bằng LR/SC
# Đổi giá trị: shared_var = new_val, trả về old_val
# =============================================================================
test_11:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 0xAAAAAAAA
    sw      t1, 0(t0)           # shared_var = 0xAAAAAAAA

    li      t3, 0x55555555      # Giá trị mới muốn swap vào
swap_retry_11:
    lr.w    t2, (t0)            # t2 = old_val
    sc.w    t4, t3, (t0)        # Ghi new_val
    bnez    t4, swap_retry_11   # Retry nếu fail

    # Kiểm tra: t2 (old) = 0xAAAAAAAA, mem = 0x55555555
    li      t5, 0xAAAAAAAA
    bne     t2, t5, fail_11
    lw      t6, 0(t0)
    li      a1, 0x55555555
    bne     t6, a1, fail_11
    addi    s0, s0, 1           # PASS
    j       test_12
fail_11:
    nop

# =============================================================================
# TEST 12: SC.W ghi 0 vào rd khi thành công (kiểm tra chính xác rd=0)
# =============================================================================
test_12:
    addi    s1, s1, 1

    la      t0, shared_var
    li      t1, 77
    sw      t1, 0(t0)

    li      t4, 0xFFFFFFFF      # Đặt t4 = all-ones trước
    lr.w    t2, (t0)
    li      t3, 88
    sc.w    t4, t3, (t0)        # Nếu thành công, t4 PHẢI = 0

    bnez    t4, fail_12         # t4 phải chính xác = 0
    addi    s0, s0, 1           # PASS
    j       done
fail_12:
    nop

# =============================================================================
# KẾT THÚC - In kết quả
# =============================================================================
done:
    # s0 = số test PASS, s1 = tổng số test
    # Exit code = (tổng test - test pass) => 0 nếu tất cả PASS
    sub     a0, s1, s0          # a0 = số test FAIL
    li      a7, 93              # syscall exit (Linux/pk convention)
    ecall

    # Fallback nếu chạy bare-metal (infinite loop)
    j       .
