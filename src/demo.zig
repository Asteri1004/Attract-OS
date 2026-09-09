//! M4a 데모 - 두 스레드가 협력해서 한 프레임을 만든다.
//!
//! 게임에서 흔한 구조를 커널 스레드로 나눠본 것이다:
//!
//!   logic  - 시뮬레이션. 프레임마다 파티클을 갱신한다
//!   render - 그리기. 백버퍼를 채우고 화면에 올린다
//!
//! 지금은 협력적이라 서로 `yield()`를 불러야 넘어간다.
//! M4b에서 타이머가 강제로 뺏게 되면, 예산을 넘긴 스레드는
//! 말 그대로 문장 중간에 끊긴다.
//!
//! 두 스레드가 같은 데이터를 만지는데 락이 없는 이유:
//! 단일 코어이고 전환 지점이 명시되어 있어서, `yield()`를 부르지
//! 않는 구간은 원자적으로 실행된다. M4b에서 선점이 들어오면
//! 이 가정이 깨지므로 그때 다시 봐야 한다.

const std = @import("std");
const kernel = @import("kernel.zig");
const gfx = @import("framebuffer.zig");
const time = @import("time.zig");
const mem = @import("mem/mem.zig");
const prof = @import("profile.zig");
const sched = @import("sched.zig");
const arch = @import("arch/x86_64/arch.zig");
const serial = @import("serial.zig");

const kbd = arch.keyboard;
const Color = gfx.Color;

const bg: Color = .{ .r = 12, .g = 14, .b = 22 };
const accent: Color = .{ .r = 255, .g = 138, .b = 40 };
const dim: Color = .{ .r = 110, .g = 118, .b = 135 };
const good: Color = .{ .r = 120, .g = 220, .b = 150 };
const warn: Color = .{ .r = 255, .g = 90, .b = 90 };

/// 프레임 예산 (마이크로초). 60fps = 16667us.
const budget_us: u64 = 16667;
const frame_ms: u64 = 16;

/// 스레드별 예산. 합이 전체 예산보다 작아야 여유가 남는다.
const logic_budget: u64 = 4000;
const render_budget: u64 = 10000;

/// 마감까지 남겨둘 여유. **작을수록 급하다.**
///
/// render는 프레임 끝에 반드시 화면이 나가야 하므로 여유가 없다.
/// logic은 render보다 먼저 끝나야 하니 마감을 더 이르게 잡는다.
const logic_slack: u64 = 12000; // 프레임 시작 후 ~4.7ms 안에
const render_slack: u64 = 1000; // 프레임 끝 1ms 전까지

const particle_count = 220;
const trail_len = 24;

// ─────────────────────────────────────────────────────────────────────
// 공유 상태
// ─────────────────────────────────────────────────────────────────────

const Particle = struct {
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    life: i32,
};

const World = struct {
    px: i32 = 0,
    py: i32 = 0,
    size: i32 = 40,
    speed: i32 = 7,

    particles: []Particle = &.{},
    trail: []Point = &.{},
    trail_head: usize = 0,

    frame: u64 = 0,
    fps: u64 = 0,
    running: bool = true,

    /// 인위적 부하. 스페이스로 켜고 끈다.
    ///
    /// 선점이 실제로 작동하는지 보려면 예산을 넘기는 스레드가 필요하다.
    /// 평소에는 logic이 2us밖에 안 써서 선점될 일이 없다.
    stress: bool = false,
    stress_edge: bool = false,

    /// 아직 화면에 반영되지 않은 입력의 시각 (us). 0이면 없음.
    pending_input_us: u64 = 0,
    /// 마지막으로 측정된 입력 -> 화면 지연
    input_latency_us: u64 = 0,
    worst_latency_us: u64 = 0,
};

const Point = struct { x: i32, y: i32 };

var world: World = .{};

