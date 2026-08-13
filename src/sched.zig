//! 스케줄러.
//!
//! M4a에서는 **협력적**이다. 스레드가 스스로 `yield()`를 불러야 전환된다.
//! 인터럽트로 강제로 뺏는 건 M4b에서.
//!
//! 순서를 이렇게 잡은 이유: 강제 전환은 "언제 어디서든" 일어나므로
//! 버그가 나면 재현이 안 된다. 협력적 전환은 전환 지점이 코드에
//! 명시되어 있어서, 컨텍스트 스위칭 자체가 맞는지 먼저 확인할 수 있다.
//!
//! 자료구조는 처음부터 데드라인 스케줄링을 염두에 두고 잡는다.
//! M4b에서 정책만 갈아끼우면 되도록.

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
    /// 특정 시각까지 대기
    sleeping,
    done,
};

pub const Thread = struct {
    id: u8,
    name: []const u8,
    state: State = .ready,

    /// 저장된 스택 포인터. 실행 중이 아닐 때만 유효하다.
    rsp: u64 = 0,
    stack: []u8 = &.{},

    /// sleeping 상태에서 깨어날 시각 (ms)
    wake_at: u64 = 0,

    // ── 프레임 예산 (M4b에서 본격적으로 쓴다) ──
    /// 한 프레임에 이 스레드가 쓸 수 있는 시간 (us). 0이면 무제한.
    budget_us: u64 = 0,
    /// 이번 프레임에 실제로 쓴 시간 (us)
    used_us: u64 = 0,
    /// 예산을 넘긴 횟수. 스케줄러가 잘 돌고 있는지 보는 지표.
    overruns: u64 = 0,

    /// 할 일이 없을 때 CPU를 재우는 스레드.
    ///
    /// 이 스레드의 실행 시간은 대부분 hlt 대기라 "CPU를 썼다"고
    /// 볼 수 없다. 통계에 넣으면 0.5초짜리 worst 같은 값이 나와
    /// 다른 수치를 읽는 데 방해가 된다.
    is_idle: bool = false,

    // ── 통계 ──
    switches: u64 = 0,
    total_us: u64 = 0,
    worst_us: u64 = 0,

    fn guardIntact(self: *const Thread) bool {
        if (self.stack.len < 8) return true;
        const guard: *const u64 = @ptrCast(@alignCast(self.stack.ptr));
        return guard.* == stack_guard;
    }
};

var threads: [max_threads]Thread = undefined;
var thread_count: u8 = 0;
var current_id: u8 = 0;

/// 스레드가 실행을 시작한 시각. 전환할 때마다 갱신한다.
var slice_start_us: u64 = 0;

/// 통계에서 제외할 초기 전환 횟수.
var warmup: u32 = 200;


pub fn current() *Thread {
    return &threads[current_id];
}

pub fn count() u8 {
    return thread_count;
}

pub fn get(id: u8) *Thread {
    return &threads[id];
}

/// 지금 실행 중인 흐름을 0번 스레드로 등록한다.
///
/// 이게 없으면 첫 전환에서 현재 컨텍스트를 저장할 곳이 없다.
/// 부팅 코드도 하나의 스레드라고 보는 것.
pub fn init() void {
    threads[0] = .{
        .id = 0,
        .name = "idle",
        .state = .running,
        .is_idle = true,
    };
    thread_count = 1;
    current_id = 0;
    slice_start_us = time.micros();
}

pub const Error = error{ TooManyThreads, OutOfMemory };

pub fn spawn(
    name: []const u8,
    entry: *const fn () callconv(.c) noreturn,
    stack_size: usize,
    budget_us: u64,
) Error!*Thread {
    if (thread_count >= max_threads) return Error.TooManyThreads;

    const stack = mem.heap.allocator().alloc(u8, stack_size) catch
        return Error.OutOfMemory;

    // 바닥에 표식을 심는다
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
    };
    thread_count += 1;

    serial.print("[+] thread ");
    serial.printDec(id);
    serial.print(" '");
    serial.print(name);
    serial.print("' stack ");
    serial.printDec(stack_size / 1024);
    serial.println(" KiB");

    return &threads[id];
}

