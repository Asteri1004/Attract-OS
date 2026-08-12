//! x86_64 4레벨 페이징.
//!
//! 지금까지는 펌웨어가 만들어둔 페이지 테이블 위에서 돌고 있었다.
//! 여기서 우리 것으로 갈아탄다. CR3에 새 테이블 주소를 쓰는 순간
//! 주소 변환 방식이 통째로 바뀌므로, 실수하면 **그 명령어 다음 줄에서
//! 즉시 트리플 폴트**가 난다. 시리얼 출력조차 못 남기고 리부트된다.
//!
//! 그래서 안전장치를 둔다:
//!   - identity mapping을 유지한다 (가상 주소 == 물리 주소)
//!     그러면 CR3 교체 직후에도 현재 실행 중인 코드가 같은 자리에 있다
//!   - 교체 전에 매핑을 검증한다 (translate로 되짚어본다)
//!
//! 가상 주소 48비트가 9/9/9/9/12로 쪼개진다:
//!   [47:39] PML4 index   [38:30] PDPT index
//!   [29:21] PD index     [20:12] PT index    [11:0] offset
//! 각 테이블은 512개 엔트리 x 8바이트 = 정확히 4KiB 한 페이지.

const std = @import("std");
const phys = @import("../../mem/physical.zig");
const serial = @import("../../serial.zig");

pub const page_size = 4096;
pub const huge_page_size = 2 * 1024 * 1024;

pub const Error = error{ OutOfMemory, AlreadyMapped, NotMapped };

/// 페이지 테이블 엔트리. 물리 주소는 12비트 정렬이라
/// 하위 12비트가 비는데, 그 자리에 플래그를 욱여넣은 구조다.
/// (Intel SDM Vol.3 Ch.4.5)
pub const Flags = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    /// PD 레벨에서 켜면 2MiB 페이지, PDPT에서 켜면 1GiB 페이지.
    /// 하위 테이블 없이 바로 물리 주소를 가리킨다.
    huge: bool = false,
    global: bool = false,
    _available: u3 = 0,
    /// 물리 주소의 [51:12]. 나머지는 정렬로 보장된다.
    addr: u40 = 0,
    _available2: u11 = 0,
    no_execute: bool = false,

    pub fn physAddr(self: Flags) u64 {
        return @as(u64, self.addr) << 12;
    }

    fn setPhys(self: *Flags, address: u64) void {
        self.addr = @intCast(address >> 12);
    }
};

const Table = [512]Flags;

/// 커널 주소 공간의 루트.
var pml4_phys: u64 = 0;

inline fn tableAt(addr: u64) *Table {
    // identity mapping 덕분에 물리 주소를 그대로 포인터로 쓸 수 있다.
    // 이게 무너지면 페이지 테이블을 읽기 위해 페이지 테이블이 필요한
    // 닭과 달걀 문제가 생긴다.
    return @ptrFromInt(addr);
}

inline fn indexOf(virt: u64, level: u2) usize {
    const shift: u6 = @as(u6, 12) + @as(u6, level) * 9;
    return @intCast((virt >> shift) & 0x1FF);
}

/// 다음 레벨 테이블을 얻는다. 없으면 만든다.
fn nextTable(table: *Table, index: usize, create: bool) Error!*Table {
    const entry = &table[index];

    if (!entry.present) {
        if (!create) return Error.NotMapped;
        const page = phys.allocZeroed() catch return Error.OutOfMemory;
        entry.* = .{ .present = true, .writable = true, .user = true };
        entry.setPhys(page);
        return tableAt(page);
    }

    if (entry.huge) return Error.AlreadyMapped;
    return tableAt(entry.physAddr());
}

/// 가상 주소 하나를 물리 주소에 매핑한다 (4KiB).
pub fn map(virt: u64, physical: u64, flags: Flags) Error!void {
    const pml4 = tableAt(pml4_phys);
    const pdpt = try nextTable(pml4, indexOf(virt, 3), true);
    const pd = try nextTable(pdpt, indexOf(virt, 2), true);
    const pt = try nextTable(pd, indexOf(virt, 1), true);

    const entry = &pt[indexOf(virt, 0)];
    if (entry.present) return Error.AlreadyMapped;

    entry.* = flags;
    entry.present = true;
    entry.setPhys(physical);
}

