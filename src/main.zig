//! Attract - 부팅 진입점.
//!
//! 이 파일은 **부팅 순서만** 다룬다. 실제 일은 각 모듈이 한다.
//! 순서 자체가 이 커널의 설계 요약이므로, 읽으면 전체 그림이 보이도록 유지한다.

const std = @import("std");
const uefi = std.os.uefi;

const kernel = @import("kernel.zig");
const serial = @import("serial.zig");
const gfx = @import("framebuffer.zig");
const time = @import("time.zig");
const demo = @import("demo.zig");
const mem = @import("mem/mem.zig");
const arch = @import("arch/x86_64/arch.zig");

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        kernel.panic(msg);
    }
}.f);

pub fn main() uefi.Status {
    // ── 1. 눈부터 뜬다 ─────────────────────────────────────────────
    // 커널에는 printf가 없다. 이게 없으면 이후 전부 장님 코딩.
    serial.init();
    serial.print("\n");
    serial.println("=== " ++ kernel.name ++ " v" ++ kernel.version ++ " booting ===");

    const st = uefi.system_table;
    const bs = st.boot_services orelse {
        serial.println("[!] boot services unavailable");
        return .load_error;
    };

    // 안 하면 펌웨어가 5분 뒤 시스템을 리부트한다.
    if (bs.setWatchdogTimer(0, 0, null)) |_| {
        serial.println("[+] watchdog disabled");
    } else |_| {}

    // ── 2. 펌웨어를 떠나기 전에 챙길 것 ─────────────────────────────
    setupGraphics(bs) catch |err| {
        serial.print("[!] graphics setup failed: ");
        serial.println(@errorName(err));
        return .unsupported;
    };

    // ── 3. 독립 ────────────────────────────────────────────────────
    // 메모리 맵은 버리지 않는다. 물리 할당자를 세우는 데 필요하다.
    // 맵이 담긴 버퍼는 loader_data라 exit 이후에도 유효하다.
    const map = exitBootServices(bs) catch |err| {
        serial.print("[!] exitBootServices failed: ");
        serial.println(@errorName(err));
        return .load_error;
    };
    clearFirmwarePointers(st);
    serial.println("[+] exited boot services - we own the machine now");

    // ── 4. CPU를 커널 통제하에 ─────────────────────────────────────
    // 메모리보다 먼저 하는 이유: 페이지 테이블을 만지다 실수하면
    // 페이지 폴트가 나는데, IDT가 없으면 원인 없이 리부트된다.
    arch.init();
    serial.println("[+] gdt / idt / pic ready");

    // ── 5. 메모리 ──────────────────────────────────────────────────
    mem.init(map, kernel.screen.base, kernel.screen.byteSize()) catch |err| {
        serial.print("[!] memory init failed: ");
        serial.println(@errorName(err));
        return .load_error;
    };

    // ── 6. 장치 ────────────────────────────────────────────────────
    time.init();
    serial.print("[+] timer @ ");
    serial.printDec(time.tick_hz);
    serial.println(" Hz");

    arch.isr.setIrqHandler(1, arch.keyboard.readAndHandle);
    arch.pic.unmask(1);
    serial.println("[+] keyboard enabled");

    // ── 7. 인터럽트 개방 ───────────────────────────────────────────
    // 핸들러가 전부 준비된 뒤에야 켤 수 있다.
    // 먼저 켜면 첫 타이머 틱이 갈 곳을 잃는다.
    arch.enableInterrupts();
    serial.println("[+] interrupts enabled");

    // 타이머가 실제로 도는지 확인. 멈춰 있으면 EOI를 의심한다.
    const t0 = time.millis();
    time.sleep(100);
    serial.print("[*] timer check: ");
    serial.printDec(time.millis() - t0);
    serial.println(" ms (expected ~100)");

    // TSC 보정. PIT가 돌기 시작한 뒤에야 할 수 있다.
    // 이게 있어야 마이크로초 단위로 구간을 잴 수 있다.
    time.calibrateTsc();
    serial.print("[+] tsc calibrated: ~");
    serial.printDec(arch.tsc.megahertz());
    serial.print(" MHz, invariant=");
    serial.print(if (arch.tsc.isInvariant()) "yes" else "no");
    serial.println(if (arch.tsc.calibration_trusted) "" else "  [!] out of expected range");

    // 시계 교차 검증.
    //
    // 두 번 잰다. 차이가 핵심이다:
    //
    //   busy : pause 루프로 도는 동안 - CPU가 계속 명령을 실행한다
    //   idle : hlt로 자는 동안       - CPU가 멈춰 있다
    //
    // busy가 맞고 idle이 어긋나면, 이 환경의 TSC는 "흐른 시간"이 아니라
    // "실행한 사이클"을 세고 있다는 뜻이다(invariant TSC가 아닌 경우).
    // 그러면 TSC는 작업 구간 측정에만 쓰고, 대기 시간은 PIT로 재야 한다.
    {
        serial.println("[*] clock check:");
        checkClock("busy", false);
        checkClock("idle", true);
    }

    // ── 8. 실행 ────────────────────────────────────────────────────
    serial.println("=== entering game loop ===");
    demo.run();
}

