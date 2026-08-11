//! GDT (Global Descriptor Table).
//!
//! 64비트 모드에서 세그먼테이션은 사실상 껍데기다. base/limit이 무시되고
//! 페이징이 그 역할을 대신한다. 그런데도 GDT가 필요한 이유는 CPU가
//! CS/SS 레지스터에서 특권 레벨과 코드 크기 비트를 읽기 때문이다.
//!
//! 펌웨어가 만든 GDT를 계속 쓰면 안 되는 이유:
//! exitBootServices() 이후 그 메모리는 우리가 자유롭게 재사용할 수 있는
//! 영역이 된다. 어느 순간 덮어쓰면 그 즉시 시스템이 죽는데,
//! 원인을 찾기가 매우 어렵다. 그래서 우리 것으로 갈아탄다.

/// 세그먼트 셀렉터. 하위 3비트는 RPL과 테이블 지시자라
/// 실제 인덱스는 8바이트 단위로 매긴다.
pub const kernel_code: u16 = 0x08; // 인덱스 1
pub const kernel_data: u16 = 0x10; // 인덱스 2

/// 64비트 코드/데이터 세그먼트 디스크립터.
/// 필드 배치가 기괴한 건 16비트 시절부터 확장을 거듭한 결과다.
/// (Intel SDM Vol.3 Ch.3.4.5)
const Entry = packed struct(u64) {
    limit_low: u16 = 0xFFFF,
    base_low: u16 = 0,
    base_mid: u8 = 0,

    accessed: bool = true, // CPU가 자동으로 세팅하므로 미리 켜둔다
    rw: bool, // 코드=읽기 허용, 데이터=쓰기 허용
    dc: bool = false, // conforming / direction
    executable: bool,
    is_user_segment: bool = true, // false면 TSS 같은 시스템 디스크립터
    dpl: u2 = 0, // 특권 레벨. 0=커널
    present: bool = true,

    limit_high: u4 = 0xF,
    reserved: u1 = 0,
    long_mode: bool, // 64비트 코드 세그먼트 표시
    default_size: bool = false, // long_mode와 동시에 켜면 안 된다
    granularity: bool = true, // limit 단위를 4KiB로

    base_high: u8 = 0,

    const null_entry: Entry = @bitCast(@as(u64, 0));

    const code: Entry = .{
        .rw = true,
        .executable = true,
        .long_mode = true,
    };

    const data: Entry = .{
        .rw = true,
        .executable = false,
        .long_mode = false,
    };
};

const Descriptor = packed struct(u80) {
    limit: u16,
    base: u64,
};

var table = [_]Entry{
    Entry.null_entry, // 인덱스 0은 반드시 null이어야 한다
    Entry.code,
    Entry.data,
};

var descriptor: Descriptor = undefined;

pub fn load() void {
    descriptor = .{
        .limit = @sizeOf(@TypeOf(table)) - 1,
        .base = @intFromPtr(&table),
    };

    asm volatile (
    // 새 GDT를 CPU에 알린다
        \\lgdt (%[desc])
        \\
        // 데이터 세그먼트 레지스터 갱신
        \\movw %[dsel], %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\movw %%ax, %%ss
        \\
        // CS는 mov로 바꿀 수 없다. 유일한 방법이 far jump/return이라
        // "돌아갈 주소"와 "돌아갈 CS"를 스택에 쌓고 lretq로 점프한다.
        // 사실상 자기 자신에게 far return 하는 셈.
        \\pushq %[csel]
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        :
        : [desc] "r" (&descriptor),
          [csel] "i" (@as(u64, kernel_code)),
          [dsel] "i" (kernel_data),
        : .{ .rax = true, .memory = true });
}
