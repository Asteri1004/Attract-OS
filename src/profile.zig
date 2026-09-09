//! 구간 측정.
//!
//! 기획서 설계 원칙 4번 - "측정할 수 없으면 개선할 수 없다"가
//! 코드가 되는 곳이다.
//!
//! 프레임 시간이 13ms라는 것만으로는 아무것도 할 수 없다.
//! clear가 느린지, present가 느린지, 아니면 폰트 렌더링이 문제인지
//! 알아야 고칠 수 있다.
//!
//! 오버헤드는 구간당 rdtsc 두 번(수십 사이클)이라, 밀리초 단위 구간을
//! 재는 데는 무시할 수 있다. 나노초 단위를 잴 때는 이 오버헤드 자체가
//! 오차가 되므로 주의.

const tsc = @import("arch/x86_64/tsc.zig");
const serial = @import("serial.zig");

/// 측정 구간.
///
/// **대기 구간은 여기 없다.** TSC는 CPU가 실행 중일 때만 사이클을 세므로,
/// hlt로 자는 동안의 시간은 잴 수 없다(invariant TSC가 아닌 환경).
/// 그건 PIT로 따로 재야 한다.
///
/// 다행히 스케줄러가 알아야 할 것은 "작업이 얼마나 걸렸나"이고,
/// 그건 전부 CPU가 도는 구간이라 TSC로 정확하게 잡힌다.
pub const Slot = enum {
    update,
    clear,
    draw,
    present,
    /// update~present 전체. 프레임 예산과 직접 비교하는 값.
    work,
    /// 입력 -> 화면 반영까지. 게임에서 사람이 실제로 체감하는 지연.
    input_latency,

    pub const count = @typeInfo(Slot).@"enum".fields.len;
};

const Stat = struct {
    /// 이번 프레임 값 (TSC 틱)
    last: u64 = 0,
    /// 관측된 최댓값. 평균보다 이게 중요하다 -
    /// 프레임을 놓치는 건 언제나 최악의 경우다.
    worst: u64 = 0,
    /// 평균 계산용 누적
    total: u64 = 0,
    samples: u64 = 0,

    start: u64 = 0,
};

var stats = [_]Stat{.{}} ** Slot.count;

/// 워밍업 구간. 첫 몇 프레임은 캐시가 비어 있고 분기 예측도
/// 학습 전이라 비정상적으로 느리다. 이걸 worst에 넣으면
/// 통계가 영구히 오염된다.
var warmup: u64 = 60;

pub inline fn begin(slot: Slot) void {
    stats[@intFromEnum(slot)].start = tsc.read();
}

pub inline fn end(slot: Slot) void {
    const elapsed = tsc.read() - stats[@intFromEnum(slot)].start;
    const s = &stats[@intFromEnum(slot)];

    s.last = elapsed;
    if (warmup == 0) {
        if (elapsed > s.worst) s.worst = elapsed;
        s.total += elapsed;
        s.samples += 1;
    }
}

/// 프레임 하나가 끝났음을 알린다.
pub fn frameEnd() void {
    if (warmup > 0) warmup -= 1;
}

pub fn lastMicros(slot: Slot) u64 {
    return tsc.toMicros(stats[@intFromEnum(slot)].last);
}

pub fn worstMicros(slot: Slot) u64 {
    return tsc.toMicros(stats[@intFromEnum(slot)].worst);
}

pub fn averageMicros(slot: Slot) u64 {
    const s = stats[@intFromEnum(slot)];
    if (s.samples == 0) return 0;
    return tsc.toMicros(s.total / s.samples);
}

/// 통계를 초기화한다. 최적화 전후를 비교할 때.
pub fn reset() void {
    stats = [_]Stat{.{}} ** Slot.count;
    warmup = 60;
}

pub fn report() void {
    serial.println("  slot      last(us)   avg(us)   worst(us)");
    for (std_slots) |slot| {
        serial.print("  ");
        const label = @tagName(slot);
        serial.print(label);
        var pad = 10 - label.len;
        while (pad > 0) : (pad -= 1) serial.putc(' ');

        printPadded(lastMicros(slot), 9);
        printPadded(averageMicros(slot), 10);
        printPadded(worstMicros(slot), 12);
        serial.print("\n");
    }
}

const std_slots = [_]Slot{ .update, .clear, .draw, .present, .work, .input_latency };

fn printPadded(value: u64, width: usize) void {
    var digits: usize = 1;
    var v = value;
    while (v >= 10) : (v /= 10) digits += 1;

    var pad = if (width > digits) width - digits else 0;
    while (pad > 0) : (pad -= 1) serial.putc(' ');
    serial.printDec(value);
}
