//! x86 포트 I/O.
//!
//! x86에는 메모리와 별개인 I/O 주소 공간이 있고, 전용 명령으로만 접근한다.
//! 시리얼, PIC, PIT, PS/2 키보드가 전부 이 방식이다.

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

/// 짧은 지연. 오래된 하드웨어(특히 PIC)는 연속 쓰기를 따라오지 못한다.
/// 포트 0x80은 POST 진단용이라 아무 부작용 없이 한 사이클을 버리는 데 쓴다.
pub inline fn wait() void {
    outb(0x80, 0);
}

// ── 인터럽트 제어 ────────────────────────────────────────────────────

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

/// 인터럽트를 켠 채로 대기. 다음 인터럽트까지 CPU를 재운다.
pub inline fn hlt() void {
    asm volatile ("hlt");
}

/// 되돌아올 수 없는 정지. 패닉 이후에 쓴다.
pub fn halt() noreturn {
    while (true) {
        cli();
        hlt();
    }
}