/// 다음에 실행할 스레드를 고른다.
///
/// M4a는 라운드로빈이다. 현재 스레드 다음부터 한 바퀴 돌면서
/// 처음 만나는 ready를 고른다. 단순하고 공정하지만,
/// **마감이 임박한 스레드를 우대하지 않는다** - 그게 M4b의 숙제다.
fn pickNext() ?u8 {
    const now = time.millis();

    // 잠든 스레드 중 시간이 된 것들을 깨운다
    var i: u8 = 0;
    while (i < thread_count) : (i += 1) {
        if (threads[i].state == .sleeping and now >= threads[i].wake_at) {
            threads[i].state = .ready;
        }
    }

    // 현재 다음부터 순회 (기아 방지).
    // 유휴 스레드는 건너뛴다 - 진짜 할 일이 있는 스레드가 우선이다.
    var n: u8 = 1;
    while (n <= thread_count) : (n += 1) {
        const id = (current_id + n) % thread_count;
        const t = &threads[id];
        if (t.state == .ready and !t.is_idle) return id;
    }

    // 아무도 준비되지 않았으면 그때 유휴 스레드로
    n = 1;
    while (n <= thread_count) : (n += 1) {
        const id = (current_id + n) % thread_count;
        if (threads[id].state == .ready) return id;
    }
    return null;
}

/// CPU를 놓아준다. 다른 실행할 스레드가 없으면 그냥 돌아온다.
///
/// noinline: 이 함수 안에서 스택이 통째로 바뀐다. 호출자에 인라인되면
/// 호출자의 스택 프레임 가정이 깨진다.
pub noinline fn yield() void {
    const me = &threads[current_id];

    // 이번에 쓴 시간을 정산.
    //
    // 워밍업 구간을 제외하는 이유는 프로파일러와 같다 - 첫 전환들은
    // 캐시가 비어 있고 분기 예측도 학습 전이라 비정상적으로 느리다.
    // 그 값이 worst에 들어가면 통계가 영구히 오염된다.
    const now = time.micros();
    const used = now -| slice_start_us;
    if (!me.is_idle) {
        me.used_us += used;
        me.total_us += used;
        if (warmup == 0 and used > me.worst_us) me.worst_us = used;
    }

    if (!me.guardIntact()) {
        serial.print("\n!! stack overflow in thread '");
        serial.print(me.name);
        serial.println("'");
        arch.halt();
    }

    const next_id = pickNext() orelse {
        // 아무도 없으면 계속 나다
        slice_start_us = time.micros();
        return;
    };

    if (me.state == .running) me.state = .ready;
    threads[next_id].state = .running;

    if (warmup > 0) warmup -= 1;

    const prev_id = current_id;
    current_id = next_id;
    threads[next_id].switches += 1;
    slice_start_us = time.micros();

    context.switchTo(&threads[prev_id].rsp, threads[next_id].rsp);
    // 여기로 돌아왔다는 건 누군가 다시 나를 골랐다는 뜻이다.
    // 그 사이에 얼마나 흘렀는지 이 코드는 모른다.
}

/// 지정 시각까지 잔다. 그동안 다른 스레드가 CPU를 쓴다.
pub noinline fn sleepUntil(wake_ms: u64) void {
    const me = &threads[current_id];
    me.wake_at = wake_ms;
    me.state = .sleeping;

    while (time.millis() < wake_ms) {
        yield();
        // 실행할 스레드가 나뿐이면 yield가 즉시 돌아온다.
        // 그때는 CPU를 태우지 말고 다음 인터럽트까지 잔다.
        if (me.state == .sleeping and time.millis() < wake_ms) {
            arch.port.hlt();
        }
    }
    me.state = .running;
}

/// 프레임 경계. 모든 스레드의 예산 사용량을 초기화한다.
pub fn beginFrame() void {
    var i: u8 = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        if (t.budget_us > 0 and t.used_us > t.budget_us) t.overruns += 1;
        t.used_us = 0;
    }
}

pub fn report() void {
    serial.println("  id  name       switches   worst(us)  overruns");
    var i: u8 = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        serial.print("  ");
        serial.printDec(t.id);
        serial.print("   ");
        serial.print(t.name);
        var pad = if (t.name.len < 11) 11 - t.name.len else 1;
        while (pad > 0) : (pad -= 1) serial.putc(' ');
        printPadded(t.switches, 8);
        if (t.is_idle) {
            serial.print("           -");
            serial.print("         -");
        } else {
            printPadded(t.worst_us, 12);
            printPadded(t.overruns, 10);
        }
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
