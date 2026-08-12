//! 메모리 서브시스템 진입점.
//!
//! 부팅 시 메모리를 세우는 순서가 여기 담긴다. 순서 하나하나에
//! 이유가 있고, 어기면 대부분 즉사(트리플 폴트)한다.

const std = @import("std");
const uefi = std.os.uefi;

const serial = @import("../serial.zig");
const paging = @import("../arch/x86_64/paging.zig");

pub const physical = @import("physical.zig");
pub const heap = @import("heap.zig");

pub const page_size = paging.page_size;

/// 물리 프레임 비트맵 저장소.
///
/// 힙이 생기기 전에 필요한 자료구조라 정적으로 잡는다.
/// 128KiB x 8비트 = 1M 페이지 = 4GiB까지 관리한다.
/// 0으로 초기화하면 .bss에 들어가 커널 파일 크기는 늘지 않는다.
var bitmap_storage: [128 * 1024]u8 = .{0} ** (128 * 1024);

/// 커널 힙 크기. 게임 하나를 돌리기엔 넉넉하다.
const heap_size = 16 * 1024 * 1024;

/// 현재 스택 주변을 넉넉히 예약한다.
///
/// **이걸 빼먹으면 아주 찾기 어려운 버그가 된다.**
/// UEFI가 준 스택은 보통 boot_services_data 타입이라, 물리 할당자가
/// "펌웨어가 나갔으니 이제 비었다"고 판단해 자유 목록에 넣는다.
/// 그러면 언젠가 그 페이지가 다른 용도로 할당되고, 지금 실행 중인
/// 함수의 지역 변수와 복귀 주소가 조용히 덮어써진다.
/// 증상은 "한참 잘 돌다가 엉뚱한 곳으로 점프"로 나타난다.
fn reserveCurrentStack() void {
    const rsp = asm volatile ("movq %%rsp, %[out]"
        : [out] "=r" (-> u64),
    );

    // 스택은 아래로 자라므로 rsp 아래쪽을 넉넉히 잡는다.
    // 위쪽도 조금 잡는 건 이미 쌓인 호출 프레임 때문.
    const below = 256 * 1024;
    const above = 64 * 1024;
    const start = if (rsp > below) rsp - below else 0;

    physical.reserve(start, below + above);

    serial.print("    stack around ");
    serial.printHex(rsp);
    serial.print(" reserved\n");
}

/// 메모리 관리를 세운다.
///
/// 순서가 곧 이유다:
///   1. 물리 할당자 - 어디가 비었는지 알아야 아무것도 할 수 없다
///   2. 스택 예약   - 지금 밟고 선 땅을 남에게 주지 않는다
///   3. 페이지 테이블 - 검증 후 교체
///   4. 힙          - 위 셋이 다 돼야 만들 수 있다
pub fn init(map: uefi.tables.MemoryMapSlice, fb_base: u64, fb_size: u64) !void {
    // ── 1. 물리 프레임 ─────────────────────────────────────────────
    physical.init(map, &bitmap_storage);
    serial.println("[+] physical allocator");
    physical.report();

    // ── 2. 발밑 보호 ───────────────────────────────────────────────
    reserveCurrentStack();

    // 프레임버퍼도 예약한다. RAM 바깥이라 보통 비트맵 범위 밖이지만
    // 겹치는 구성이 있을 수 있다.
    physical.reserve(fb_base, fb_size);

    // ── 3. 페이지 테이블 ───────────────────────────────────────────
    const ram_bytes = physical.stats().total * page_size;
    try paging.init(ram_bytes, fb_base, fb_size);
    serial.println("[+] page tables built");

    // 교체 전 검증. identity mapping이므로 translate 결과가
    // 입력과 같아야 한다. 여기서 어긋나면 activate 순간 트리플 폴트다.
    try verifyMapping(fb_base);

    paging.activate();
    serial.print("[+] cr3 switched to ");
    serial.printHex(paging.rootPhys());
    serial.print("\n");

    // 이 줄이 출력된다면 교체가 성공한 것이다.
    // 실패했다면 위 activate에서 이미 죽어서 여기 도달하지 못한다.

    // ── 4. 힙 ──────────────────────────────────────────────────────
    try heap.init(heap_size);
    serial.println("[+] kernel heap (pre-faulted)");
    heap.report();
}

/// CR3를 바꾸기 전에, 지금 실행 중인 코드와 스택과 프레임버퍼가
/// 새 테이블에서도 같은 주소로 해석되는지 확인한다.
fn verifyMapping(fb_base: u64) !void {
    const rsp = asm volatile ("movq %%rsp, %[out]"
        : [out] "=r" (-> u64),
    );
    const rip = @returnAddress();

    const checks = [_]struct { name: []const u8, addr: u64 }{
        .{ .name = "code", .addr = rip },
        .{ .name = "stack", .addr = rsp },
        .{ .name = "framebuffer", .addr = fb_base },
        .{ .name = "page table", .addr = paging.rootPhys() },
    };

    for (checks) |c| {
        const resolved = paging.translate(c.addr) orelse {
            serial.print("[!] unmapped: ");
            serial.print(c.name);
            serial.print(" @ ");
            serial.printHex(c.addr);
            serial.print("\n");
            return error.VerificationFailed;
        };
        if (resolved != c.addr) {
            serial.print("[!] mismatch: ");
            serial.print(c.name);
            serial.print(" ");
            serial.printHex(c.addr);
            serial.print(" -> ");
            serial.printHex(resolved);
            serial.print("\n");
            return error.VerificationFailed;
        }
    }
    serial.println("[+] mapping verified (code, stack, fb, tables)");
}
