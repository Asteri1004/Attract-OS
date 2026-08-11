//! Attract — M1: 프레임버퍼 + 텍스트 + 더블 버퍼링
//!
//! M0에서 "볼 수 있는 눈"(시리얼)을 만들었고,
//! 이제 화면을 직접 통제한다. 백버퍼에 그리고 한 번에 화면으로 옮긴다.

const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("serial.zig");
const gfx = @import("framebuffer.zig");

const name = "Attract";
const version = "0.1.0";

const Color = gfx.Color;

const bg: Color = .{ .r = 12, .g = 14, .b = 22 };
const fg: Color = .{ .r = 230, .g = 232, .b = 240 };
const accent: Color = .{ .r = 255, .g = 138, .b = 40 };

fn utf16(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub fn main() uefi.Status {
    // ── 1. 시리얼부터. 이게 없으면 이후 전부 장님 코딩 ────────────────
    serial.init();
    serial.print("\n");
    serial.println("=== " ++ name ++ " v" ++ version ++ " booting ===");

    const st = uefi.system_table;

    const bs = st.boot_services orelse {
        serial.println("[!] boot services unavailable");
        return .load_error;
    };
    serial.println("[+] boot services ok");

    // ── 2. 워치독 해제 (안 하면 5분 뒤 강제 리부트) ──────────────────
    if (bs.setWatchdogTimer(0, 0, null)) |_| {
        serial.println("[+] watchdog disabled");
    } else |_| {
        serial.println("[!] watchdog disable failed (continuing)");
    }

    // ── 3. GOP 획득 ────────────────────────────────────────────────
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null) orelse {
        serial.println("[!] GOP not found");
        return .unsupported;
    };

    const screen = gfx.Framebuffer.init(gop) catch |err| {
        serial.print("[!] framebuffer init failed: ");
        serial.println(@errorName(err));
        return .unsupported;
    };

    serial.println("[+] GOP found");
    serial.print("    resolution : ");
    serial.printDec(screen.width);
    serial.print(" x ");
    serial.printDec(screen.height);
    serial.print("\n");
    serial.print("    stride     : ");
    serial.printDec(screen.stride);
    serial.println(" px");
    serial.print("    fb base    : ");
    serial.printHex(screen.base);
    serial.print("\n");

    // ── 4. 백버퍼 할당 ─────────────────────────────────────────────
    // 아직 UEFI 앱이라 펌웨어의 풀 할당자를 쓸 수 있다.
    // M3에서 자체 할당자를 만들면 이 부분을 교체한다.
    const back = uefi.pool_allocator.alloc(u32, screen.pixelCount()) catch {
        serial.println("[!] back buffer allocation failed");
        return .out_of_resources;
    };
    const canvas = screen.canvas(back);

    serial.print("[+] back buffer ");
    serial.printDec(back.len * 4 / 1024);
    serial.println(" KiB allocated");

    // ── 5. 그리기 ──────────────────────────────────────────────────
    canvas.gradient();
    canvas.drawBorder(12, accent);

    // 좌상단 기준점 — 원점이 어디인지, 좌표가 밀리지 않는지 확인용
    canvas.fillRect(28, 28, 40, 40, bg);

    canvas.drawString(96, 60, name ++ " v" ++ version, fg, 5);
    canvas.drawString(96, 130,
        \\a bare-metal OS for games
        \\
        \\M0  serial + uefi boot ......... done
        \\M1  framebuffer + text ......... done
        \\M2  timer + input .............. next
    , fg, 2);

    serial.println("[+] canvas drawn");

    // ── 6. 화면으로 ────────────────────────────────────────────────
    screen.present(canvas);
    serial.println("[+] presented");

    // UEFI 콘솔은 이제 쓰지 않는다. 화면은 우리 것이다.
    _ = st.con_out;

    serial.println("=== M1 complete. halting ===");

    // hlt로 대기. 빈 while(true)와 달리 CPU를 태우지 않는다.
    while (true) asm volatile ("hlt");
}
