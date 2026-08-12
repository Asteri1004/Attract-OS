//! 커널 힙.
//!
//! 이 파일이 기획서의 설계 원칙 3번 "런타임에 놀라지 않는다"가
//! 실제 코드가 되는 곳이다.
//!
//! 보통의 OS는 메모리를 게으르게 준다. malloc은 주소만 넘겨주고,
//! 실제 물리 페이지는 처음 접근할 때 페이지 폴트를 통해 붙는다.
//! 평균 성능에는 유리하지만 **언제 폴트가 날지 예측할 수 없다.**
//! 게임에서 이건 프레임 한복판의 히칭으로 나타난다.
//!
//! 그래서 반대로 간다:
//!   1. 부팅 시 힙 영역 전체를 물리 페이지로 확보하고 매핑한다
//!   2. 전 영역을 한 번 써서 TLB와 캐시에 올린다 (프리폴트)
//!   3. 런타임 할당은 순수한 포인터 계산만 한다 - 폴트가 날 여지가 없다
//!
//! 대가는 시작 시간과 메모리 낭비다. 게임기는 그걸 낼 만하다.

const std = @import("std");
const Alignment = std.mem.Alignment;

const phys = @import("physical.zig");
const paging = @import("../arch/x86_64/paging.zig");
const serial = @import("../serial.zig");

pub const Error = error{ OutOfMemory, TooSmall };

/// 블록 헤더. 각 블록 바로 앞에 붙는다.
///
/// 16바이트로 맞춘 이유: x86_64에서 가장 큰 기본 정렬이 16이라
/// 헤더가 그 배수면 페이로드 정렬을 따로 맞출 일이 줄어든다.
const Header = extern struct {
    size: usize, // 페이로드 크기 (헤더 제외)
    next: ?*Header, // 다음 자유 블록. 사용 중이면 의미 없음
    free: bool,
    _pad: [7]u8 = .{0} ** 7,

    const size_of = @sizeOf(Header);

    fn payload(self: *Header) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + size_of;
    }

    fn fromPayload(ptr: [*]u8) *Header {
        return @ptrCast(@alignCast(ptr - size_of));
    }

    /// 이 블록 바로 뒤에 오는 헤더. 힙 끝을 넘을 수 있으니 호출 측에서 확인.
    fn following(self: *Header) *Header {
        return @ptrFromInt(@intFromPtr(self) + size_of + self.size);
    }
};

var heap_start: usize = 0;
var heap_end: usize = 0;
var first: ?*Header = null;

/// 통계. 프레임 예산을 지키는지 보려면 측정부터 해야 한다.
pub var alloc_count: u64 = 0;
pub var free_count: u64 = 0;
pub var bytes_in_use: usize = 0;
pub var peak_bytes: usize = 0;

/// 힙을 준비한다. 물리 페이지를 실제로 붙이고 미리 터치한다.
///
/// `virt_base`는 힙이 놓일 가상 주소. identity mapping을 쓰고 있으므로
/// 물리 주소를 그대로 넘겨도 되지만, 나중에 커널 전용 영역으로
/// 옮길 여지를 남겨 인자로 받는다.
pub fn init(size_bytes: usize) Error!void {
    if (size_bytes < paging.page_size * 4) return Error.TooSmall;

    const pages = (size_bytes + paging.page_size - 1) / paging.page_size;

    // 물리적으로 연속되게 잡는다. 꼭 필요하진 않지만
    // 힙이 조각나 있으면 캐시 지역성이 나빠진다.
    const base = phys.allocContiguous(pages) catch return Error.OutOfMemory;

    heap_start = @intCast(base);
    heap_end = heap_start + pages * paging.page_size;

    // 프리폴트: 전 영역을 0으로 채운다.
    // 이 한 줄이 런타임 페이지 폴트를 없앤다. 부팅이 조금 느려지는 대신
    // 게임이 도는 동안에는 메모리 때문에 멈추는 일이 없다.
    const all: [*]u8 = @ptrFromInt(heap_start);
    @memset(all[0 .. heap_end - heap_start], 0);

    // 힙 전체를 하나의 자유 블록으로
    const head: *Header = @ptrFromInt(heap_start);
    head.* = .{
        .size = (heap_end - heap_start) - Header.size_of,
        .next = null,
        .free = true,
    };
    first = head;
}

