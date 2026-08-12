# Attract

> 게임을 위한, 게임만을 위한 베어메탈 OS

x86_64 UEFI 환경에서 처음부터 쌓아 올리는 커널. Zig로 작성.
범용 OS가 아니라 게임 콘솔 펌웨어에 가깝고, **프레임 데드라인을 지키는 것**을
최우선으로 설계한다.

취미 / 학습 프로젝트. 배포 목표 없음.

## 현재 상태

**M3 완료** — 펌웨어에서 독립해 자체 GDT/IDT/페이지 테이블 위에서 돈다.
프리폴트 힙 덕에 매 프레임 동적 할당을 해도 프레임 시간이 흔들리지 않는다.

| | 마일스톤 | 상태 |
|---|---|---|
| M0 | 시리얼, UEFI 부팅, GOP | 완료 |
| M1 | 프레임버퍼, 비트맵 폰트, 더블 버퍼링 | 완료 |
| M2a | exitBootServices, GDT, IDT, 예외 핸들러 | 완료 |
| M2b | PIC, 타이머, 키보드, 60fps 루프 | 완료 |
| M3 | 물리 할당자, 4레벨 페이징, 프리폴트 힙 | 완료 |
| M4 | 데드라인 스케줄러, 지연 측정 | 진행 예정 |
| M5 | 유저 모드, ELF 로더 | |

전체 계획은 [docs/PLAN.md](docs/PLAN.md), 개발 과정은
[docs/journal/](docs/journal/) 참고.

### 측정값 (QEMU, 1280x800)

```
물리 메모리  117 MiB 가용 (30088 pages)
커널 힙      16 MiB, 프리폴트 완료
프레임 예산  16 ms
worst        13 ms   <- 여유 3ms. M4 전에 렌더링 비용을 줄여야 한다
```

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

방향키 또는 WASD로 사각형을 움직이고, ESC로 멈춘다.

## 부팅 순서

`main.zig`를 위에서 아래로 읽으면 이 순서가 그대로 보인다.
**순서 하나하나에 이유가 있고, 어기면 대부분 즉사한다.**

1. **시리얼 초기화** — 이후 모든 디버깅의 통로. 이게 없으면 장님 코딩
2. 워치독 해제 — 안 하면 5분 뒤 강제 리부트
3. GOP에서 프레임버퍼 정보 확보, 백버퍼 할당
   — 펌웨어 할당자를 쓸 수 있는 마지막 기회
4. 메모리 맵 획득 → `exitBootServices()` — 맵은 버리지 않고 보관
5. **GDT / IDT / PIC** — 메모리보다 먼저. 페이지 테이블을 만지다 실수하면
   페이지 폴트가 나는데, IDT가 없으면 원인 없이 리부트된다
6. **메모리** — 물리 할당자 → 스택 예약 → 페이지 테이블 검증 후 교체 → 힙
7. 타이머, 키보드 등록
8. 인터럽트 개방 (`sti`) — 핸들러가 전부 준비된 뒤에야
9. 게임 루프

## 구조

```
src/
  main.zig             부팅 순서만
  kernel.zig           전역 상태, panic
  demo.zig             게임 루프 (M5에서 커널 밖으로 나갈 코드)
  serial.zig           COM1 UART
  framebuffer.zig      Canvas(백버퍼) + Framebuffer(화면)
  font.zig             8x8 비트맵 폰트
  time.zig             틱, sleep
  mem/
    mem.zig            메모리 초기화 순서
    physical.zig       물리 프레임 비트맵 할당자
    heap.zig           프리폴트 힙 (std.mem.Allocator 구현)
  arch/x86_64/
    arch.zig           아키텍처 진입점
    port.zig           포트 I/O, 인터럽트 제어
    gdt.zig            세그먼트 디스크립터
    idt.zig            인터럽트 디스크립터
    isr.zig            예외/IRQ 스텁, 레지스터 덤프
    paging.zig         4레벨 페이지 테이블
    pic.zig            8259 인터럽트 컨트롤러
    pit.zig            8254 타이머
    keyboard.zig       PS/2 (상태 배열 방식)
```

