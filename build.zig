const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // UEFI 애플리케이션은 사실상 Windows PE 형식이라 abi가 .msvc다.
    // (역사적인 이유. UEFI 스펙이 MS 계열에서 나왔다.)
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    // 기본을 ReleaseFast로 둔다.
    //
    // Debug 빌드는 배열 인덱싱마다 경계 검사, 산술마다 오버플로 검사를
    // 넣는데, 픽셀 100만 개를 도는 렌더링 루프에서 이게 두 자릿수 배율
    // 차이를 만든다. 측정 결과 clear가 4591us -> 1403us였다.
    //
    // b.standardOptimizeOption(.{ .preferred_optimize_mode = ... })를
    // 쓰지 않는 이유: 그 방식은 옵션 이름을 -Drelease(bool)로 바꾸고
    // 기본값은 여전히 Debug로 둔다. 여기서는 기본을 최적화 쪽에 두고
    // -Doptimize=Debug로 되돌릴 수 있게 직접 정의한다.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "빌드 모드 (Debug / ReleaseSafe / ReleaseFast / ReleaseSmall)",
    ) orelse .ReleaseFast;

    // 이름이 "bootx64"면 결과물은 bootx64.efi가 된다.
    // UEFI 펌웨어가 기본으로 찾는 경로가 \EFI\BOOT\BOOTX64.EFI 이기 때문에
    // 이 이름을 그대로 쓰면 부트 항목 등록 없이 자동으로 부팅된다.
    const exe = b.addExecutable(.{
        .name = "bootx64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // zig-out/efi/boot/bootx64.efi 위치에 설치
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "efi/boot" } },
    });
    b.getInstallStep().dependOn(&install.step);

    const is_windows = builtin.os.tag == .windows;

    // ── QEMU 실행 파일 ──────────────────────────────────────────────
    // PATH에 의존하지 않는다. 경로가 다르면:
    //   zig build run -Dqemu="D:/qemu/qemu-system-x86_64.exe"
    const qemu = b.option(
        []const u8,
        "qemu",
        "qemu-system-x86_64 실행 파일 경로",
    ) orelse if (is_windows)
        "C:/Program Files/qemu/qemu-system-x86_64.exe"
    else
        "qemu-system-x86_64";

    // ── EDK2 펌웨어 (분리형) ────────────────────────────────────────
    //
    // 요즘 QEMU에 들어있는 EDK2 펌웨어는 code / vars 두 파일로 나뉘어 있다.
    // 예전의 통합 OVMF.fd와 달리 -bios 옵션으로는 못 쓴다.
    // -bios는 이미지 크기가 64KB의 배수여야 하는데
    // edk2-x86_64-code.fd는 3,653,632바이트로 배수가 아니라 거부당한다.
    // (qemu: could not load PC BIOS ...)
    //
    // 대신 pflash 두 칸에 물린다:
    //   unit=0 → code (읽기 전용, 펌웨어 본체)
    //   unit=1 → vars (쓰기 가능, NVRAM 부트 변수 저장용)
    //
    // x86_64용 vars 파일은 따로 없고 i386용을 공용으로 쓴다.
    const ovmf_code = b.option(
        []const u8,
        "ovmf-code",
        "EDK2 code 이미지 경로 (읽기 전용)",
    ) orelse if (is_windows)
        "C:/Program Files/qemu/share/edk2-x86_64-code.fd"
    else
        "/usr/share/OVMF/OVMF_CODE.fd";

    // vars는 펌웨어가 기록하므로 쓰기 가능한 사본이어야 한다.
    // 설치 폴더의 원본을 그대로 쓰면 권한 문제로 실패한다.
    //   copy "C:\Program Files\qemu\share\edk2-i386-vars.fd" .\ovmf_vars.fd
    const ovmf_vars = b.option(
        []const u8,
        "ovmf-vars",
        "EDK2 vars 이미지 경로 (쓰기 가능한 사본)",
    ) orelse "ovmf_vars.fd";

    // ── QEMU 실행 ───────────────────────────────────────────────────
    const run = b.addSystemCommand(&.{
        qemu,

        // 펌웨어: pflash 슬롯 두 개
        "-drive",
        b.fmt("if=pflash,format=raw,unit=0,readonly=on,file={s}", .{ovmf_code}),
        "-drive",
        b.fmt("if=pflash,format=raw,unit=1,file={s}", .{ovmf_vars}),

        // zig-out 디렉터리를 FAT 디스크처럼 노출한다(VVFAT).
        // 디스크 이미지를 만들 필요가 없어서 편집→실행이 몇 초 안에 끝난다.
        "-drive",
        "format=raw,file=fat:rw:zig-out",

        // 하드웨어 가속. 이게 없으면 QEMU는 명령을 하나씩 번역해서
        // 실행하므로(TCG) 10~50배 느리고, TSC가 "호스트 시간"이 아니라
        // "실행한 명령 수"를 따라가서 시간 측정이 왜곡된다.
        //
        // 순서대로 시도하고 안 되면 tcg로 떨어진다.
        //   whpx : Windows (Hyper-V 플랫폼 활성화 필요)
        //   kvm  : Linux
        //   hvf  : macOS
        "-accel", "whpx,kernel-irqchip=off",
        "-accel", "kvm",
        "-accel", "hvf",
        "-accel", "tcg",

        "-serial",   "stdio",         // 시리얼 출력을 터미널로
        "-no-reboot",                 // 죽었을 때 무한 리부트 대신 정지
        "-net",      "none",          // PXE 부팅 시도를 건너뛰어 부팅이 빨라진다
        "-d",        "guest_errors",  // 잘못된 하드웨어 접근을 로그로
    });
    run.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "QEMU에서 실행");
    run_step.dependOn(&run.step);
}