/// first-fit. 자유 블록을 앞에서부터 훑어 처음 맞는 것을 쓴다.
///
/// best-fit보다 조각화가 조금 심하지만 예측 가능한 시간에 끝난다.
/// 게임 OS에서는 "평균이 빠른 것"보다 "최악이 짧은 것"이 중요하다.
fn findFit(size: usize, alignment: usize) ?*Header {
    var current = first;
    while (current) |block| : (current = block.next) {
        if (!block.free) continue;

        const payload_addr = @intFromPtr(block) + Header.size_of;
        const aligned = std.mem.alignForward(usize, payload_addr, alignment);
        const padding = aligned - payload_addr;

        if (block.size >= size + padding) return block;
    }
    return null;
}

/// 블록이 충분히 크면 뒤쪽을 잘라 새 자유 블록으로 만든다.
/// 안 그러면 8바이트 요청에 1MiB 블록이 통째로 나간다.
fn split(block: *Header, needed: usize) void {
    const leftover = block.size - needed;

    // 헤더 + 최소 페이로드가 안 되면 쪼개지 않고 통째로 준다
    if (leftover < Header.size_of + 32) return;

    const rest: *Header = @ptrFromInt(@intFromPtr(block) + Header.size_of + needed);
    rest.* = .{
        .size = leftover - Header.size_of,
        .next = block.next,
        .free = true,
    };

    block.size = needed;
    block.next = rest;
}

/// 인접한 자유 블록을 합친다. 이게 없으면 할당/해제를 반복하는 것만으로
/// 힙이 잘게 부서져 큰 할당이 실패하기 시작한다.
fn coalesce() void {
    var current = first;
    while (current) |block| {
        if (!block.free) {
            current = block.next;
            continue;
        }

        const next = block.next orelse break;
        // 메모리상 바로 뒤에 붙어 있고 그것도 비어 있으면 합친다
        if (block.following() == next and next.free) {
            block.size += Header.size_of + next.size;
            block.next = next.next;
            continue; // 더 합칠 수 있는지 같은 블록에서 다시
        }
        current = block.next;
    }
}

// ─────────────────────────────────────────────────────────────────────
// std.mem.Allocator 인터페이스
// ─────────────────────────────────────────────────────────────────────

pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &vtable,
    };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = vtableAlloc,
    .resize = vtableResize,
    .remap = vtableRemap,
    .free = vtableFree,
};

fn vtableAlloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const want = alignment.toByteUnits();

    const block = findFit(len, want) orelse return null;

    const payload_addr = @intFromPtr(block) + Header.size_of;
    const aligned = std.mem.alignForward(usize, payload_addr, want);
    const padding = aligned - payload_addr;

    split(block, len + padding);
    block.free = false;

    alloc_count += 1;
    bytes_in_use += block.size;
    if (bytes_in_use > peak_bytes) peak_bytes = bytes_in_use;

    return @ptrFromInt(aligned);
}

fn vtableResize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    const block = Header.fromPayload(memory.ptr);
    // 줄이는 건 항상 되고, 늘리는 건 현재 블록 안에서만
    return new_len <= block.size;
}

fn vtableRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (vtableResize(ctx, memory, alignment, new_len, ra)) return memory.ptr;
    return null;
}

fn vtableFree(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const block = Header.fromPayload(memory.ptr);
    block.free = true;

    free_count += 1;
    bytes_in_use -= block.size;

    coalesce();
}

// ─────────────────────────────────────────────────────────────────────

pub fn stats() struct { total: usize, in_use: usize, peak: usize, allocs: u64, frees: u64 } {
    return .{
        .total = heap_end - heap_start,
        .in_use = bytes_in_use,
        .peak = peak_bytes,
        .allocs = alloc_count,
        .frees = free_count,
    };
}

pub fn report() void {
    const s = stats();
    serial.print("    size ");
    serial.printDec(s.total / 1024);
    serial.print(" KiB / in use ");
    serial.printDec(s.in_use / 1024);
    serial.print(" KiB / peak ");
    serial.printDec(s.peak / 1024);
    serial.println(" KiB");
}
