//! IDT (Interrupt Descriptor Table).
//!
//! CPU는 예외나 인터럽트가 발생하면 벡터 번호로 이 표를 찾아
//! 해당 핸들러로 점프한다. 표가 없거나 항목이 비어 있으면
//! "핸들러를 부르려다 실패" → 그것도 예외 → 또 실패 → 트리플 폴트 →
//! CPU 리셋. 원인 표시 없이 그냥 리부트된다.
//!
//! 그래서 IDT를 일찍 세우는 것이 곧 디버깅 능력이다.

const gdt = @import("gdt.zig");

pub const Gate = enum(u4) {
    /// 진입 시 인터럽트를 자동으로 끈다. 예외 처리에 적합.
    interrupt = 0xE,
    /// 인터럽트를 끄지 않는다. 중첩을 허용해야 할 때.
    trap = 0xF,
};

/// 64비트 IDT 엔트리는 16바이트. (Intel SDM Vol.3 Ch.6.14.1)
const Entry = packed struct(u128) {
    offset_low: u16 = 0,
    selector: u16 = 0,
    /// Interrupt Stack Table 인덱스. 0이면 현재 스택을 그대로 쓴다.
    /// 스택이 망가져서 생긴 예외라면 그 스택으로 핸들러를 부를 수 없으니,
    /// 나중에 double fault용으로 별도 스택을 지정하게 된다(TSS 필요).
    ist: u3 = 0,
    reserved0: u5 = 0,
    gate_type: u4 = 0,
    zero: u1 = 0,
    dpl: u2 = 0,
    present: bool = false,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved1: u32 = 0,

    fn init(handler: u64, gate: Gate) Entry {
        return .{
            .offset_low = @truncate(handler),
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
            .selector = gdt.kernel_code,
            .gate_type = @intFromEnum(gate),
            .present = true,
        };
    }
};

const Descriptor = packed struct(u80) {
    limit: u16,
    base: u64,
};

/// 0..31은 CPU 예외, 32..47은 PIC를 통한 하드웨어 인터럽트,
/// 나머지는 소프트웨어용.
pub const entry_count = 256;

var table = [_]Entry{.{}} ** entry_count;
var descriptor: Descriptor = undefined;

pub fn setHandler(vector: u8, handler: *const anyopaque, gate: Gate) void {
    table[vector] = Entry.init(@intFromPtr(handler), gate);
}

pub fn load() void {
    descriptor = .{
        .limit = @sizeOf(@TypeOf(table)) - 1,
        .base = @intFromPtr(&table),
    };
    asm volatile ("lidt (%[desc])"
        :
        : [desc] "r" (&descriptor),
        : .{ .memory = true });
}
