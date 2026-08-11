//! 8259 PIC (Programmable Interrupt Controller).
//!
//! 하드웨어 인터럽트(IRQ)를 CPU로 전달하는 칩. 1981년 IBM PC의 유물이고
//! 요즘은 APIC로 대체되었지만, 초기화가 훨씬 간단해서 먼저 쓴다.
//!
//! **반드시 리맵해야 하는 이유:**
//! 기본 설정에서 IRQ 0~7은 벡터 8~15로 들어온다. 그런데 그 범위는
//! CPU 예외가 이미 쓰고 있다 — 벡터 8은 double fault, 13은 general
//! protection fault다. 리맵하지 않으면 타이머 틱이 double fault로 보인다.
//!
//! 이건 IBM이 잘못 정한 게 아니라, 8086 시절엔 예약 벡터가 그렇게 많지
//! 않았고 나중에 인텔이 그 영역을 예외용으로 확장하면서 생긴 충돌이다.

const port = @import("port.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;

const EOI: u8 = 0x20;

/// IRQ 0~15을 벡터 32~47로 옮긴다.
/// 32부터인 이유: 0~31이 CPU 예외 전용이기 때문. (Intel SDM Vol.3 Table 6-1)
pub const vector_base: u8 = 32;

pub fn remap() void {
    // 기존 마스크 보존
    const mask1 = port.inb(PIC1_DATA);
    const mask2 = port.inb(PIC2_DATA);

    // ICW1: 초기화 시작. 이 뒤로 DATA 포트에 쓰는 값은 ICW2/3/4로 해석된다.
    port.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    port.wait();
    port.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    port.wait();

    // ICW2: 벡터 오프셋
    port.outb(PIC1_DATA, vector_base); // master: 32~39
    port.wait();
    port.outb(PIC2_DATA, vector_base + 8); // slave:  40~47
    port.wait();

    // ICW3: 두 칩의 연결 관계.
    // slave는 master의 IRQ2 선에 물려 있다. 그래서 IRQ2는 실제로는
    // 쓸 수 없고, 대신 IRQ8~15가 그 자리를 통해 올라온다.
    port.outb(PIC1_DATA, 0b0000_0100); // master: bit 2에 slave 있음
    port.wait();
    port.outb(PIC2_DATA, 2); // slave: 나는 master의 2번
    port.wait();

    // ICW4: 8086 모드 (8080 모드가 아님)
    port.outb(PIC1_DATA, ICW4_8086);
    port.wait();
    port.outb(PIC2_DATA, ICW4_8086);
    port.wait();

    port.outb(PIC1_DATA, mask1);
    port.outb(PIC2_DATA, mask2);
}

/// 모든 IRQ 차단. 1 = 막힘.
pub fn maskAll() void {
    port.outb(PIC1_DATA, 0xFF);
    port.outb(PIC2_DATA, 0xFF);
}

pub fn unmask(irq: u4) void {
    const p: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const bit: u3 = @intCast(irq & 7);
    port.outb(p, port.inb(p) & ~(@as(u8, 1) << bit));

    // slave의 IRQ를 열려면 master의 캐스케이드 선(IRQ2)도 열어야 한다.
    if (irq >= 8) {
        port.outb(PIC1_DATA, port.inb(PIC1_DATA) & ~(@as(u8, 1) << 2));
    }
}

pub fn mask(irq: u4) void {
    const p: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const bit: u3 = @intCast(irq & 7);
    port.outb(p, port.inb(p) | (@as(u8, 1) << bit));
}

/// End Of Interrupt. **이걸 안 보내면 같은 IRQ가 두 번 다시 오지 않는다.**
/// 타이머가 한 번 돌고 멈추는 버그의 대부분이 이것 때문이다.
pub fn endOfInterrupt(irq: u4) void {
    // slave에서 온 것이면 slave에게도 알려야 한다
    if (irq >= 8) port.outb(PIC2_CMD, EOI);
    port.outb(PIC1_CMD, EOI);
}
