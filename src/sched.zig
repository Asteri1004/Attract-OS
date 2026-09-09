//! 데드라인 스케줄러.
//!
//! 여기가 이 프로젝트의 정체성이다. 일반 OS가 "공정하게 나눠주기"를
//! 하는 자리에서 "마감 지키기"로 바꾼다.
//!
//! 세 가지가 다르다:
//!
//! 1. **선택 기준이 마감이다.** 라운드로빈이 아니라 EDF(Earliest
//!    Deadline First) - 준비된 스레드 중 마감이 가장 임박한 것을 고른다.
//!    처리량은 손해지만 "제때 끝났는가"에서는 최적에 가깝다고 알려져 있다.
//!
//! 2. **예산을 넘기면 뺏는다.** 타이머가 매 틱마다 감시하다가
//!    할당량을 넘긴 스레드를 선점한다. 협력에 기대지 않는다.
//!
//! 3. **프레임이 스케줄링 단위다.** 스레드는 프레임당 한 번 일하고
//!    다음 프레임까지 잠든다. 남는 시간을 채우려 들지 않는다.

const std = @import("std");
const context = @import("arch/x86_64/context.zig");
const arch = @import("arch/x86_64/arch.zig");
const mem = @import("mem/mem.zig");
const time = @import("time.zig");
const serial = @import("serial.zig");

pub const max_threads = 8;
pub const default_stack_size = 32 * 1024;

/// 스택 바닥에 심어두는 표식.
///
/// 커널에는 스택 가드 페이지가 없어서 스택이 넘치면 그냥 아래쪽
/// 메모리를 짓밟는다. 증상은 "관계없는 변수가 이상해짐"으로 나타나
/// 원인 추적이 지옥이다. 이 값이 깨졌는지 확인하는 것만으로도
/// 상당수를 잡을 수 있다.
const stack_guard: u64 = 0xDEAD_BEEF_CAFE_F00D;

pub const State = enum {
    ready,
    running,
    /// 이번 프레임 몫을 끝냈다. 다음 프레임에 깨어난다.
    frame_done,
    /// 특정 시각까지 대기
    sleeping,
};

pub const Thread = struct {
    id: u8,
    name: []const u8,
    state: State = .ready,

    /// 저장된 스택 포인터. 실행 중이 아닐 때만 유효하다.
    rsp: u64 = 0,
    stack: []u8 = &.{},

    wake_at: u64 = 0,

    // ── 데드라인 스케줄링 ──
    /// 한 프레임에 이 스레드가 쓸 수 있는 시간 (us). 0이면 무제한.
    budget_us: u64 = 0,
    /// 이번 프레임에 실제로 쓴 시간 (us)
    used_us: u64 = 0,
    /// 이번 프레임 안에서 끝나야 하는 시각 (부팅 이후 us).
    /// **스케줄러는 이 값이 작은 스레드를 먼저 고른다.**
    deadline_us: u64 = 0,
    /// 마감보다 얼마나 앞서 끝나야 하는가. 작을수록 급하다.
    /// render는 present가 프레임 끝에 걸려야 하므로 여유가 적다.
    slack_us: u64 = 0,

    // ── 통계 ──
    switches: u64 = 0,
    preemptions: u64 = 0,
    overruns: u64 = 0,
    worst_us: u64 = 0,
    /// 마감을 넘긴 횟수. 이 값이 0으로 유지되는 것이 목표다.
    missed_deadlines: u64 = 0,

    /// 할 일이 없을 때 CPU를 재우는 스레드.
    is_idle: bool = false,

    fn guardIntact(self: *const Thread) bool {
        if (self.stack.len < 8) return true;
        const guard: *const u64 = @ptrCast(@alignCast(self.stack.ptr));
        return guard.* == stack_guard;
    }
};

var threads: [max_threads]Thread = undefined;
var thread_count: u8 = 0;
var current_id: u8 = 0;

var slice_start_us: u64 = 0;

/// 통계에서 제외할 초기 전환 횟수.
var warmup: u32 = 200;

// ── 프레임 ──
pub var frame_number: u64 = 0;
var frame_start_us: u64 = 0;
var frame_budget_us: u64 = 16_667;

