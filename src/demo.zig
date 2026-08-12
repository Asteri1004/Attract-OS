//! 렌더링 프로파일 데모.
//!
//! 커널에 하드코딩된 임시 앱이다. M5에서 유저 모드 ELF 로더가 생기면
//! 이런 코드는 커널 밖으로 나간다.
//!
//! 이번 판의 목적은 **프레임 예산이 어디로 새는지 보는 것**이다.
//! M3까지의 측정은 "13ms"라는 숫자 하나뿐이었는데, 그걸로는
//! 무엇을 고쳐야 할지 알 수 없다. 구간별로 쪼개서 본다.

const std = @import("std");
const kernel = @import("kernel.zig");
const gfx = @import("framebuffer.zig");
const time = @import("time.zig");
const mem = @import("mem/mem.zig");
const prof = @import("profile.zig");
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

const trail_len = 24;

const Player = struct {
    x: i32,
    y: i32,
    size: i32 = 40,
    speed: i32 = 7,
};

const Point = struct { x: i32, y: i32 };

pub fn run() noreturn {
    const screen = kernel.screen;
    const canvas = kernel.canvas;
    const allocator = mem.heap.allocator();

    var player: Player = .{
        .x = @intCast(screen.width / 2),
        .y = @intCast(screen.height / 2),
    };

    const trail = allocator.alloc(Point, trail_len) catch {
        kernel.panic("trail allocation failed");
    };
    for (trail) |*p| p.* = .{ .x = player.x, .y = player.y };
    var trail_head: usize = 0;

    var frame: u64 = 0;
    var next_frame = time.millis();
    var worst_frame_us: u64 = 0;

    // 실측 FPS. 프로파일러가 아니라 PIT로 직접 센다.
    // 두 시계가 어긋나 있으면 여기서 드러난다.
    var fps: u64 = 0;
    var fps_frames: u64 = 0;
    var fps_mark = time.millis();

    while (true) {
        prof.begin(.work);

        // ── update ──
        prof.begin(.update);
        {
            if (kbd.isDown(.escape)) {
                serial.println("\n=== esc pressed ===");
                serial.println("[*] frame profile:");
                prof.report();
                mem.heap.report();
                arch.halt();
            }

            const max_x: i32 = @as(i32, @intCast(screen.width)) - player.size - 16;
            const max_y: i32 = @as(i32, @intCast(screen.height)) - player.size - 16;

            if (kbd.isDown(.left) or kbd.isDown(.a)) player.x -= player.speed;
            if (kbd.isDown(.right) or kbd.isDown(.d)) player.x += player.speed;
            if (kbd.isDown(.up) or kbd.isDown(.w)) player.y -= player.speed;
            if (kbd.isDown(.down) or kbd.isDown(.s)) player.y += player.speed;

            player.x = @max(16, @min(max_x, player.x));
            player.y = @max(16, @min(max_y, player.y));

            trail[trail_head] = .{ .x = player.x, .y = player.y };
            trail_head = (trail_head + 1) % trail_len;

            // 매 프레임 할당/해제. 프리폴트 힙이 일하는지 확인용.
            const scratch = allocator.alloc(u8, 4096) catch {
                kernel.panic("scratch allocation failed");
            };
            scratch[0] = @truncate(frame);
            allocator.free(scratch);
        }
        prof.end(.update);

        // ── clear ──
        prof.begin(.clear);
        canvas.clear(bg);
        prof.end(.clear);

        // ── draw ──
        prof.begin(.draw);
        {
            canvas.drawBorder(8, accent);
            canvas.drawString(40, 32, kernel.name ++ " v" ++ kernel.version, accent, 3);

            var buf: [80]u8 = undefined;
            const lines = [_]struct { label: []const u8, slot: ?prof.Slot }{
                .{ .label = "update ", .slot = .update },
                .{ .label = "clear  ", .slot = .clear },
                .{ .label = "draw   ", .slot = .draw },
                .{ .label = "present", .slot = .present },
            };

            var y: u32 = 80;
            canvas.drawString(40, y, "us     last   worst", dim, 2);
            y += 24;

            for (lines) |line| {
                const slot = line.slot.?;
                const last = prof.lastMicros(slot);
                const worst = prof.worstMicros(slot);
                const c: Color = if (worst > budget_us / 2) warn else dim;
                canvas.drawString(40, y, twoCol(&buf, line.label, last, worst), c, 2);
                y += 22;
            }

            y += 12;
            const over = worst_frame_us > budget_us;
            canvas.drawString(40, y, twoCol(&buf, "work   ", prof.lastMicros(.work), worst_frame_us), if (over) warn else good, 2);

            // 실측 FPS. 60에서 크게 벗어나면 페이싱이나 시계가 잘못된 것.
            y += 24;
            const fps_ok = fps >= 55 and fps <= 65;
            canvas.drawString(40, y, twoCol(&buf, "fps    ", fps, 60), if (fps_ok) good else warn, 2);

            // 예산의 몇 %를 썼는가. 스케줄러에게 남는 시간이 이 나머지다.
            y += 22;
            const pct = worst_frame_us * 100 / budget_us;
            canvas.drawString(40, y, twoCol(&buf, "budget%", pct, 100), if (pct > 80) warn else good, 2);

            // 예산 막대. 최악 프레임이 예산의 몇 %인지 한눈에.
            const bar_w: u32 = 400;
            const filled: u32 = @intCast(@min(bar_w, worst_frame_us * bar_w / budget_us));
            canvas.fillRect(40, y + 30, bar_w, 12, .{ .r = 30, .g = 34, .b = 44 });
            canvas.fillRect(40, y + 30, filled, 12, if (over) warn else good);

            // 잔상
            var i: usize = 0;
            while (i < trail_len) : (i += 1) {
                const idx = (trail_head + i) % trail_len;
                const age = @as(u32, @intCast(i));
                const shade: u8 = @intCast(30 + age * 3);
                const s: i32 = 8 + @as(i32, @intCast(age / 3));
                canvas.fillRect(
                    @intCast(trail[idx].x + @divTrunc(player.size - s, 2)),
                    @intCast(trail[idx].y + @divTrunc(player.size - s, 2)),
                    @intCast(s),
                    @intCast(s),
                    .{ .r = shade / 2, .g = shade, .b = shade / 2 + 20 },
                );
            }

            canvas.fillRect(
                @intCast(player.x),
                @intCast(player.y),
                @intCast(player.size),
                @intCast(player.size),
                good,
            );
        }
        prof.end(.draw);

        // ── present ──
        prof.begin(.present);
        screen.present(canvas);
        prof.end(.present);

        prof.end(.work);

        // ── pace ──
        // 여기는 hlt로 자는 구간이라 TSC로 재지 않는다.
        // 잰다 해도 CPU가 멈춰 있는 동안의 사이클은 세어지지 않는다.
        const work_us = prof.lastMicros(.work);
        if (frame > 60 and work_us > worst_frame_us) worst_frame_us = work_us;

        next_frame += frame_ms;
        time.sleepUntil(next_frame);

        prof.frameEnd();
        frame += 1;

        // 1초마다 실측 FPS 갱신
        fps_frames += 1;
        const now_ms = time.millis();
        if (now_ms - fps_mark >= 1000) {
            fps = fps_frames * 1000 / (now_ms - fps_mark);
            fps_frames = 0;
            fps_mark = now_ms;
        }

        // 5초마다 시리얼로도 남긴다. 화면을 못 볼 때를 대비.
        if (frame % 300 == 0) {
            serial.print("[frame ");
            serial.printDec(frame);
            serial.print("]  measured fps: ");
            serial.printDec(fps);
            serial.print("\n");
            prof.report();
        }
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