// ─────────────────────────────────────────────────────────────────────

/// PIT와 TSC로 같은 구간을 재서 대조한다.
fn checkClock(label: []const u8, comptime use_hlt: bool) void {
    const span_ms = 200;

    const pit_start = time.millis();
    const tsc_start = time.micros();

    if (use_hlt) {
        time.sleep(span_ms);
    } else {
        const target = time.millis() + span_ms;
        while (time.millis() < target) asm volatile ("pause");
    }

    const pit_ms = time.millis() - pit_start;
    const tsc_ms = (time.micros() - tsc_start) / 1000;

    serial.print("    ");
    serial.print(label);
    serial.print(" : pit ");
    serial.printDec(pit_ms);
    serial.print(" ms / tsc ");
    serial.printDec(tsc_ms);
    serial.print(" ms  ");

    const diff = if (tsc_ms > pit_ms) tsc_ms - pit_ms else pit_ms - tsc_ms;
    if (pit_ms > 0 and diff * 100 / pit_ms > 5) {
        serial.print("[!] off by ");
        serial.printDec(diff * 100 / pit_ms);
        serial.println("%");
    } else {
        serial.println("ok");
    }
}

/// GOP에서 프레임버퍼 정보를 얻고 백버퍼를 확보한다.
///
/// exitBootServices 이후 GOP 프로토콜은 쓸 수 없지만
/// 프레임버퍼의 물리 주소는 그대로 유효하다. 그래서 주소와 형식만 복사해 둔다.
/// 백버퍼도 여기서 잡는다 - 펌웨어 할당자를 쓸 수 있는 마지막 기회다.
/// (여기서 받은 메모리는 loader_data라 물리 할당자가 건드리지 않는다)
fn setupGraphics(bs: *uefi.tables.BootServices) !void {
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse
        return error.NoGraphicsOutput;

    kernel.screen = try gfx.Framebuffer.init(gop);

    serial.print("[+] framebuffer ");
    serial.printDec(kernel.screen.width);
    serial.print("x");
    serial.printDec(kernel.screen.height);
    serial.print(" @ ");
    serial.printHex(kernel.screen.base);
    serial.print("\n");

    const back = try uefi.pool_allocator.alloc(u32, kernel.screen.pixelCount());
    kernel.canvas = kernel.screen.canvas(back);

    serial.print("[+] back buffer ");
    serial.printDec(back.len * 4 / 1024);
    serial.println(" KiB");
}

/// 메모리 맵을 얻고 펌웨어에서 나간다. 맵을 그대로 돌려준다.
///
/// getMemoryMap이 주는 map_key는 "그 순간의 메모리 상태"를 가리킨다.
/// 그 뒤 할당이 한 번이라도 일어나면 키가 무효가 되어 exit이 거부된다.
/// 그런데 맵을 담을 버퍼를 할당하는 것 자체가 상태를 바꾼다.
/// 그래서 실패하면 다시 얻어 재시도하는 구조가 된다.
fn exitBootServices(bs: *uefi.tables.BootServices) !uefi.tables.MemoryMapSlice {
    const info = try bs.getMemoryMapInfo();
    const size = (info.len + 8) * info.descriptor_size;
    const buffer = try bs.allocatePool(.loader_data, size);

    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        const map = bs.getMemoryMap(@alignCast(buffer)) catch |err| {
            if (err == error.BufferTooSmall) return err;
            continue;
        };
        bs.exitBootServices(uefi.handle, map.info.key) catch continue;
        return map;
    }
    return error.ExitFailed;
}

/// exitBootServices 이후 무효가 된 포인터들. UEFI 스펙이 지우라고 요구한다.
fn clearFirmwarePointers(st: *uefi.tables.SystemTable) void {
    st.console_in_handle = null;
    st.con_in = null;
    st.console_out_handle = null;
    st.con_out = null;
    st.standard_error_handle = null;
    st.std_err = null;
    st.boot_services = null;
}
