//! M3 데모 - 힙 위에서 도는 파티클.
//!
//! 커널에 하드코딩된 임시 앱이다. M5에서 유저 모드 ELF 로더가 생기면
//! 이런 코드는 커널 밖으로 나간다. 그때까지의 시험대 역할.
//!
//! 이번 판의 목적은 **프리폴트 힙이 실제로 프레임을 지키는지** 보는 것이다.
//! 매 프레임 할당과 해제를 반복하면서 worst 프레임 시간을 관찰한다.

const std = @import("std");
const kernel = @import("kernel.zig");
const gfx = @import("framebuffer.zig");
const time = @import("time.zig");
const mem = @import("mem/mem.zig");
const arch = @import("arch/x86_64/arch.zig");
const serial = @import("serial.zig");

const kbd = arch.keyboard;
const Color = gfx.Color;

const bg: Color = .{ .r = 12, .g = 14, .b = 22 };
const accent: Color = .{ .r = 255, .g = 138, .b = 40 };
const dim: Color = .{ .r = 110, .g = 118, .b = 135 };
const good: Color = .{ .r = 120, .g = 220, .b = 150 };

/// 목표 프레임 시간. 60fps = 16.67ms인데 타이머가 1ms 해상도라
/// 16과 17이 섞인다. M4에서 고정밀 타이머로 옮기면 해결된다.
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

    // 힙에서 잡는 잔상 버퍼. 부팅 시 한 번.
    const trail = allocator.alloc(Point, trail_len) catch {
        kernel.panic("trail allocation failed");
    };
    for (trail) |*p| p.* = .{ .x = player.x, .y = player.y };
    var trail_head: usize = 0;

    serial.print("[+] trail buffer allocated (");
    serial.printDec(trail.len * @sizeOf(Point));
    serial.println(" bytes)");

    var frame: u64 = 0;
    var next_frame = time.millis();
    var worst_ms: u64 = 0;

    while (true) {
        const frame_start = time.millis();

        // ── update ──
        if (kbd.isDown(.escape)) {
            serial.println("=== esc pressed ===");
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

        // 매 프레임 할당/해제. 보통의 OS라면 여기서 페이지 폴트가
        // 튀어나와 프레임을 흔든다. 프리폴트 힙에서는 순수 포인터
        // 계산이라 worst가 흔들리지 않아야 한다.
        const scratch = allocator.alloc(u8, 4096) catch {
            kernel.panic("scratch allocation failed");
        };
        scratch[0] = @truncate(frame);
        allocator.free(scratch);

        // ── render ──
        canvas.clear(bg);
        canvas.drawBorder(8, accent);
        canvas.drawString(40, 32, kernel.name ++ " v" ++ kernel.version, accent, 3);
        canvas.drawString(40, 72, "paging + pre-faulted heap", dim, 2);

        var buf: [64]u8 = undefined;
        canvas.drawString(40, 108, stat(&buf, "frame  ", frame), dim, 2);
        canvas.drawString(40, 130, stat(&buf, "allocs ", mem.heap.alloc_count), dim, 2);
        canvas.drawString(40, 152, stat(&buf, "heap kb", mem.heap.bytes_in_use / 1024), dim, 2);
        canvas.drawString(40, 174, stat(&buf, "worst  ", worst_ms), if (worst_ms > frame_ms) accent else good, 2);

        // 잔상 - 오래된 것일수록 어둡게
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

        screen.present(canvas);

        // ── pace ──
        // 다음 프레임 시각을 "이번 프레임 시작 + 예산"으로 잡는다.
        // 실제 소요 시간을 더하면 오차가 누적되어 서서히 느려진다.
        next_frame += frame_ms;

        const elapsed = time.millis() - frame_start;
        if (frame > 60 and elapsed > worst_ms) worst_ms = elapsed; // 워밍업 제외

        time.sleepUntil(next_frame);
        frame += 1;
    }
}

/// 커널에는 std.fmt를 쓸 여유가 없으니 직접 만든다.
fn stat(buf: []u8, label: []const u8, value: u64) []const u8 {
    var i: usize = 0;
    for (label) |c| {
        buf[i] = c;
        i += 1;
    }
    if (value == 0) {
        buf[i] = '0';
        return buf[0 .. i + 1];
    }
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        digits[n] = '0' + @as(u8, @intCast(v % 10));
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        buf[i] = digits[n];
        i += 1;
    }
    return buf[0..i];
}
