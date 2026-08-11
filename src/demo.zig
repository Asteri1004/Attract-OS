//! M2b 데모 — 움직이는 사각형.
//!
//! 커널에 하드코딩된 임시 앱이다. M5에서 유저 모드 ELF 로더가 생기면
//! 이런 코드는 커널 밖으로 나간다. 그때까지의 시험대 역할.

const kernel = @import("kernel.zig");
const gfx = @import("framebuffer.zig");
const time = @import("time.zig");
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

const Player = struct {
    x: i32,
    y: i32,
    size: i32 = 48,
    speed: i32 = 6,
};

pub fn run() noreturn {
    const screen = kernel.screen;
    const canvas = kernel.canvas;

    var player: Player = .{
        .x = @intCast(screen.width / 2),
        .y = @intCast(screen.height / 2),
    };

    var frame: u64 = 0;
    var next_frame = time.millis();
    var worst_ms: u64 = 0;

    while (true) {
        const frame_start = time.millis();

        // ── update ──
        if (kbd.isDown(.escape)) {
            serial.println("=== esc pressed, halting ===");
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

        // ── render ──
        canvas.clear(bg);
        canvas.drawBorder(8, accent);
        canvas.drawString(40, 32, kernel.name ++ " v" ++ kernel.version, accent, 3);
        canvas.drawString(40, 72, "arrow keys / wasd to move   esc to halt", dim, 2);

        var buf: [64]u8 = undefined;
        canvas.drawString(40, 110, stat(&buf, "frame ", frame), dim, 2);
        canvas.drawString(40, 132, stat(&buf, "ms    ", frame_start), dim, 2);
        canvas.drawString(40, 154, stat(&buf, "worst ", worst_ms), if (worst_ms > frame_ms) accent else good, 2);

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

/// 커널에는 std.fmt를 쓸 할당자가 없으니 직접 만든다.
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
