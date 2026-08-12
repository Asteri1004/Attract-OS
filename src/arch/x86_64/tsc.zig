//! TSC (Time Stamp Counter).
//!
//! CPU가 부팅 이후 센 클럭 사이클 수. 읽는 데 명령 하나면 되고
//! 나노초 수준의 해상도가 나온다. PIT의 1ms로는 볼 수 없던 것들이 보인다.
//!
//! 주의할 점 두 가지:
//!
//! 1. **주파수를 모른다.** TSC는 사이클을 셀 뿐이라 초당 몇 개인지는
//!    직접 재야 한다. PIT처럼 주파수가 알려진 시계로 보정한다.
//!
//! 2. **옛날 CPU에서는 믿을 수 없었다.** 주파수 스케일링이나 절전 상태에
//!    따라 속도가 변했기 때문. 요즘 CPU는 "invariant TSC"라 항상 일정한
//!    속도로 도는데, CPUID로 확인할 수 있다.

const port = @import("port.zig");

/// 사이클 카운터를 읽는다.
///
/// `lfence`를 앞에 두는 이유: rdtsc는 순서 재배치가 가능한 명령이라
/// 측정하려는 코드보다 먼저 실행될 수 있다. 그러면 구간 측정이
/// 엉뚱한 값을 낸다. lfence가 그 앞의 명령을 모두 끝내게 강제한다.
pub inline fn read() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile (
        \\lfence
        \\rdtsc
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .memory = true });
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// invariant TSC 지원 여부. CPUID leaf 0x80000007, EDX bit 8.
/// (Intel SDM Vol.3 Ch.18.17)
pub fn isInvariant() bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    // 확장 leaf가 있는지부터 확인
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 0x8000_0000)),
    );
    if (eax < 0x8000_0007) return false;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 0x8000_0007)),
    );
    return (edx & (1 << 8)) != 0;
}

var ticks_per_us: u64 = 0;
pub var calibration_trusted: bool = false;

/// 마이크로초당 TSC 틱 수를 잰다.
///
/// **보정 중에는 절대 hlt하면 안 된다.**
/// QEMU가 하드웨어 가속 없이(TCG) 돌 때 TSC는 "호스트의 시간"이 아니라
/// "게스트가 실행한 명령 수"를 따라간다. hlt 중에는 명령을 실행하지
/// 않으므로 TSC가 거의 멈춘다. 자면서 보정하면 틱 수가 실제보다
/// 훨씬 적게 세어지고, ticks_per_us가 과소평가되어
/// 이후 모든 측정값이 같은 비율로 부풀려진다.
///
/// 그래서 `pause` 루프로 바쁘게 기다린다. CPU를 태우지만
/// 보정은 부팅 때 한 번뿐이라 감당할 만하다.
///
/// `nowMs`는 주파수가 알려진 기준 시계(PIT)를 읽는 함수다.
pub fn calibrate(nowMs: *const fn () u64, ms: u64) void {
    // 틱 경계에 맞춰 시작한다. 안 그러면 최대 1ms의 오차가 그대로 들어간다.
    const t0 = nowMs();
    while (nowMs() == t0) {
        asm volatile ("pause");
    }

    const begin_ms = nowMs();
    const begin_tsc = read();

    while (nowMs() - begin_ms < ms) {
        asm volatile ("pause");
    }

    const elapsed_ms = nowMs() - begin_ms;
    const elapsed_ticks = read() - begin_tsc;

    ticks_per_us = elapsed_ticks / (elapsed_ms * 1000);

    // 상식 검사. 100MHz ~ 10GHz 범위를 벗어나면 뭔가 잘못된 것이다.
    // 값을 그대로 쓰되 신뢰할 수 없다고 표시해 둔다 -
    // 틀린 시계를 모르고 믿는 것보다 안다고 아는 편이 낫다.
    calibration_trusted = ticks_per_us >= 100 and ticks_per_us <= 10_000;
    if (ticks_per_us == 0) ticks_per_us = 1;
}

pub fn ticksPerUs() u64 {
    return ticks_per_us;
}

/// 대략적인 CPU 주파수 (MHz). 보정 결과를 사람이 읽기 좋게.
pub fn megahertz() u64 {
    return ticks_per_us;
}

/// TSC 틱을 마이크로초로.
pub inline fn toMicros(ticks: u64) u64 {
    return ticks / ticks_per_us;
}

/// TSC 틱을 나노초로. 짧은 구간을 볼 때.
pub inline fn toNanos(ticks: u64) u64 {
    return (ticks * 1000) / ticks_per_us;
}

/// 부팅 이후 마이크로초. millis()보다 1000배 정밀하다.
pub inline fn micros() u64 {
    return read() / ticks_per_us;
}

/// 짧은 지연. 인터럽트를 기다리지 않고 바쁘게 도므로
/// 마이크로초 단위에만 쓴다.
pub fn spin(us: u64) void {
    const target = read() + us * ticks_per_us;
    while (read() < target) {
        asm volatile ("pause");
    }
    _ = port;
}
