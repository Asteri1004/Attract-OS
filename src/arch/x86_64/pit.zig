//! 8254 PIT (Programmable Interval Timer).
//!
//! 고정 주파수로 IRQ0을 발생시키는 칩. 이것 역시 IBM PC 유물이지만,
//! 설정이 단순하고 어디서나 동작해서 시간의 출발점으로 삼기 좋다.
//!
//! 정밀도가 필요해지면 TSC나 HPET으로 옮긴다. 지금 필요한 건
//! "일정 간격으로 깨어나는 것"이지 나노초 단위 정확도가 아니다.

const port = @import("port.zig");

const CHANNEL0: u16 = 0x40;
const COMMAND: u16 = 0x43;

/// PIT의 입력 클럭. 원래 NTSC 컬러버스트(3.579545MHz)의 1/3이라
/// 이렇게 어중간한 값이 되었다. 진짜 유물.
pub const base_frequency: u32 = 1_193_182;

/// 목표 주파수로 설정. 실제 주파수는 정수 분주비 때문에 약간 어긋난다.
pub fn init(hz: u32) void {
    const divisor: u16 = @intCast(base_frequency / hz);

    // 0b00_11_010_0
    //   채널0, 하위·상위 바이트 순서로 쓰기, 모드3(구형파), 2진수
    port.outb(COMMAND, 0b00_11_010_0);
    port.outb(CHANNEL0, @truncate(divisor));
    port.outb(CHANNEL0, @truncate(divisor >> 8));
}

/// 설정된 분주비로 실제 나오는 주파수. 오차를 확인할 때 쓴다.
pub fn actualFrequency(hz: u32) u32 {
    const divisor: u32 = base_frequency / hz;
    return base_frequency / divisor;
}
