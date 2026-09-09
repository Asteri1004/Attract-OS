//! 커널 전역 상태와 공용 진입점.
//!
//! main.zig는 "부팅 순서"만 다루고, 실제 상태는 여기 모인다.
//! 앞으로 메모리 관리자(M3)와 스케줄러(M4)가 이 파일에 붙는다.

const arch = @import("arch/x86_64/arch.zig");
const serial = @import("serial.zig");
const gfx = @import("framebuffer.zig");

pub const name = "Attract";
pub const version = "0.6.0";

/// 화면. 부팅 시 한 번 세팅되고 이후 바뀌지 않는다.
pub var screen: gfx.Framebuffer = undefined;
pub var canvas: gfx.Canvas = undefined;

/// 되돌아올 수 없는 실패. 예외 핸들러와 같은 곳으로 모인다.
pub fn panic(msg: []const u8) noreturn {
    serial.print("\n!! KERNEL PANIC: ");
    serial.println(msg);
    arch.halt();
}
