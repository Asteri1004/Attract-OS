//! 예외 핸들러.
//!
//! 이 파일의 목적은 "예외를 고치는 것"이 아니라 **잘 죽는 것**이다.
//! 커널에서 버그를 만나면 대개 화면이 멈추거나 조용히 리부트되는데,
//! 그러면 원인을 알 방법이 없다. 대신 여기서 레지스터 상태를 전부
//! 시리얼로 뱉고 멈추면, 무엇이 어디서 터졌는지 바로 보인다.
//!
//! M0에서 그래픽보다 시리얼을 먼저 만든 것과 같은 이유다.
//! 넘어지는 법부터 배워둔다.

const std = @import("std");
const serial = @import("../../serial.zig");
const port = @import("port.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");

/// 인터럽트 진입 시 스택에 쌓인 것들.
///
/// 메모리 배치가 곧 푸시 순서다. 스택은 낮은 주소로 자라므로
/// **마지막에 푸시한 것이 구조체의 첫 필드**가 된다.
/// isrCommon의 push 순서와 이 순서가 어긋나면 덤프가 통째로 거짓말을 한다.
pub const Frame = extern struct {
    // ── isrCommon이 푸시 (역순으로 나열) ──
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    // ── 스텁이 푸시 ──
    vector: u64,
    /// 일부 예외만 CPU가 밀어넣는다. 나머지는 스텁이 0을 채워
    /// 프레임 모양을 통일한다.
    error_code: u64,

    // ── CPU가 자동으로 푸시 ──
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// 에러 코드를 CPU가 직접 밀어넣는 예외들. (Intel SDM Vol.3 Ch.6.3.1 Table 6-1)
/// 이 목록이 틀리면 스택이 8바이트 어긋나 iretq가 엉뚱한 곳으로 돌아간다.
fn hasErrorCode(comptime vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

const exception_names = [_][]const u8{
    "divide error",
    "debug",
    "non-maskable interrupt",
    "breakpoint",
    "overflow",
    "bound range exceeded",
    "invalid opcode",
    "device not available",
    "double fault",
    "coprocessor segment overrun",
    "invalid TSS",
    "segment not present",
    "stack segment fault",
    "general protection fault",
    "page fault",
    "reserved (15)",
    "x87 floating point",
    "alignment check",
    "machine check",
    "SIMD floating point",
    "virtualization",
    "control protection",
    "reserved (22)",
    "reserved (23)",
    "reserved (24)",
    "reserved (25)",
    "reserved (26)",
    "reserved (27)",
    "hypervisor injection",
    "VMM communication",
    "security exception",
    "reserved (31)",
};

// ─────────────────────────────────────────────────────────────────────
// 스텁 — 벡터마다 하나씩, comptime으로 생성
// ─────────────────────────────────────────────────────────────────────

/// comptime이 빛나는 지점. C였다면 매크로로 32개를 찍어내거나
/// 어셈블리 파일을 따로 두어야 했을 것을, 일반 Zig 코드로 만든다.
fn Stub(comptime vector: u8) type {
    return struct {
        fn handler() callconv(.naked) void {
            // 에러 코드가 없는 예외에는 더미 0을 넣어 프레임 모양을 맞춘다.
            // 이게 없으면 예외 종류마다 스택 배치가 달라져서
            // 공통 핸들러를 쓸 수 없다.
            if (comptime !hasErrorCode(vector)) {
                asm volatile ("pushq $0");
            }
            asm volatile (
                \\pushq %[vec]
                \\jmp isrCommon
                :
                : [vec] "i" (@as(u32, vector)),
            );
        }
    };
}

/// 모든 범용 레지스터를 저장하고 Zig 핸들러를 부른다.
///
/// 스택 정렬 계산 (SysV ABI는 call 직전 rsp % 16 == 0을 요구):
///   진입 시 정렬됨            rsp % 16 == 0
///   CPU 푸시 5개 (40바이트)   → 8
///   에러코드/더미 (8바이트)   → 0
///   벡터 번호 (8바이트)       → 8
///   범용 15개 (120바이트)     → 0   ✓
export fn isrCommon() callconv(.naked) void {
    asm volatile (
    // Frame 구조체의 역순으로 푸시한다
        \\pushq %r15
        \\pushq %r14
        \\pushq %r13
        \\pushq %r12
        \\pushq %r11
        \\pushq %r10
        \\pushq %r9
        \\pushq %r8
        \\pushq %rbp
        \\pushq %rdi
        \\pushq %rsi
        \\pushq %rdx
        \\pushq %rcx
        \\pushq %rbx
        \\pushq %rax
        \\
        // 스택 포인터가 곧 Frame의 주소다.
        // SysV 첫 인자는 rdi (커널 전체가 msvc ABI로 빌드되지만
        // isrDispatch만 sysv로 명시해두었다)
        \\movq %rsp, %rdi
        \\call isrDispatch
        \\
        \\popq %rax
        \\popq %rbx
        \\popq %rcx
        \\popq %rdx
        \\popq %rsi
        \\popq %rdi
        \\popq %rbp
        \\popq %r8
        \\popq %r9
        \\popq %r10
        \\popq %r11
        \\popq %r12
        \\popq %r13
        \\popq %r14
        \\popq %r15
        \\
        // 벡터 번호와 에러 코드를 걷어낸다.
        // 이걸 빼먹으면 iretq가 스택을 잘못 읽어 아무 데로나 점프한다.
        \\addq $16, %rsp
        \\iretq
    );
}

/// 벡터 3 = breakpoint(int3). 유일하게 "복구 가능한" 예외로 취급한다.
///
/// 덤프만 찍고 정상 복귀하므로, 이게 성공한다는 건
/// 푸시/팝 순서, 스택 정렬, addq $16, iretq가 전부 맞다는 뜻이다.
/// 자가 진단 도구로 쓰기 좋다.
const breakpoint_vector = 3;

/// 벡터 14 = page fault. M3에서 페이지 테이블을 직접 관리하기 시작하면
/// 가장 자주 보게 될 예외다. CR2에 문제의 주소가 담긴다.
const page_fault_vector = 14;

/// IRQ 핸들러 테이블. 인터럽트 컨텍스트에서 호출되므로
/// 여기 등록하는 함수는 짧아야 한다. 긴 작업은 플래그만 세우고
/// 게임 루프에서 처리한다.
var irq_handlers = [_]?*const fn () void{null} ** 16;

pub fn setIrqHandler(irq: u4, handler: *const fn () void) void {
    irq_handlers[irq] = handler;
}

export fn isrDispatch(frame: *Frame) callconv(.{ .x86_64_sysv = .{} }) void {
    const vec = frame.vector;

    // ── 하드웨어 인터럽트 ──
    if (vec >= pic.vector_base and vec < pic.vector_base + 16) {
        const irq: u4 = @intCast(vec - pic.vector_base);

        if (irq_handlers[irq]) |handler| handler();

        // EOI를 빠뜨리면 같은 IRQ가 두 번 다시 오지 않는다.
        // 타이머가 한 번 돌고 멈추는 버그의 대부분이 이것.
        pic.endOfInterrupt(irq);
        return;
    }

    // ── CPU 예외 ──
    dump(frame);

    if (vec == breakpoint_vector) {
        serial.println("!! breakpoint - resuming\n");
        return;
    }

    serial.println("!! halted.");
    port.halt();
}

// ─────────────────────────────────────────────────────────────────────
// 덤프
// ─────────────────────────────────────────────────────────────────────

fn reg(label: []const u8, value: u64) void {
    serial.print(label);
    serial.print(" = ");
    serial.printHex(value);
    serial.print("\n");
}

fn dump(frame: *Frame) void {
    const vec = frame.vector;

    serial.print("\n");
    serial.println("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
    serial.print("!! EXCEPTION ");
    serial.printDec(vec);
    if (vec < exception_names.len) {
        serial.print(" - ");
        serial.print(exception_names[@intCast(vec)]);
    }
    serial.print("\n");
    serial.println("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");

    reg("  rip   ", frame.rip);
    reg("  cs    ", frame.cs);
    reg("  rflags", frame.rflags);
    reg("  rsp   ", frame.rsp);
    reg("  ss    ", frame.ss);
    reg("  err   ", frame.error_code);

    // 페이지 폴트는 접근하려던 주소가 CR2에 남는다.
    // 이 한 줄이 페이지 폴트 디버깅의 8할이다.
    if (vec == page_fault_vector) {
        const cr2 = asm volatile ("movq %%cr2, %[out]"
            : [out] "=r" (-> u64),
        );
        reg("  cr2   ", cr2);
        serial.print("  cause : ");
        const e = frame.error_code;
        serial.print(if (e & 1 != 0) "protection violation" else "page not present");
        serial.print(if (e & 2 != 0) ", write" else ", read");
        if (e & 4 != 0) serial.print(", user mode");
        if (e & 16 != 0) serial.print(", instruction fetch");
        serial.print("\n");
    }

    serial.println("  --- general purpose ---");
    reg("  rax   ", frame.rax);
    reg("  rbx   ", frame.rbx);
    reg("  rcx   ", frame.rcx);
    reg("  rdx   ", frame.rdx);
    reg("  rsi   ", frame.rsi);
    reg("  rdi   ", frame.rdi);
    reg("  rbp   ", frame.rbp);
    reg("  r8    ", frame.r8);
    reg("  r9    ", frame.r9);
    reg("  r10   ", frame.r10);
    reg("  r11   ", frame.r11);
    reg("  r12   ", frame.r12);
    reg("  r13   ", frame.r13);
    reg("  r14   ", frame.r14);
    reg("  r15   ", frame.r15);
}

// ─────────────────────────────────────────────────────────────────────

/// CPU 예외 32개 + PIC IRQ 16개를 IDT에 등록한다.
pub fn install() void {
    inline for (0..pic.vector_base + 16) |v| {
        idt.setHandler(v, &Stub(v).handler, .interrupt);
    }
}
