proc riscv_authenticate {} {
    echo "\[Bảo mật\] Đang khởi động quy trình mở khóa JTAG..."

    # Đọc thanh ghi authdata (Địa chỉ 0x30 của DMI)
    # Trong OpenOCD, lệnh này trả về giá trị Hexa và gán vào biến 'challenge'
    set challenge [riscv dmi_read 0x30]
    echo "\[Bảo mật\] Mã thử thách (Challenge) từ phần cứng: $challenge"

    # Tính toán mã phản hồi (Response)
    # TCL hỗ trợ tính toán toán học. Ví dụ dưới đây là phép XOR với một Secret Key.
    # Bạn có thể thay bằng logic mã hóa của riêng lõi RoT của bạn.
    # Lưu ý: TCL dùng [expr {...}] để tính toán.
    set secret_key 0xDEADBEEF
    set response [expr {$challenge ^ $secret_key}]

    # Format lại thành chuỗi Hexa cho đẹp (Tùy chọn)
    set response_hex [format "0x%08X" $response]
    echo "\[Bảo mật\] Đang gửi mã phản hồi (Response): $response_hex"

    # Ghi ngược lại vào thanh ghi authdata để mở khóa
    riscv dmi_write 0x30 $response_hex

    echo "\[Bảo mật\] Mở khóa thành công! Hệ thống sẵn sàng cho GDB."
}