/// idle이 연속으로 선택된 횟수. 교착 감지에 쓴다.
var idle_streak: u32 = 0;

/// 선점 요청. 타이머가 세우고, 안전한 지점에서 처리한다.
var need_resched: bool = false;

/// 선점을 잠시 막는다. 스케줄러 자신이 도는 동안 재진입하면 안 된다.
var preempt_disabled: u32 = 0;

pub fn current() *Thread {
    return &threads[current_id];
}

pub fn count() u8 {
    return thread_count;
}

pub fn get(id: u8) *Thread {
    return &threads[id];
}

pub fn init(frame_us: u64) void {
    threads[0] = .{
        .id = 0,
        .name = "idle",
        .state = .running,
        .is_idle = true,
    };
    thread_count = 1;
    current_id = 0;
    frame_budget_us = frame_us;
    slice_start_us = time.micros();
    frame_start_us = slice_start_us;
}

pub const Error = error{ TooManyThreads, OutOfMemory };

/// 스레드를 만든다.
///
/// `slack_us`는 "마감까지 남겨둘 여유"다. 이 값이 작을수록
/// 마감이 이르게 잡혀 우선순위가 높아진다.
pub fn spawn(
    name: []const u8,
    entry: *const fn () callconv(.c) noreturn,
    stack_size: usize,
    budget_us: u64,
    slack_us: u64,
) Error!*Thread {
    if (thread_count >= max_threads) return Error.TooManyThreads;

    const stack = mem.heap.allocator().alloc(u8, stack_size) catch
        return Error.OutOfMemory;

    const guard: *u64 = @ptrCast(@alignCast(stack.ptr));
    guard.* = stack_guard;

    const id = thread_count;
    threads[id] = .{
        .id = id,
        .name = name,
        .state = .ready,
        .stack = stack,
        // 표식을 밟지 않도록 그 위부터 스택으로 쓴다
        .rsp = context.initStack(stack[8..], entry),
        .budget_us = budget_us,
        .slack_us = slack_us,
    };
    thread_count += 1;

    serial.print("[+] thread ");
    serial.printDec(id);
    serial.print(" '");
    serial.print(name);
    serial.print("' budget ");
    serial.printDec(budget_us);
    serial.print("us slack ");
    serial.printDec(slack_us);
    serial.println("us");

    return &threads[id];
}

// ─────────────────────────────────────────────────────────────────────
// 스케줄링 정책
// ─────────────────────────────────────────────────────────────────────

/// 다음에 실행할 스레드를 고른다. **Earliest Deadline First.**
///
/// 라운드로빈과의 차이가 핵심이다. 라운드로빈은 "누가 오래 기다렸나"를
/// 보지만, EDF는 "누가 급한가"를 본다. 프레임 끝에 반드시 화면이
/// 나가야 하는 render는 언제나 logic보다 급하다.
///
/// 예산을 넘긴 스레드는 후순위로 밀린다. 마감을 못 지킬 게 확실한
/// 스레드에 시간을 더 주는 것보다, 아직 지킬 수 있는 쪽을 살리는 게 낫다.
fn pickNext() ?u8 {
    const now_ms = time.millis();

    // 잠든 스레드 중 시간이 된 것들을 깨운다
    var i: u8 = 0;
    while (i < thread_count) : (i += 1) {
        if (threads[i].state == .sleeping and now_ms >= threads[i].wake_at) {
            threads[i].state = .ready;
        }
    }

    var best: ?u8 = null;
    var best_key: u64 = std.math.maxInt(u64);

    i = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        if (t.state != .ready and t.state != .running) continue;
        if (t.is_idle) continue; // 진짜 할 일이 없을 때만

        // 예산 초과분을 마감에 더해 후순위로 민다.
        // 초과가 클수록 뒤로 밀린다.
        const over = if (t.budget_us > 0 and t.used_us > t.budget_us)
            (t.used_us - t.budget_us) * 4
        else
            0;

        const key = t.deadline_us +| over;
        if (key < best_key) {
            best_key = key;
            best = i;
        }
    }

    if (best) |b| return b;

    // 아무도 준비되지 않았으면 유휴 스레드로
    i = 0;
    while (i < thread_count) : (i += 1) {
        if (threads[i].is_idle) return i;
    }
    return null;
}

