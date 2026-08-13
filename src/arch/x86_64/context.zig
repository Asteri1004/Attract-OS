//! 컨텍스트 스위칭.
//!
//! 스레드를 바꾼다는 건 결국 **스택 포인터를 바꾸는 것**이다.
//! rsp가 다른 스택을 가리키면, 그 위에 쌓여 있던 복귀 주소와
//! 지역 변수가 되살아나면서 다른 실행 흐름이 이어진다.
//!
//! 이 파일은 **모듈 레벨 어셈블리**로 심볼을 직접 정의한다.
//! Zig 함수(naked 포함)로 감싸면 컴파일러가 프롤로그/에필로그를 붙이거나,
//! 인라인하거나, 호출 자체를 지워버릴 여지가 남는다.
//! 실제로 겪은 증상들:
//!
//!   - 일반 함수: 에필로그가 남의 스택에서 rbp를 꺼내 쓰레기로 리턴
//!     (invalid opcode, rip이 코드 영역 밖)
//!   - naked + @extern: 호출이 통째로 사라짐
//!     (전환한 척만 하고 계속 같은 스레드가 실행됨, 저장된 rsp가 0)
//!
//! 어셈블리를 직접 심으면 이런 여지가 전혀 없다.
//! 실제 전환 코드. SysV 규약이니 rdi = save_to, rsi = new_rsp.
//!
//! 저장할 레지스터가 6개뿐인 이유:
//! 이 코드는 **일반 함수 호출로** 진입한다. SysV ABI에서 함수 호출은
//! caller-saved 레지스터(rax, rcx, rdx, rsi, rdi, r8-r11)를 망가뜨려도
//! 된다고 약속되어 있고, 컴파일러가 필요하면 알아서 저장해둔다.
//! 그러니 callee-saved(rbx, rbp, r12-r15)만 챙기면 된다.
//!
//! 인터럽트로 강제 전환할 때(M4b)는 얘기가 다르다. 그건 함수 호출이
//! 아니라 예고 없는 침입이라 전부 저장해야 한다.
comptime {
    asm (
        \\.text
        \\.globl attractSwitchContext
        \\attractSwitchContext:
        \\  pushq %rbp
        \\  pushq %rbx
        \\  pushq %r12
        \\  pushq %r13
        \\  pushq %r14
        \\  pushq %r15
        \\
        \\  movq %rsp, (%rdi)   /* 지금까지의 나를 저장하고 */
        \\  movq %rsi, %rsp     /* 저쪽이 된다 */
        \\
        \\  /* 여기서부터는 다른 스레드의 스택 위에서 실행 중이다.
        \\     이 pop들이 꺼내는 값은 그 스레드가 예전에 밀어넣은 것. */
        \\  popq %r15
        \\  popq %r14
        \\  popq %r13
        \\  popq %r12
        \\  popq %rbx
        \\  popq %rbp
        \\
        \\  /* 새 스레드의 복귀 주소로 점프.
        \\     갓 생성된 스레드라면 initStack이 심어둔 진입점으로. */
        \\  retq
    );
}

/// 현재 스레드의 rsp를 `save_to`에 넣고, `new_rsp`로 갈아탄다.
///
/// 이 함수는 **두 번 돌아온다**는 점이 특이하다.
/// 호출한 순간에는 다른 스레드로 떠나고, 나중에 누군가 이 스레드로
/// 다시 전환해줄 때 마치 방금 리턴한 것처럼 이어진다.
/// 그 사이에 몇 프레임이 흘렀는지 이 함수는 모른다.
pub extern fn attractSwitchContext(
    save_to: *u64,
    new_rsp: u64,
) callconv(.{ .x86_64_sysv = .{} }) void;

pub const switchTo = attractSwitchContext;

/// 스택 최상단에서 초기 프레임을 만든다.
///
/// 스택에 "이미 한 번 전환됐다가 돌아오는 중인 것처럼" 가짜 흔적을
/// 남겨두는 것이다. 그래야 switchTo가 평소처럼 pop과 ret만 해도
/// 새 스레드의 진입점으로 뛰어든다.
///
/// **스택 정렬이 까다롭다.** SysV는 함수 진입 시점에 rsp % 16 == 8을
/// 요구한다(call이 8바이트를 밀어넣은 직후 상태). ReleaseFast 빌드는
/// SIMD를 쓰는데, 정렬이 틀리면 movaps에서 general protection fault가
/// 난다. 원인 찾기 지독한 부류의 버그다.
pub fn initStack(stack: []u8, entry: *const fn () callconv(.c) noreturn) u64 {
    const top = @intFromPtr(stack.ptr) + stack.len;
    const aligned = top & ~@as(u64, 15); // 16바이트 정렬

    // 레이아웃 (주소 낮은 쪽 -> 높은 쪽):
    //   aligned-64  r15
    //   aligned-56  r14
    //   aligned-48  r13
    //   aligned-40  r12
    //   aligned-32  rbx
    //   aligned-24  rbp
    //   aligned-16  진입점 주소   <- ret가 여기로 점프
    //   aligned-8   (미사용, 정렬용 여백)
    //
    // ret 직후 rsp = aligned-8 이고, (aligned-8) % 16 == 8 이 된다.
    const frame: [*]u64 = @ptrFromInt(aligned - 64);

    frame[0] = 0; // r15
    frame[1] = 0; // r14
    frame[2] = 0; // r13
    frame[3] = 0; // r12
    frame[4] = 0; // rbx
    frame[5] = 0; // rbp
    frame[6] = @intFromPtr(entry);
    frame[7] = 0;

    return aligned - 64;
}
