//! Attract — M2a: 펌웨어 독립
//!
//! 여기서 성격이 바뀐다. exitBootServices()를 부르는 순간
//! 펌웨어의 서비스는 전부 사라지고, 이 커널이 기계의 유일한 주인이 된다.
//! 할당자도, 콘솔도, 워치독도 없다. 남는 건 우리가 만든 것뿐이다.
//!
//! 그래서 나가기 전에 필요한 것을 미리 챙기고,
//! 나간 직후에 GDT와 IDT부터 세운다.

const std = @import("std");
const uefi = std.os.uefi;

const serial = @import("serial.zig");
const gfx = @import("framebuffer.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const isr = @import("arch/x86_64/isr.zig");
const port = @import("arch/x86_64/port.zig");

const name = "Attract";
const version = "0.2.0";

const Color = gfx.Color;
const bg: Color = .{ .r = 12, .g = 14, .b = 22 };
const fg: Color = .{ .r = 230, .g = 232, .b = 240 };
const accent: Color = .{ .r = 255, .g = 138, .b = 40 };
const dim: Color = .{ .r = 120, .g = 128, .b = 145 };

/// 커널이 자체적으로 죽을 때. 예외 핸들러와 같은 곳으로 모인다.
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, _: ?usize) noreturn {
    serial.print("\n!! KERNEL PANIC: ");
    serial.println(msg);
    port.halt();
}

pub fn main() uefi.Status {
    serial.init();
    serial.print("\n");
    serial.println("=== " ++ name ++ " v" ++ version ++ " booting ===");

    const st = uefi.system_table;
    const bs = st.boot_services orelse {
        serial.println("[!] boot services unavailable");
        return .load_error;
    };

    if (bs.setWatchdogTimer(0, 0, null)) |_| {
        serial.println("[+] watchdog disabled");
    } else |_| {}

    // ── 1. 나가기 전에 챙길 것: 프레임버퍼 ──────────────────────────
    // GOP 프로토콜 자체는 exit 후 쓸 수 없지만, 프레임버퍼의 물리 주소는
    // 그대로 유효하다. 그래서 주소와 형식만 미리 복사해 둔다.
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null) orelse {
        serial.println("[!] GOP not found");
        return .unsupported;
    };

    const screen = gfx.Framebuffer.init(gop) catch |err| {
        serial.print("[!] framebuffer init failed: ");
        serial.println(@errorName(err));
        return .unsupported;
    };
    serial.print("[+] framebuffer ");
    serial.printDec(screen.width);
    serial.print("x");
    serial.printDec(screen.height);
    serial.print(" @ ");
    serial.printHex(screen.base);
    serial.print("\n");

    // ── 2. 백버퍼도 지금 할당한다 ──────────────────────────────────
    // 펌웨어 할당자를 쓸 수 있는 마지막 기회다.
    // 여기서 받은 메모리는 loader_data로 표시되어 exit 후에도 우리 것이다.
    const back = uefi.pool_allocator.alloc(u32, screen.pixelCount()) catch {
        serial.println("[!] back buffer allocation failed");
        return .out_of_resources;
    };
    const canvas = screen.canvas(back);
    serial.print("[+] back buffer ");
    serial.printDec(back.len * 4 / 1024);
    serial.println(" KiB");

    // ── 3. exitBootServices ────────────────────────────────────────
    exitBootServices(bs) catch |err| {
        serial.print("[!] exitBootServices failed: ");
        serial.println(@errorName(err));
        return .load_error;
    };

    // 여기서부터 펌웨어는 없다. bs, con_out 등은 전부 무효.
    // 스펙이 요구하는 대로 포인터를 지운다.
    st.console_in_handle = null;
    st.con_in = null;
    st.console_out_handle = null;
    st.con_out = null;
    st.standard_error_handle = null;
    st.std_err = null;
    st.boot_services = null;

    serial.println("[+] exited boot services - we own the machine now");

    // ── 4. 우리 GDT / IDT ──────────────────────────────────────────
    gdt.load();
    serial.println("[+] gdt loaded");

    isr.install();
    idt.load();
    serial.println("[+] idt loaded (32 exception handlers)");

    // ── 5. 자가 진단 ───────────────────────────────────────────────
    // int3를 일부러 실행한다. 덤프가 찍히고 **정상 복귀**하면
    // 푸시/팝 순서, 스택 정렬, iretq가 전부 맞다는 뜻이다.
    serial.println("[*] self-test: triggering int3 ...");
    asm volatile ("int3");
    serial.println("[+] returned from exception - handler path verified");

    // ── 6. 화면 ────────────────────────────────────────────────────
    canvas.clear(bg);
    canvas.drawBorder(8, accent);
    canvas.drawString(80, 60, name ++ " v" ++ version, accent, 5);
    canvas.drawString(80, 130,
        \\firmware exited. kernel is on its own.
    , dim, 2);
    canvas.drawString(80, 180,
        \\M0  serial + uefi boot ......... done
        \\M1  framebuffer + text ......... done
        \\M2a exit boot services ......... done
        \\    gdt / idt / exceptions ..... done
        \\M2b timer + input .............. next
    , fg, 2);
    screen.present(canvas);

    serial.println("=== M2a complete. halting ===");

    // 아직 인터럽트를 켜지 않는다. 핸들러가 예외용밖에 없어서
    // 타이머가 들어오면 갈 곳이 없다. M2b에서 PIC를 세운 뒤에 켠다.
    port.halt();
}

/// 메모리 맵을 얻고 펌웨어에서 나간다.
///
/// 까다로운 점: getMemoryMap이 돌려주는 map_key는 "그 순간의 메모리 상태"를
/// 가리킨다. 그 뒤에 할당이 한 번이라도 일어나면 키가 무효가 되고
/// exitBootServices가 거부한다. 그런데 맵을 담을 버퍼를 할당하는 것 자체가
/// 메모리 상태를 바꾼다. 그래서 실패하면 다시 얻어 재시도하는 구조가 된다.
fn exitBootServices(bs: *uefi.tables.BootServices) !void {
    const info = try bs.getMemoryMapInfo();

    // 여유분: 버퍼를 할당하는 행위 자체가 맵을 쪼갤 수 있어서
    // 디스크립터가 몇 개 늘어난다.
    const size = (info.len + 8) * info.descriptor_size;
    const buffer = try bs.allocatePool(.loader_data, size);

    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        const map = bs.getMemoryMap(@alignCast(buffer)) catch |err| {
            if (err == error.BufferTooSmall) return err;
            continue;
        };

        if (attempt == 0) {
            serial.print("[+] memory map: ");
            serial.printDec(map.info.len);
            serial.println(" descriptors");
        }

        bs.exitBootServices(uefi.handle, map.info.key) catch continue;
        return; // 성공
    }
    return error.ExitFailed;
}