/// CPU를 놓아준다.
///
/// noinline: 이 함수 안에서 스택이 통째로 바뀐다. 호출자에 인라인되면
/// 호출자의 스택 프레임 가정이 깨진다.
pub noinline fn yield() void {
    // **defer를 쓰면 안 된다.**
    //
    // switchTo로 다른 스레드에 넘어가면 이 함수는 그 자리에서 멈추고,
    // defer는 실행되지 않는다. 특히 갓 생성된 스레드는 진입점으로 바로
    // 뛰어들기 때문에 defer가 존재하지도 않는다. 그러면 preempt_disabled가
    // 1 이상으로 굳어버리고 선점이 영영 일어나지 않는다.
    //
    // 증상: 타이머 훅은 불리는데(ticks 증가) 예산 검사까지 못 감(checks 0).
    //
    // 전역 변수인데 실행 흐름이 갈라지는 상황이라, 각 경로에서 직접 푼다.
    preempt_disabled += 1;
    need_resched = false;

    const me = &threads[current_id];

    // 이번에 쓴 시간을 정산
    const now = time.micros();
    const used = now -| slice_start_us;
    if (!me.is_idle) {
        me.used_us += used;
        if (warmup == 0 and used > me.worst_us) me.worst_us = used;
    }

    if (!me.guardIntact()) {
        serial.print("\n!! stack overflow in thread '");
        serial.print(me.name);
        serial.println("'");
        arch.halt();
    }

    const next_id = pickNext() orelse {
        slice_start_us = time.micros();
        preempt_disabled -= 1;
        return;
    };

    // 교착 감지.
    //
    // 프레임 마스터가 잠들어 아무도 advanceFrame()을 부르지 못하면
    // 모든 일꾼이 frame_done인 채로 idle만 돌게 된다. 화면은 마지막
    // 프레임에서 멈추고 아무 에러도 나지 않아 원인을 찾기 어렵다.
    if (threads[next_id].is_idle) {
        idle_streak += 1;
        if (idle_streak == 3000) {
            serial.println("\n!! scheduler stall - no thread is runnable");
            serial.print("   frame ");
            serial.printDec(frame_number);
            serial.print(", states:");
            var k: u8 = 0;
            while (k < thread_count) : (k += 1) {
                serial.print(" ");
                serial.print(threads[k].name);
                serial.print("=");
                serial.print(@tagName(threads[k].state));
            }
            serial.print("\n");
        }
    } else {
        idle_streak = 0;
    }

    if (next_id == current_id) {
        slice_start_us = time.micros();
        preempt_disabled -= 1;
        return;
    }

    if (me.state == .running) me.state = .ready;
    threads[next_id].state = .running;

    if (warmup > 0) warmup -= 1;

    const prev_id = current_id;
    current_id = next_id;
    threads[next_id].switches += 1;
    slice_start_us = time.micros();

    // 전환하기 전에 푼다. 이 시점 이후로는 이 함수의 코드가
    // 언제 다시 실행될지 알 수 없으므로, 뒷정리를 남겨두면 안 된다.
    preempt_disabled -= 1;

    context.switchTo(&threads[prev_id].rsp, threads[next_id].rsp);
    // 여기로 돌아왔다는 건 누군가 다시 나를 골랐다는 뜻이다.
    // 그 사이 preempt_disabled는 다른 스레드들이 알아서 관리했다.
}

/// 이번 프레임 몫을 끝냈다고 알린다. 다음 프레임까지 잠든다.
///
/// **M4a에서 logic이 프레임당 14번 돌던 문제의 해법이다.**
/// 협력적 스케줄링에서는 스레드가 프레임 경계를 몰라서, CPU가 남으면
/// 계속 일했다. 이제 스케줄러가 경계를 관리한다.
pub noinline fn endFrame() void {
    const me = &threads[current_id];

    // 마감을 지켰는지 기록
    const now = time.micros();
    if (me.deadline_us > 0 and now > me.deadline_us) me.missed_deadlines += 1;
    if (me.budget_us > 0 and me.used_us > me.budget_us) me.overruns += 1;

    me.state = .frame_done;
    yield();
}

