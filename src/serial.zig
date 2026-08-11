//! COM1 시리얼 포트 (16550 UART).
//!
//! 커널에는 printf가 없다. 이 파일이 모든 디버깅의 통로다.
//! 그래픽보다 먼저 만든 이유: 화면이 검을 때 원인을 알 방법이 필요하기 때문.
//!
//! 참고: PC의 COM1은 관례적으로 I/O 포트 0x3F8에 매핑되어 있다.
//! QEMU의 -serial stdio 옵션이 이 포트를 터미널 stdout에 연결해준다.

const port = @import("arch/x86_64/port.zig");

const COM1: u16 = 0x3F8;

// 레지스터 오프셋 (DLAB=0 기준)
const DATA = 0; // 송수신 버퍼
const IER = 1; // 인터럽트 활성화 레지스터
const FCR = 2; // FIFO 제어 레지스터
const LCR = 3; // 라인 제어 레지스터
const MCR = 4; // 모뎀 제어 레지스터
const LSR = 5; // 라인 상태 레지스터

/// UART 초기화. 순서가 중요하다 — DLAB 비트를 켜야 분주비를 쓸 수 있다.
pub fn init() void {
    port.outb(COM1 + IER, 0x00); // 인터럽트 끄기 (아직 IDT가 없다)
    port.outb(COM1 + LCR, 0x80); // DLAB=1 → 다음 두 쓰기가 분주비로 해석됨
    port.outb(COM1 + DATA, 0x03); // 분주비 하위 = 3 → 115200/3 = 38400 baud
    port.outb(COM1 + IER, 0x00); // 분주비 상위 = 0
    port.outb(COM1 + LCR, 0x03); // DLAB=0, 8비트 / 패리티 없음 / 스톱비트 1
    port.outb(COM1 + FCR, 0xC7); // FIFO 켜고 비우기, 임계값 14바이트
    port.outb(COM1 + MCR, 0x0B); // DTR + RTS + OUT2 켜기
}

/// 송신 버퍼가 빌 때까지 대기. LSR bit 5 = Transmitter Holding Register Empty.
fn txReady() bool {
    return (port.inb(COM1 + LSR) & 0x20) != 0;
}

pub fn putc(c: u8) void {
    while (!txReady()) {}
    port.outb(COM1 + DATA, c);
}

/// 문자열 출력. '\n'을 만나면 '\r'을 먼저 넣어준다 (터미널 줄 정렬용).
pub fn print(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

pub fn println(s: []const u8) void {
    print(s);
    print("\n");
}

/// 10진 출력. std.fmt는 할당자를 요구할 수 있어서 직접 만든다.
pub fn printDec(value: u64) void {
    if (value == 0) {
        putc('0');
        return;
    }
    var buf: [20]u8 = undefined; // u64 최대 20자리
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        putc(buf[i]);
    }
}

/// 16진 출력. 주소를 찍을 일이 아주 많다.
/// 자릿수를 16자리로 고정하는 편이 덤프를 눈으로 정렬해 읽기 좋다.
pub fn printHex(value: u64) void {
    const digits = "0123456789ABCDEF";
    print("0x");
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        putc(digits[@truncate((value >> shift) & 0xF)]);
        if (shift == 0) break;
    }
}
