# Attract

> 게임을 위한, 게임만을 위한 베어메탈 OS

x86_64 UEFI 환경에서 처음부터 쌓아 올리는 커널. Zig로 작성.
범용 OS가 아니라 게임 콘솔 펌웨어에 가깝고, **프레임 데드라인을 지키는 것**을
최우선으로 설계한다.

취미 / 학습 프로젝트. 배포 목표 없음.

## 현재 상태

**M2a 완료** — 펌웨어에서 독립했다. 자체 GDT/IDT로 동작하며,
예외가 발생하면 시리얼에 레지스터 덤프를 남기고 멈춘다.

| | 마일스톤 | 상태 |
|---|---|---|
| M0 | 시리얼 출력, UEFI 부팅, GOP 조회 | 완료 |
| M1 | 프레임버퍼, 비트맵 폰트, 더블 버퍼링 | 완료 |
| M2a | exitBootServices, GDT, IDT, 예외 핸들러 | 완료 |
| M2b | PIC, 타이머, 키보드, 60fps 루프 | 진행 예정 |
| M3 | 물리/가상 메모리 관리, 힙 | |
| M4 | 데드라인 기반 스케줄러, 지연 측정 | |
| M5 | 유저 모드, ELF 로더 | |

전체 계획은 [docs/PLAN.md](docs/PLAN.md), 개발 과정은
[docs/journal/](docs/journal/) 참고.

## 빌드 & 실행

### 준비물

- **Zig 0.16.0** — [ziglang.org/download](https://ziglang.org/download/)
- **QEMU** — Windows는 [qemu.weilnetz.de/w64](https://qemu.weilnetz.de/w64/)

### EDK2 vars 사본 만들기

펌웨어가 부팅 변수를 기록하므로 쓰기 가능한 사본이 필요하다.
프로젝트 루트에서 한 번만:

```powershell
# Windows
copy "C:\Program Files\qemu\share\edk2-i386-vars.fd" .\ovmf_vars.fd
```

```bash
# Linux
cp /usr/share/OVMF/OVMF_VARS.fd ./ovmf_vars.fd
```

### 실행

```
zig build run
```

경로가 다르면 옵션으로 넘긴다:

```
zig build run -Dqemu="D:/qemu/qemu-system-x86_64.exe" -Dovmf-code="D:/qemu/share/edk2-x86_64-code.fd"
```

QEMU 창에 상태 화면이 뜨고, 터미널에 부팅 로그가 찍히면 성공.

```
=== Attract v0.2.0 booting ===
[+] watchdog disabled
[+] framebuffer 1280x800 @ 0x0000000080000000
[+] back buffer 4000 KiB
[+] memory map: 108 descriptors
[+] exited boot services - we own the machine now
[+] gdt loaded
[+] idt loaded (32 exception handlers)
[*] self-test: triggering int3 ...
!! EXCEPTION 3 - breakpoint
   ... 레지스터 덤프 ...
!! breakpoint - resuming
[+] returned from exception - handler path verified
=== M2a complete. halting ===
```

## 구조

```
build.zig            UEFI 타겟 설정 + QEMU 실행
build.zig.zon        Zig 버전 고정 (0.16.0)
src/
  main.zig           부팅 순서가 여기 다 있다
  serial.zig         COM1 UART. 모든 디버깅의 통로
  framebuffer.zig    Canvas(백버퍼) + Framebuffer(화면)
  font.zig           8x8 비트맵 폰트 (ASCII 32..126)
  arch/x86_64/
    port.zig         포트 I/O, 인터럽트 제어
    gdt.zig          세그먼트 디스크립터
    idt.zig          인터럽트 디스크립터
    isr.zig          예외 스텁 + 레지스터 덤프
```

## 부팅 순서

1. 펌웨어가 FAT 파티션의 `\EFI\BOOT\BOOTX64.EFI`를 로드
2. **시리얼 초기화** — 이후 모든 디버깅의 통로
3. 워치독 해제 (안 하면 5분 뒤 강제 리부트)
4. GOP에서 프레임버퍼 주소/형식 확보, 백버퍼 할당
   — 펌웨어 할당자를 쓸 수 있는 마지막 기회
5. 메모리 맵 획득 → `exitBootServices()`
6. **자체 GDT / IDT 설치**
7. `int3` 자가 진단 — 복귀에 성공하면 인터럽트 경로 전체가 정상
8. 화면 출력

## 설계 메모

**시리얼이 그래픽보다 먼저다.** 커널에는 디버거도 printf도 없다.
화면이 검을 때 원인을 알 방법이 없으면 이후 모든 작업이 장님 코딩이 된다.

**넘어지는 법을 먼저 배운다.** IDT 없이 예외가 나면 트리플 폴트로
조용히 리부트된다. 원인 표시가 전혀 없다. 예외 핸들러를 일찍 세우는 것이
곧 디버깅 능력이다. `int3` 자가 진단이 복귀에 성공한다는 건
푸시/팝 순서, 스택 정렬, `iretq`가 전부 맞다는 뜻이라 검증 도구로도 쓴다.

**펌웨어 GDT를 물려받지 않는다.** exitBootServices 이후 그 메모리는
우리가 자유롭게 재사용할 수 있는 영역이 된다. 어느 순간 덮어쓰면
즉시 죽는데 원인 추적이 매우 어렵다.

**Canvas와 Framebuffer는 분리한다.** 그리기는 전부 일반 메모리(Canvas)에서
일어나고, Framebuffer는 그것을 한 번에 옮기는 일만 한다. 화면 메모리는
캐시가 안 먹어서 픽셀 단위 접근이 느리고, 중간 상태가 보이면 깜빡인다.
게임의 `update → render → present` 구조와도 그대로 맞는다.

**stride는 width와 다를 수 있다.** 하드웨어가 줄 시작 주소를 정렬하려고
여분을 두기 때문. 지금 QEMU 환경은 둘이 같지만, 처음부터 분리해두지 않으면
나중에 화면이 사선으로 밀리는 버그를 만나게 된다.

**커널 로그는 ASCII만.** em dash 같은 문자는 터미널에서 `??`로 깨진다.

## 옵션

| 옵션 | 기본값 |
|---|---|
| `-Dqemu=` | `C:/Program Files/qemu/qemu-system-x86_64.exe` |
| `-Dovmf-code=` | `C:/Program Files/qemu/share/edk2-x86_64-code.fd` |
| `-Dovmf-vars=` | `ovmf_vars.fd` |
| `-Doptimize=` | `Debug` |

## 참고 자료

- [OSDev Wiki](https://wiki.osdev.org/) — 막힐 때의 사전
- [Writing a Hypervisor in Zig](https://hv.smallkirby.com/) — UEFI 부트로더 파트가 훌륭
- [sfiedler/zig_os](https://codeberg.org/sfiedler/zig_os) — Zig 버전별 태그 제공
- Intel SDM Vol.3 — GDT는 Ch.3, 예외/IDT는 Ch.6
- UEFI Specification — 원전
- `<zig설치경로>/lib/std/os/uefi/` — std.os.uefi API의 가장 정확한 문서
