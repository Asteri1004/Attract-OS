//! 시간.
//!
//! 게임 OS의 심장이다. 여기서 나오는 숫자가 프레임 페이싱과
//! 나중에 만들 데드라인 스케줄러의 기준이 된다.

const arch = @import("arch/x86_64/arch.zig");

/// 1ms 해상도. 60fps(16.67ms)를 다루기에 충분하고
/// 인터럽트 부담도 크지 않다.
pub const tick_hz: u32 = 1000;

const IRQ_TIMER: u4 = 0;

var ticks: u64 = 0;

/// 매 틱마다 부를 훅. 스케줄러가 여기에 걸려 예산을 감시한다.
///
/// time이 sched를 직접 import하지 않는 이유: sched가 time을 쓰므로
/// 순환 의존이 된다. 콜백으로 방향을 끊는다.
var tick_hook: ?*const fn () void = null;

pub fn setTickHook(hook: *const fn () void) void {
    tick_hook = hook;
}

fn onTick() void {
    @atomicStore(u64, &ticks, @atomicLoad(u64, &ticks, .monotonic) + 1, .monotonic);
    if (tick_hook) |hook| hook();
}

pub fn init() void {
    arch.pit.init(tick_hz);
    arch.isr.setIrqHandler(IRQ_TIMER, onTick);
    arch.pic.unmask(IRQ_TIMER);
}

/// TSC를 PIT 기준으로 보정한다. 인터럽트를 켠 뒤에 불러야 한다
/// (타이머 틱이 돌아야 기준 시계가 생기므로).
pub fn calibrateTsc() void {
    arch.tsc.calibrate(millis, 100);
}

/// 부팅 이후 마이크로초. millis()보다 1000배 정밀하다.
pub inline fn micros() u64 {
    return arch.tsc.micros();
}

/// 부팅 이후 경과 밀리초.
///
/// atomic으로 읽는 이유: 인터럽트가 바꾸는 값이라 컴파일러가
/// 레지스터에 캐싱하면 대기 루프가 영원히 끝나지 않는다.
pub fn millis() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}

/// 지정 시각까지 대기. 인터럽트를 켠 채로 CPU를 재운다.
///
/// 바쁜 대기(`while (millis() < t) {}`)와의 차이가 중요하다.
/// hlt는 다음 인터럽트까지 CPU를 멈추므로 전력과 열을 아끼고,
/// 무엇보다 나중에 다른 스레드에 시간을 넘길 여지를 남긴다.
pub fn sleepUntil(target_ms: u64) void {
    while (millis() < target_ms) {
        arch.port.hlt();
    }
}

pub fn sleep(ms: u64) void {
    sleepUntil(millis() + ms);
}