의존은 아래로만 흐른다. `arch` 계층은 위를 모르고,
`time.zig`도 `pit`/`pic`을 직접 부르지 않고 `arch`를 경유한다.

## 설계 메모

**시리얼이 그래픽보다 먼저다.** 커널에는 디버거도 printf도 없다.
화면이 검을 때 원인을 알 방법이 없으면 이후 작업이 전부 장님 코딩이 된다.

**넘어지는 법을 먼저 배운다.** IDT 없이 예외가 나면 트리플 폴트로
조용히 리부트된다. 원인 표시가 전혀 없다. `int3` 자가 진단이 복귀에
성공한다는 건 푸시/팝 순서, 스택 정렬, `iretq`가 전부 맞다는 뜻이라
검증 도구로도 쓴다.

**PIC은 반드시 리맵한다.** 기본 설정에서 IRQ 0\~7이 벡터 8\~15로 들어오는데,
그 범위는 CPU 예외가 쓴다 — 벡터 8이 double fault다.
리맵하지 않으면 타이머 틱이 double fault로 보인다.

**인터럽트는 짧게, 일은 루프에서.** 키보드는 이벤트 큐가 아니라
상태 배열이다. 핸들러는 갱신만 하고 즉시 빠져나오고, 게임 루프가
프레임마다 읽어간다. 핸들러에서 로직을 돌리면 입력량에 따라
프레임 타이밍이 흔들린다.

**모르는 메모리는 건드리지 않는다.** 물리 할당자는 전부 사용 중으로
시작해서 확실히 빈 것만 해제한다. 반대로 하면 맵에 안 적힌 영역
(MMIO, 예약, 펌웨어가 언급 안 한 구멍)을 할당해 하드웨어를 밟는다.

**UEFI가 준 스택을 지킨다.** 그 스택은 `boot_services_data`라
그냥 두면 자유 목록에 들어간다. 나중에 재할당되면 실행 중인 함수의
지역 변수와 복귀 주소가 조용히 덮어써진다.

**CR3 교체 전에 검증한다.** 잘못된 페이지 테이블로 갈아타면
그 다음 명령어에서 트리플 폴트 — 로그가 한 줄도 안 남는다.
identity mapping을 유지하고, `translate()`로 코드/스택/프레임버퍼/
페이지 테이블 자신을 되짚어본 뒤에야 교체한다.

**힙은 프리폴트한다.** 보통 OS는 malloc이 주소만 주고 물리 페이지는
첫 접근 때 폴트로 붙인다. 평균엔 유리하지만 **언제 폴트가 날지
예측할 수 없다.** 게임에선 그게 프레임 한복판의 히칭이다.
부팅 시 전 영역을 한 번 밟아두면 런타임에 놀랄 일이 없다.
first-fit을 쓰는 것도 같은 이유 — 평균이 빠른 것보다 최악이 짧은 것.

**Canvas와 Framebuffer는 분리한다.** 그리기는 일반 메모리에서 하고,
Framebuffer는 한 번에 옮기는 일만 한다. 화면 메모리는 캐시가 안 먹어
픽셀 단위 접근이 느리고, 중간 상태가 보이면 깜빡인다.

**stride는 width와 다를 수 있다.** 하드웨어가 줄 시작 주소를 정렬하려고
여분을 두기 때문. 지금 QEMU는 둘이 같지만 처음부터 분리해두지 않으면
나중에 화면이 사선으로 밀린다.

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
- Intel SDM Vol.3 — GDT는 Ch.3, 예외/IDT는 Ch.6, 페이징은 Ch.4
- UEFI Specification — 원전
- `<zig설치경로>/lib/std/os/uefi/` — std.os.uefi API의 가장 정확한 문서
