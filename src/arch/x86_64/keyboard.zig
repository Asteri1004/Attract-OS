//! PS/2 키보드 (스캔코드 세트 1).
//!
//! 게임에 필요한 건 "이 키가 눌린 순간"이 아니라 "지금 눌려 있는가"다.
//! 그래서 이벤트 큐가 아니라 **상태 배열**로 관리한다.
//! 인터럽트는 상태를 갱신만 하고, 게임 루프가 프레임마다 읽어간다.
//!
//! 이 구조가 중요한 이유: 인터럽트 핸들러에서 게임 로직을 돌리면
//! 프레임 타이밍이 입력에 따라 흔들린다. 레이턴시를 예측 가능하게
//! 유지하려면 인터럽트는 최대한 짧게 끝내고 빠져나와야 한다.

const port = @import("port.zig");

const DATA: u16 = 0x60;

/// 게임에 쓸 키만 추린다. 필요해질 때 늘린다.
pub const Key = enum(u8) {
    escape,
    space,
    enter,
    up,
    down,
    left,
    right,
    w,
    a,
    s,
    d,

    pub const count = @typeInfo(Key).@"enum".fields.len;
};

var pressed = [_]bool{false} ** Key.count;

/// 다음 바이트가 확장 키의 두 번째 바이트인지.
/// 화살표 키 같은 것들은 0xE0을 앞세워 두 바이트로 온다.
var extended = false;

pub fn isDown(key: Key) bool {
    return pressed[@intFromEnum(key)];
}

/// 스캔코드 하나 처리. IRQ1 핸들러에서 호출한다.
pub fn handleScancode(code: u8) void {
    if (code == 0xE0) {
        extended = true;
        return;
    }

    // 최상위 비트가 켜져 있으면 떼는 동작(break code)
    const is_release = (code & 0x80) != 0;
    const make = code & 0x7F;

    const key: ?Key = if (extended) switch (make) {
        0x48 => .up,
        0x50 => .down,
        0x4B => .left,
        0x4D => .right,
        else => null,
    } else switch (make) {
        0x01 => .escape,
        0x39 => .space,
        0x1C => .enter,
        0x11 => .w,
        0x1E => .a,
        0x1F => .s,
        0x20 => .d,
        else => null,
    };

    extended = false;

    if (key) |k| pressed[@intFromEnum(k)] = !is_release;
}

/// IRQ1 핸들러가 호출. 데이터 포트를 반드시 읽어야 하며,
/// 읽지 않으면 컨트롤러가 다음 인터럽트를 보내지 않는다.
pub fn readAndHandle() void {
    handleScancode(port.inb(DATA));
}