/// 아주 단순한 난수. 결정적이라 재현이 쉽다.
var rng_state: u32 = 0x1234_5678;
fn rand() u32 {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

fn randRange(lo: i32, hi: i32) i32 {
    const span: u32 = @intCast(hi - lo + 1);
    return lo + @as(i32, @intCast(rand() % span));
}

// ─────────────────────────────────────────────────────────────────────
// logic 스레드
// ─────────────────────────────────────────────────────────────────────

fn logicThread() callconv(.c) noreturn {
    while (true) {
        prof.begin(.update);

        // 아직 화면에 안 나간 입력이 있으면 시각을 물려받는다.
        // render가 present 직후에 이 값과 대조해 지연을 잰다.
        if (kbd.takePendingPress()) |t| world.pending_input_us = t;

        // 스페이스로 부하 토글. 눌린 순간만 반응하도록 경계를 검사한다.
        const space_now = kbd.isDown(.space);
        if (space_now and !world.stress_edge) world.stress = !world.stress;
        world.stress_edge = space_now;

        if (kbd.isDown(.escape)) world.running = false;

        const screen = kernel.screen;
        const max_x: i32 = @as(i32, @intCast(screen.width)) - world.size - 16;
        const max_y: i32 = @as(i32, @intCast(screen.height)) - world.size - 16;

        if (kbd.isDown(.left) or kbd.isDown(.a)) world.px -= world.speed;
        if (kbd.isDown(.right) or kbd.isDown(.d)) world.px += world.speed;
        if (kbd.isDown(.up) or kbd.isDown(.w)) world.py -= world.speed;
        if (kbd.isDown(.down) or kbd.isDown(.s)) world.py += world.speed;

        world.px = @max(16, @min(max_x, world.px));
        world.py = @max(16, @min(max_y, world.py));

        world.trail[world.trail_head] = .{ .x = world.px, .y = world.py };
        world.trail_head = (world.trail_head + 1) % trail_len;

        // 파티클 시뮬레이션. 죽은 것은 플레이어 위치에서 되살린다.
        for (world.particles) |*p| {
            p.x += p.vx;
            p.y += p.vy;
            p.vy += 1; // 중력
            p.life -= 1;

            if (p.life <= 0 or p.y > max_y) {
                p.* = .{
                    .x = world.px + @divTrunc(world.size, 2),
                    .y = world.py + @divTrunc(world.size, 2),
                    .vx = randRange(-6, 6),
                    .vy = randRange(-14, -4),
                    .life = randRange(30, 90),
                };
            }
        }

        // ── 인위적 부하 ──
        //
        // 예산(4000us)을 훌쩍 넘기는 시간을 일부러 태운다.
        //
        // 산술 루프를 돌리는 방식은 쓸 수 없다. `junk = junk*a + b` 같은
        // 선형 합동은 LLVM이 닫힌 형태로 계산해버려서 300만 번 반복이
        // 순식간에 끝난다(실제로 겪었다: logic worst 14us).
        // 시계를 읽으며 도는 건 최적화할 수 없다 - rdtsc는 부작용이 있는
        // 명령이라 컴파일러가 건드리지 못한다.
        //
        // 선점이 없다면 이 루프가 끝날 때까지 render가 실행되지 못해
        // 프레임이 통째로 밀린다. 선점이 있다면 예산을 넘긴 순간
        // **이 루프 한복판에서** 끊기고 render로 넘어간다.
        if (world.stress) {
            const until = time.micros() + 12_000; // 예산의 3배
            while (time.micros() < until) {}
        }

        prof.end(.update);

        // 이번 프레임 몫 끝. 다음 프레임까지 잠든다.
        // M4a에서는 여기서 yield()만 불러서 CPU가 남으면 계속 돌았다
        // (프레임당 14회). 이제 스케줄러가 경계를 관리한다.
        sched.endFrame();
    }
}

// ─────────────────────────────────────────────────────────────────────
// render 스레드
// ─────────────────────────────────────────────────────────────────────

fn renderThread() callconv(.c) noreturn {
    const screen = kernel.screen;
    const canvas = kernel.canvas;

    var next_frame = time.millis();
    var worst_work_us: u64 = 0;
    var fps_frames: u64 = 0;
    var fps_mark = time.millis();

    while (true) {
        prof.begin(.work);

        prof.begin(.clear);
        canvas.clear(bg);
        prof.end(.clear);

        prof.begin(.draw);
        {
            canvas.drawBorder(8, accent);
            canvas.drawString(40, 32, kernel.name ++ " v" ++ kernel.version, accent, 3);

            var buf: [80]u8 = undefined;
            var y: u32 = 80;
            canvas.drawString(40, y, "us      last    worst", dim, 2);
            y += 24;

            const slots = [_]struct { label: []const u8, slot: prof.Slot }{
                .{ .label = "update  ", .slot = .update },
                .{ .label = "clear   ", .slot = .clear },
                .{ .label = "draw    ", .slot = .draw },
                .{ .label = "present ", .slot = .present },
            };
            for (slots) |s| {
                canvas.drawString(40, y, twoCol(&buf, s.label, prof.lastMicros(s.slot), prof.worstMicros(s.slot)), dim, 2);
                y += 22;
            }

            y += 10;
            const over = worst_work_us > budget_us;
            canvas.drawString(40, y, twoCol(&buf, "work    ", prof.lastMicros(.work), worst_work_us), if (over) warn else good, 2);

            y += 22;
            const fps_ok = world.fps >= 55 and world.fps <= 65;
            canvas.drawString(40, y, twoCol(&buf, "fps     ", world.fps, 60), if (fps_ok) good else warn, 2);

            // 스케줄러 계측. onTick이 실제로 불리는지 확인용.
            y += 22;
            canvas.drawString(40, y, twoCol(&buf, "ticks   ", sched.tick_count, sched.preempt_checks), dim, 2);

            // 부하 상태
            y += 22;
            canvas.drawString(
                40,
                y,
                if (world.stress) "STRESS ON  (space to stop)" else "space: stress test",
                if (world.stress) warn else dim,
                2,
            );

            // 입력 -> 화면 지연. 이 커널이 존재하는 이유다.
            y += 22;
            const lat_ok = world.worst_latency_us < budget_us * 2;
            canvas.drawString(40, y, twoCol(&buf, "input ms", world.input_latency_us / 1000, world.worst_latency_us / 1000), if (lat_ok) good else warn, 2);

            // 스레드별 최악 실행 시간과 예산
            y += 32;
            canvas.drawString(40, y, "thread   worst budget preempt", dim, 2);
            y += 24;
            var t: u8 = 0;
            while (t < sched.count()) : (t += 1) {
                const th = sched.get(t);
                if (th.is_idle) continue; // 유휴 시간은 CPU 사용이 아니다
                const c: Color = if (th.overruns > 0) warn else dim;
                canvas.drawString(40, y, thread_line(&buf, th), c, 2);
                y += 22;
            }

            // 파티클
            for (world.particles) |p| {
                if (p.x < 0 or p.y < 0) continue;
                const heat: u8 = @intCast(@min(255, @as(u32, @intCast(@max(0, p.life))) * 3));
                canvas.fillRect(
                    @intCast(p.x),
                    @intCast(p.y),
                    4,
                    4,
                    .{ .r = 255, .g = heat, .b = heat / 3 },
                );
            }

            // 잔상
            var i: usize = 0;
            while (i < trail_len) : (i += 1) {
                const idx = (world.trail_head + i) % trail_len;
                const age: u32 = @intCast(i);
                const shade: u8 = @intCast(30 + age * 3);
                const s: i32 = 8 + @as(i32, @intCast(age / 3));
                canvas.fillRect(
                    @intCast(world.trail[idx].x + @divTrunc(world.size - s, 2)),
                    @intCast(world.trail[idx].y + @divTrunc(world.size - s, 2)),
                    @intCast(s),
                    @intCast(s),
                    .{ .r = shade / 2, .g = shade, .b = shade / 2 + 20 },
                );
            }

            canvas.fillRect(
                @intCast(world.px),
                @intCast(world.py),
                @intCast(world.size),
                @intCast(world.size),
                good,
            );
        }
        prof.end(.draw);

        prof.begin(.present);
        screen.present(canvas);
        prof.end(.present);

        prof.end(.work);

        // ── 입력 -> 화면 지연 ──
        // 키가 눌린 순간(인터럽트에서 기록)부터 그 결과가 화면에
        // 나간 지금까지. 사람이 실제로 체감하는 값이다.
        if (world.pending_input_us > 0) {
            const latency = time.micros() -| world.pending_input_us;
            world.input_latency_us = latency;
            if (world.frame > 60 and latency > world.worst_latency_us) {
                world.worst_latency_us = latency;
            }
            world.pending_input_us = 0;
        }

        const work = prof.lastMicros(.work);
        if (world.frame > 60 and work > worst_work_us) worst_work_us = work;

        prof.frameEnd();
        world.frame += 1;
        fps_frames += 1;

        const now_ms = time.millis();
        if (now_ms - fps_mark >= 1000) {
            world.fps = fps_frames * 1000 / (now_ms - fps_mark);
            fps_frames = 0;
            fps_mark = now_ms;
        }

        if (!world.running) {
            serial.println("\n=== esc pressed ===");
            serial.println("[*] frame profile:");
            prof.report();
            serial.println("[*] threads:");
            sched.report();
            mem.heap.report();
            arch.halt();
        }

        if (world.frame % 300 == 0) {
            serial.print("[frame ");
            serial.printDec(world.frame);
            serial.print("]  fps ");
            serial.printDec(world.fps);
            serial.print("\n");
            sched.report();
        }

        // 프레임 경계.
        //
        // render는 프레임 마스터라 endFrame()을 부르지 않는다.
        // 부르면 frame_done이 되어 스케줄에서 빠지는데, 잠든 스레드를
        // 깨울 advanceFrame()을 부를 사람이 자기 자신이라 교착에 빠진다.
        // 대신 sleepUntil로 대기한다 - 이건 시각이 되면 스케줄러가 깨운다.
        next_frame += frame_ms;
        sched.sleepUntil(next_frame);
        sched.advanceFrame();
    }
}

// ─────────────────────────────────────────────────────────────────────

pub fn run() noreturn {
    const allocator = mem.heap.allocator();
    const screen = kernel.screen;

    world.px = @intCast(screen.width / 2);
    world.py = @intCast(screen.height / 2);

    world.trail = allocator.alloc(Point, trail_len) catch
        kernel.panic("trail allocation failed");
    for (world.trail) |*p| p.* = .{ .x = world.px, .y = world.py };

    world.particles = allocator.alloc(Particle, particle_count) catch
        kernel.panic("particle allocation failed");
    for (world.particles) |*p| p.* = .{ .x = -1, .y = -1, .vx = 0, .vy = 0, .life = 0 };

    sched.init(budget_us);

    // 타이머가 매 틱마다 예산을 감시하게 한다.
    time.setTickHook(sched.onTick);

    _ = sched.spawn("logic", logicThread, sched.default_stack_size, logic_budget, logic_slack) catch
        kernel.panic("cannot spawn logic thread");
    _ = sched.spawn("render", renderThread, sched.default_stack_size, render_budget, render_slack) catch
        kernel.panic("cannot spawn render thread");

    serial.println("=== scheduler running ===");

    // main 스레드는 이제 할 일이 없다. 계속 양보하면서
    // 아무도 준비되지 않았을 때만 CPU를 재운다.
    while (true) {
        sched.yield();
        arch.port.hlt();
    }
}

/// "label  1234   5678" 형태로 두 값을 한 줄에.
fn twoCol(buf: []u8, label: []const u8, a: u64, b: u64) []const u8 {
    var i: usize = 0;
    for (label) |c| {
        buf[i] = c;
        i += 1;
    }
    i = writePadded(buf, i, a, 7);
    i = writePadded(buf, i, b, 8);
    return buf[0..i];
}

fn thread_line(buf: []u8, t: *const sched.Thread) []const u8 {
    var i: usize = 0;
    for (t.name) |c| {
        buf[i] = c;
        i += 1;
    }
    while (i < 9) : (i += 1) buf[i] = ' ';
    i = writePadded(buf, i, t.worst_us, 6);
    i = writePadded(buf, i, t.budget_us, 7);
    i = writePadded(buf, i, t.preemptions, 6);
    return buf[0..i];
}

fn writePadded(buf: []u8, start: usize, value: u64, width: usize) usize {
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    if (v == 0) {
        digits[0] = '0';
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[n] = '0' + @as(u8, @intCast(v % 10));
            n += 1;
        }
    }
    var i = start;
    var pad = if (width > n) width - n else 0;
    while (pad > 0) : (pad -= 1) {
        buf[i] = ' ';
        i += 1;
    }
    while (n > 0) {
        n -= 1;
        buf[i] = digits[n];
        i += 1;
    }
    return i;
}
