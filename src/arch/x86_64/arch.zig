//! x86_64 아키텍처 진입점.
//!
//! 상위 코드가 gdt / idt / pic을 개별로 알 필요가 없도록 한 겹 덮는다.
//! 나중에 다른 아키텍처를 얹게 되면 이 파일과 같은 인터페이스를
//! 제공하는 형제 모듈을 만들면 된다.
//!
//! 그럴 일은 아마 없겠지만, 경계를 그어두면 "이건 x86 얘기"와
//! "이건 커널 얘기"가 섞이지 않는다.

pub const port = @import("port.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const isr = @import("isr.zig");
pub const pic = @import("pic.zig");
pub const pit = @import("pit.zig");
pub const keyboard = @import("keyboard.zig");
pub const paging = @import("paging.zig");
pub const tsc = @import("tsc.zig");
pub const context = @import("context.zig");

pub const Frame = isr.Frame;

/// CPU를 커널 통제하에 둔다. exitBootServices 직후에 부른다.
///
/// 순서가 곧 이유다:
///   1. GDT — 펌웨어 것을 물려받으면 그 메모리를 재사용하는 순간 죽는다
///   2. IDT — 예외가 나도 원인을 볼 수 있게. 그 전엔 트리플 폴트뿐이다
///   3. PIC 차단 후 리맵 — 리맵 도중 인터럽트가 오면 어디로 갈지 모른다
///
/// 인터럽트는 아직 켜지 않는다. 핸들러를 등록한 뒤 enableInterrupts()로.
pub fn init() void {
    gdt.load();
    isr.install();
    idt.load();

    pic.maskAll();
    pic.remap();
}

pub fn enableInterrupts() void {
    port.sti();
}

pub fn halt() noreturn {
    port.halt();
}