/// 2MiB 대형 페이지. identity mapping처럼 넓은 영역을 덮을 때
/// 테이블 수가 512분의 1로 줄어 초기화가 훨씬 빠르고 TLB 압박도 적다.
pub fn mapHuge(virt: u64, physical: u64, flags: Flags) Error!void {
    const pml4 = tableAt(pml4_phys);
    const pdpt = try nextTable(pml4, indexOf(virt, 3), true);
    const pd = try nextTable(pdpt, indexOf(virt, 2), true);

    const entry = &pd[indexOf(virt, 1)];
    if (entry.present) return Error.AlreadyMapped;

    entry.* = flags;
    entry.present = true;
    entry.huge = true;
    entry.setPhys(physical);
}

/// 매핑을 되짚어 물리 주소를 얻는다. 검증용으로 요긴하다.
pub fn translate(virt: u64) ?u64 {
    const pml4 = tableAt(pml4_phys);

    const e4 = pml4[indexOf(virt, 3)];
    if (!e4.present) return null;

    const pdpt = tableAt(e4.physAddr());
    const e3 = pdpt[indexOf(virt, 2)];
    if (!e3.present) return null;
    if (e3.huge) return e3.physAddr() + (virt & 0x3FFF_FFFF); // 1GiB

    const pd = tableAt(e3.physAddr());
    const e2 = pd[indexOf(virt, 1)];
    if (!e2.present) return null;
    if (e2.huge) return e2.physAddr() + (virt & 0x1F_FFFF); // 2MiB

    const pt = tableAt(e2.physAddr());
    const e1 = pt[indexOf(virt, 0)];
    if (!e1.present) return null;
    return e1.physAddr() + (virt & 0xFFF);
}

/// 넓은 영역을 identity 매핑한다. 2MiB 단위로 정렬해 처리.
fn identityRange(start: u64, end: u64, flags: Flags) Error!void {
    var addr = start & ~@as(u64, huge_page_size - 1);
    while (addr < end) : (addr += huge_page_size) {
        mapHuge(addr, addr, flags) catch |err| switch (err) {
            Error.AlreadyMapped => continue, // 겹치는 건 넘어간다
            else => return err,
        };
    }
}

/// 커널 주소 공간을 만든다. 아직 활성화하지는 않는다.
///
/// identity mapping을 쓰는 이유가 여기서 결정적이다.
/// CR3를 바꾸는 순간 실행 중인 코드의 주소 해석이 바뀌는데,
/// 가상 == 물리라면 아무것도 움직이지 않는다.
pub fn init(ram_bytes: u64, fb_base: u64, fb_size: u64) Error!void {
    pml4_phys = phys.allocZeroed() catch return Error.OutOfMemory;

    const rw: Flags = .{ .writable = true };

    // 1. 물리 RAM 전체
    try identityRange(0, ram_bytes, rw);

    // 2. 프레임버퍼. RAM 영역 바깥(보통 2GiB 부근)에 따로 있다.
    //    캐시를 끄지 않는다 - MMIO지만 프레임버퍼는 순수 메모리처럼
    //    동작하고, 캐시를 끄면 present()가 수십 배 느려진다.
    try identityRange(fb_base, fb_base + fb_size, rw);
}

/// CR3 교체. 되돌릴 수 없다.
pub fn activate() void {
    asm volatile ("movq %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4_phys),
        : .{ .memory = true });
}

pub fn currentCr3() u64 {
    return asm volatile ("movq %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
}

/// 매핑 하나를 무효화한다. 매핑을 바꾼 뒤 이걸 빼먹으면
/// CPU가 TLB에 캐시된 옛 변환을 계속 쓴다.
pub fn invalidate(virt: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
}

pub fn rootPhys() u64 {
    return pml4_phys;
}
