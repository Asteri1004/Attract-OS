//! 물리 프레임 할당자.
//!
//! 4KiB 페이지 단위로 "이 물리 메모리를 쓸 수 있는가"를 관리한다.
//! 비트맵 한 장이 전부다 - 비트 1개 = 페이지 1개.
//!
//! 왜 비트맵인가: 4GiB를 관리하는 데 128KiB면 충분하고(0.003%),
//! 할당/해제가 O(1)에 가까우며, 무엇보다 자료구조 자체가 힙을 필요로
//! 하지 않는다. 힙을 만들기 위한 할당자가 힙을 요구하면 곤란하다.

const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("../serial.zig");

pub const page_size = 4096;

pub const Error = error{OutOfMemory};

var bitmap: []u8 = &.{};
var total_pages: usize = 0;
var free_pages: usize = 0;

/// 할당 힌트. 매번 0부터 훑으면 느려지므로 마지막 위치를 기억한다.
var search_hint: usize = 0;

inline fn isUsed(page: usize) bool {
    return (bitmap[page / 8] & (@as(u8, 1) << @intCast(page % 8))) != 0;
}

inline fn markUsed(page: usize) void {
    bitmap[page / 8] |= (@as(u8, 1) << @intCast(page % 8));
}

inline fn markFree(page: usize) void {
    bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}

/// UEFI 메모리 맵으로부터 초기화한다.
///
/// 전략: 일단 **전부 사용 중으로 표시**하고, 확실히 비어 있다고
/// 알려진 영역만 해제한다. 반대로 하면 맵에 없는 영역(MMIO, 예약,
/// 펌웨어가 언급하지 않은 구멍)을 실수로 할당해서 하드웨어를 밟는다.
/// 모르는 메모리는 건드리지 않는 쪽이 안전하다.
pub fn init(map: uefi.tables.MemoryMapSlice, bitmap_storage: []u8) void {
    var highest: u64 = 0;
    var it = map.iterator();
    while (it.next()) |desc| {
        const end = desc.physical_start + desc.number_of_pages * page_size;
        if (end > highest) highest = end;
    }

    total_pages = @intCast(highest / page_size);
    const need = (total_pages + 7) / 8;

    bitmap = bitmap_storage[0..@min(need, bitmap_storage.len)];
    if (bitmap.len < need) {
        // 저장 공간이 모자라면 관리 범위를 줄인다. 위쪽 메모리를 포기할 뿐
        // 동작에는 문제가 없다.
        total_pages = bitmap.len * 8;
    }

    @memset(bitmap, 0xFF); // 전부 사용 중
    free_pages = 0;

    it = map.iterator();
    while (it.next()) |desc| {
        switch (desc.type) {
            // conventional: 원래 비어 있던 메모리
            // boot_services_*: 펌웨어가 나갔으니 이제 우리 것
            .conventional_memory,
            .boot_services_code,
            .boot_services_data,
            => {},
            else => continue,
        }

        const start: usize = @intCast(desc.physical_start / page_size);
        const count: usize = @intCast(desc.number_of_pages);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const p = start + i;
            if (p >= total_pages) break;
            if (isUsed(p)) {
                markFree(p);
                free_pages += 1;
            }
        }
    }

    // 첫 페이지(0x0)는 영원히 막아둔다.
    // null 포인터 역참조가 조용히 성공하는 것보다
    // 페이지 폴트로 시끄럽게 죽는 편이 낫다.
    if (!isUsed(0)) {
        markUsed(0);
        free_pages -= 1;
    }
}

/// 이미 쓰고 있는 영역을 예약한다. 커널 이미지, 백버퍼처럼
/// exitBootServices 이전에 확보해둔 메모리를 보호할 때 쓴다.
pub fn reserve(addr: u64, size: usize) void {
    const start: usize = @intCast(addr / page_size);
    const end: usize = @intCast((addr + size + page_size - 1) / page_size);
    var p = start;
    while (p < end and p < total_pages) : (p += 1) {
        if (!isUsed(p)) {
            markUsed(p);
            free_pages -= 1;
        }
    }
}

/// 물리 페이지 하나. 반환값은 물리 주소.
pub fn alloc() Error!u64 {
    var scanned: usize = 0;
    var p = search_hint;

    while (scanned < total_pages) : (scanned += 1) {
        if (p >= total_pages) p = 0;
        if (!isUsed(p)) {
            markUsed(p);
            free_pages -= 1;
            search_hint = p + 1;
            return @as(u64, p) * page_size;
        }
        p += 1;
    }
    return Error.OutOfMemory;
}

/// 0으로 채워진 페이지. 페이지 테이블용으로 쓴다.
/// 쓰레기 값이 남아 있으면 그대로 유효한 매핑으로 해석되어
/// 엉뚱한 물리 주소를 가리킨다.
pub fn allocZeroed() Error!u64 {
    const addr = try alloc();
    const ptr: [*]u8 = @ptrFromInt(addr);
    @memset(ptr[0..page_size], 0);
    return addr;
}

/// 연속된 페이지 n개. 프레임버퍼나 DMA 버퍼처럼 물리적으로
/// 이어져 있어야 하는 것들에 쓴다.
pub fn allocContiguous(count: usize) Error!u64 {
    if (count == 0) return Error.OutOfMemory;

    var start: usize = 0;
    while (start + count <= total_pages) {
        var i: usize = 0;
        while (i < count and !isUsed(start + i)) : (i += 1) {}

        if (i == count) {
            var j: usize = 0;
            while (j < count) : (j += 1) markUsed(start + j);
            free_pages -= count;
            return @as(u64, start) * page_size;
        }
        start += i + 1; // 막힌 지점 다음부터 다시
    }
    return Error.OutOfMemory;
}

pub fn free(addr: u64) void {
    const p: usize = @intCast(addr / page_size);
    if (p >= total_pages or !isUsed(p)) return;
    markFree(p);
    free_pages += 1;
    if (p < search_hint) search_hint = p;
}

pub fn stats() struct { total: usize, free: usize, used: usize } {
    return .{
        .total = total_pages,
        .free = free_pages,
        .used = total_pages - free_pages,
    };
}

pub fn report() void {
    const s = stats();
    serial.print("    total ");
    serial.printDec(s.total * page_size / 1024 / 1024);
    serial.print(" MiB / free ");
    serial.printDec(s.free * page_size / 1024 / 1024);
    serial.print(" MiB (");
    serial.printDec(s.free);
    serial.println(" pages)");
}
