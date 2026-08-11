# Attract — M0: 부트스트랩

> 목표: `zig build run` 했을 때 터미널에 부팅 로그가 뜬다.

## 준비물

```bash
# 1) Zig 0.16.0
#    ziglang.org/download 에서 받아 PATH에 추가
zig version    # 0.16.0 이 나와야 함

# 2) QEMU + OVMF (UEFI 펌웨어)
# Ubuntu/Debian
sudo apt install qemu-system-x86 ovmf
# Arch
sudo pacman -S qemu-system-x86_64 edk2-ovmf
# macOS
brew install qemu    # OVMF는 별도로 구해야 함
```

OVMF 경로 확인:
```bash
find / -name "OVMF*.fd" 2>/dev/null
```

경로가 다르면 실행할 때 넘기면 된다:
```bash
zig build run -Dovmf=/usr/share/OVMF/OVMF_CODE.fd
```

## 실행

```bash
zig build run
```

기대 출력:
```
=== Attract v0.1.0 booting ===
[+] boot services ok
[+] watchdog disabled
[+] console output ok
[+] GOP found
    resolution : 800 x 600
    stride     : 800 px
    format     : blue_green_red_reserved_8_bit_per_color
    fb base    : 0x80000000
    fb size    : 1920000 bytes
    modes      : 3
=== M0 complete. halting ===
```

종료는 `Ctrl+A` 누른 뒤 `X`.

## 파일 구조

```
build.zig       UEFI 타겟 설정 + QEMU 실행 파이프라인
build.zig.zon   Zig 버전 고정
src/serial.zig  COM1 드라이버 — 모든 디버깅의 기반
src/main.zig    진입점
```

## 이 단계에서 일어나는 일

1. 펌웨어가 FAT 파티션에서 `\EFI\BOOT\BOOTX64.EFI`를 찾아 실행
2. Zig 런타임이 `EfiMain`을 통해 `main()` 호출, `uefi.system_table` 세팅
3. COM1 UART 초기화 → 여기부터 로그를 볼 수 있다
4. 워치독 해제 (안 하면 5분 뒤 강제 리부트)
5. GOP 프로토콜을 찾아 프레임버퍼 정보만 출력 (아직 그리지 않음)
6. `hlt`로 정지

## 막혔을 때

| 증상 | 원인 |
|---|---|
| 터미널에 아무것도 안 뜸 | OVMF 경로 확인. QEMU 창은 뜨는지? |
| `BdsDxe: failed to load Boot0001` | `zig-out/efi/boot/bootx64.efi` 존재 확인 |
| fingerprint 에러 | 에러 메시지가 알려주는 값을 `.zon`에 복사 |
| API 관련 컴파일 에러 | `<zig설치경로>/lib/std/os/uefi/` 소스를 직접 읽는다 |
| 5분 뒤 저절로 재부팅 | 워치독 해제 실패 |

## 다음 (M1)

- [ ] `gop.mode.frame_buffer_base`를 `[*]u32`로 캐스팅해 픽셀 찍기
- [ ] 그라디언트 그리기 (stride 주의: 가로 해상도와 다를 수 있다)
- [ ] 비트맵 폰트로 화면에 텍스트
- [ ] 더블 버퍼링
