//! 프레임버퍼와 캔버스.
//!
//! 설계상 둘을 분리한다:
//!
//!   Canvas      — 일반 메모리에 있는 백버퍼. 모든 그리기가 여기서 일어난다.
//!   Framebuffer — 실제 화면. 하는 일은 캔버스를 한 번에 복사하는 것뿐.
//!
//! 왜 나누는가:
//!   1) 화면 메모리(MMIO)는 캐시가 안 먹어서 픽셀 단위 쓰기가 느리다.
//!      일반 메모리에 그리고 한 번에 옮기면 훨씬 빠르다.
//!   2) 그리는 도중의 중간 상태가 화면에 보이지 않는다(테어링/깜빡임 방지).
//!   3) 게임 루프의 "update → render → present" 구조와 그대로 맞는다.

const std = @import("std");
const uefi = std.os.uefi;
const font = @import("font.zig");

const GraphicsOutput = uefi.protocol.GraphicsOutput;
const PixelFormat = GraphicsOutput.PixelFormat;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
};

pub const Error = error{UnsupportedPixelFormat};

/// Color를 하드웨어 픽셀 값으로 변환.
///
/// 포맷 이름은 "메모리에 놓이는 바이트 순서"를 말한다.
/// x86은 리틀엔디안이라 u32의 최하위 바이트가 메모리 첫 바이트가 되므로,
/// BGR 포맷이면 u32 = (R << 16) | (G << 8) | B 가 된다.
inline fn encode(format: PixelFormat, c: Color) u32 {
    const r: u32 = c.r;
    const g: u32 = c.g;
    const b: u32 = c.b;
    return switch (format) {
        .blue_green_red_reserved_8_bit_per_color => (r << 16) | (g << 8) | b,
        .red_green_blue_reserved_8_bit_per_color => (b << 16) | (g << 8) | r,
        else => unreachable, // Framebuffer.init에서 걸러낸다
    };
}

// ─────────────────────────────────────────────────────────────────────
// Canvas — 백버퍼. 모든 그리기는 여기서.
// ─────────────────────────────────────────────────────────────────────

pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    format: PixelFormat,

    pub inline fn setPixel(self: Canvas, x: u32, y: u32, c: Color) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.width + x] = encode(self.format, c);
    }

    pub fn clear(self: Canvas, c: Color) void {
        @memset(self.pixels, encode(self.format, c));
    }

    pub fn fillRect(self: Canvas, x0: u32, y0: u32, w: u32, h: u32, c: Color) void {
        const value = encode(self.format, c);
        const x_end = @min(x0 + w, self.width);
        const y_end = @min(y0 + h, self.height);
        if (x0 >= x_end) return;

        var y = y0;
        while (y < y_end) : (y += 1) {
            const row = y * self.width;
            @memset(self.pixels[row + x0 .. row + x_end], value);
        }
    }

    /// 화면 가장자리 테두리. 좌표 계산 검증용으로 쓰기 좋다.
    pub fn drawBorder(self: Canvas, t: u32, c: Color) void {
        self.fillRect(0, 0, self.width, t, c);
        self.fillRect(0, self.height - t, self.width, t, c);
        self.fillRect(0, 0, t, self.height, c);
        self.fillRect(self.width - t, 0, t, self.height, c);
    }

    pub fn gradient(self: Canvas) void {
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const v: u32 = (y * 255) / (self.height - 1);
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const u: u32 = (x * 255) / (self.width - 1);
                self.setPixel(x, y, .{
                    .r = @intCast(u),
                    .g = @intCast((u + v) / 2),
                    .b = @intCast(v),
                });
            }
        }
    }

    /// 글자 하나. scale로 정수배 확대할 수 있다.
    pub fn drawChar(self: Canvas, x: u32, y: u32, ch: u8, c: Color, scale: u32) void {
        const g = font.glyph(ch);
        for (g, 0..) |bits, ry| {
            var rx: u3 = 0;
            while (true) : (rx += 1) {
                // bit 0이 왼쪽 픽셀이므로 시프트 방향과 x 방향이 일치한다
                if ((bits >> rx) & 1 == 1) {
                    const px = x + @as(u32, rx) * scale;
                    const py = y + @as(u32, @intCast(ry)) * scale;
                    self.fillRect(px, py, scale, scale, c);
                }
                if (rx == 7) break;
            }
        }
    }

    /// 문자열. '\n'을 만나면 다음 줄로 내려간다.
    pub fn drawString(self: Canvas, x: u32, y: u32, s: []const u8, c: Color, scale: u32) void {
        var cx = x;
        var cy = y;
        for (s) |ch| {
            if (ch == '\n') {
                cx = x;
                cy += (font.glyph_height + 2) * scale; // 줄간격 2px
                continue;
            }
            self.drawChar(cx, cy, ch, c, scale);
            cx += font.glyph_width * scale;
        }
    }
};

// ─────────────────────────────────────────────────────────────────────
// Framebuffer — 실제 화면
// ─────────────────────────────────────────────────────────────────────

pub const Framebuffer = struct {
    base: u64,
    width: u32,
    height: u32,
    /// 한 줄에 실제로 들어있는 픽셀 수. width와 다를 수 있다.
    /// 하드웨어가 줄 시작 주소를 정렬하려고 여분을 두기 때문인데,
    /// 이걸 무시하고 width로 계산하면 화면이 사선으로 기울어진다.
    stride: u32,
    format: PixelFormat,

    pub fn init(gop: *GraphicsOutput) Error!Framebuffer {
        const info = gop.mode.info;

        switch (info.pixel_format) {
            .red_green_blue_reserved_8_bit_per_color,
            .blue_green_red_reserved_8_bit_per_color,
            => {},
            // bit_mask는 마스크를 해석해야 하고, blt_only는 직접 접근이 불가능하다.
            .bit_mask, .blt_only => return Error.UnsupportedPixelFormat,
        }

        return .{
            .base = gop.mode.frame_buffer_base,
            .width = info.horizontal_resolution,
            .height = info.vertical_resolution,
            .stride = info.pixels_per_scan_line,
            .format = info.pixel_format,
        };
    }

    pub fn pixelCount(self: Framebuffer) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    /// 화면 메모리의 실제 바이트 크기. stride를 써야 한다 -
    /// width로 계산하면 마지막 줄 일부가 매핑에서 빠진다.
    pub fn byteSize(self: Framebuffer) u64 {
        return @as(u64, self.stride) * @as(u64, self.height) * 4;
    }

    /// 주어진 버퍼로 Canvas를 만든다. 버퍼는 width*height 이상이어야 한다.
    pub fn canvas(self: Framebuffer, buffer: []u32) Canvas {
        return .{
            .pixels = buffer[0..self.pixelCount()],
            .width = self.width,
            .height = self.height,
            .format = self.format,
        };
    }

    /// 백버퍼를 화면으로. 줄 단위로 복사하는 이유는 stride 때문이다.
    /// 캔버스는 width 간격, 화면은 stride 간격이라 통째로 복사할 수 없다.
    pub fn present(self: Framebuffer, c: Canvas) void {
        const dst: [*]u32 = @ptrFromInt(self.base);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const src_row = c.pixels[y * c.width ..][0..self.width];
            const dst_row = dst[y * self.stride ..][0..self.width];
            @memcpy(dst_row, src_row);
        }
    }
};