/// 프레임 경계를 선언하고 모든 스레드를 깨운다.
///
/// **프레임 마스터 스레드(render)만 부른다.** 자기 자신은 `frame_done`이
/// 되지 않는다 - 그러면 다음 프레임을 시작할 사람이 없어져 아무도
/// 깨어나지 못하는 교착이 된다.
///
/// 역할이 갈린다:
///   endFrame()     일꾼용. 몫을 끝내고 다음 프레임까지 잠든다
///   advanceFrame() 마스터용. 경계를 긋고 잠든 일꾼들을 깨운다
pub fn advanceFrame() void {
    const now = time.micros();

    // 마스터 자신의 이번 프레임 결과부터 기록
    const me = &threads[current_id];
    if (!me.is_idle) {
        if (me.deadline_us > 0 and now > me.deadline_us) me.missed_deadlines += 1;
        if (me.budget_us > 0 and me.used_us > me.budget_us) me.overruns += 1;
    }

    frame_number += 1;
    frame_start_us = now;

    var i: u8 = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        t.used_us = 0;
        if (t.state == .frame_done) t.state = .ready;

        // 마감 = 프레임 끝 - 여유.
        // slack이 작은 스레드일수록 마감이 이르게 잡혀 먼저 실행된다.
        t.deadline_us = frame_start_us + frame_budget_us -| t.slack_us;
    }
}

/// 지정 시각까지 잔다.
pub noinline fn sleepUntil(wake_ms: u64) void {
    const me = &threads[current_id];
    me.wake_at = wake_ms;
    me.state = .sleeping;

    while (time.millis() < wake_ms) {
        yield();
        if (me.state == .sleeping and time.millis() < wake_ms) {
            arch.port.hlt();
        }
    }
    me.state = .running;
}

// ─────────────────────────────────────────────────────────────────────
// 선점
// ─────────────────────────────────────────────────────────────────────

/// 타이머 인터럽트가 매 틱마다 부른다.
///
/// 여기서 컨텍스트를 바꾼다는 게 M4a와의 결정적 차이다.
/// 스레드가 `yield()`를 부르지 않아도, 예산을 넘기면 **문장 중간에서**
/// 끊긴다. 무한 루프에 빠진 스레드도 프레임을 망치지 못한다.
///
/// 이게 가능한 이유:
///   - 인터럽트 진입 시 스텁이 모든 레지스터를 저장해뒀다
///   - 여기서 전환하면 이 스레드는 "인터럽트 핸들러 안에서 멈춘"
///     상태가 되고, 나중에 재개되면 핸들러를 마저 실행하고 iretq로
///     원래 코드로 돌아간다
///   - 각 스레드가 rflags를 들고 다니므로 인터럽트 상태도 보존된다
pub var tick_count: u64 = 0;
pub var preempt_checks: u64 = 0;

pub fn onTick() void {
    tick_count += 1;

    if (preempt_disabled > 0) return;

    const me = &threads[current_id];
    if (me.is_idle) return;
    if (me.budget_us == 0) return;

    preempt_checks += 1;

    const used = me.used_us + (time.micros() -| slice_start_us);
    if (used <= me.budget_us) return;

    // 예산 초과. 뺏는다.
    me.preemptions += 1;
    yield();
}

// ─────────────────────────────────────────────────────────────────────

pub fn report() void {
    serial.println("  name     worst(us)  budget  preempt  over  missed");
    var i: u8 = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        if (t.is_idle) continue;

        serial.print("  ");
        serial.print(t.name);
        var pad = if (t.name.len < 9) 9 - t.name.len else 1;
        while (pad > 0) : (pad -= 1) serial.putc(' ');

        printPadded(t.worst_us, 9);
        printPadded(t.budget_us, 8);
        printPadded(t.preemptions, 9);
        printPadded(t.overruns, 6);
        printPadded(t.missed_deadlines, 8);
        serial.print("\n");
    }
}

fn printPadded(value: u64, width: usize) void {
    var digits: usize = 1;
    var v = value;
    while (v >= 10) : (v /= 10) digits += 1;
    var pad = if (width > digits) width - digits else 0;
    while (pad > 0) : (pad -= 1) serial.putc(' ');
    serial.printDec(value);
}
