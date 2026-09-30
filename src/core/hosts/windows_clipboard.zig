//! Native Windows clipboard. Text goes on as CF_UNICODETEXT with CRLF line
//! endings and files as a CF_HDROP list, so pastes work in any application
//! without a helper process or a console code page in between. Images come
//! off as PNG: the registered "PNG" format when the source offers it, as
//! browsers and the Snipping Tool do, or else the CF_DIB bitmap re-encoded.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const flate = std.compress.flate;
const windows = std.os.windows;

const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;
const HWND = windows.HWND;

pub fn copyText(text: []const u8) bool {
    const units = encode(text, .text, null) + 1;
    const memory = GlobalAlloc(gmem_moveable, units * 2) orelse return false;
    const base = GlobalLock(memory) orelse return release(memory);
    const out: [*]u16 = @ptrCast(@alignCast(base));
    _ = encode(text, .text, out);
    out[units - 1] = 0;
    _ = GlobalUnlock(memory);
    return publish(cf_unicode_text, memory);
}

/// `path` must be absolute. The list holds one path and ends with an empty one.
pub fn copyFile(path: []const u8) bool {
    const units = encode(path, .path, null) + 2;
    const memory = GlobalAlloc(gmem_moveable | gmem_zeroinit, @sizeOf(DropFiles) + units * 2) orelse return false;
    const base: [*]u8 = @ptrCast(GlobalLock(memory) orelse return release(memory));
    const header: *DropFiles = @ptrCast(@alignCast(base));
    header.* = .{ .files_offset = @sizeOf(DropFiles), .wide = .TRUE };
    _ = encode(path, .path, @ptrCast(@alignCast(base + @sizeOf(DropFiles))));
    _ = GlobalUnlock(memory);
    return publish(cf_hdrop, memory);
}

pub const ReadImageError = error{ ClipboardUnavailable, UnsupportedBitmap } || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Returns the clipboard image as PNG bytes owned by the caller, or null when
/// the clipboard holds no image.
pub fn readImagePng(alloc: std.mem.Allocator) ReadImageError!?[]u8 {
    const png_format = RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("PNG"));
    const has_png = png_format != 0 and IsClipboardFormatAvailable(png_format).toBool();
    if (!has_png and !IsClipboardFormatAvailable(cf_dib).toBool()) return null;

    if (!open()) return error.ClipboardUnavailable;
    const bytes = copyData(alloc, if (has_png) png_format else cf_dib);
    _ = CloseClipboard();
    const data = try bytes orelse return null;
    if (has_png) return data;
    defer alloc.free(data);
    return try dibToPng(alloc, data);
}

fn copyData(alloc: std.mem.Allocator, format: c_uint) std.mem.Allocator.Error!?[]u8 {
    const memory = GetClipboardData(format) orelse return null;
    const base: [*]const u8 = @ptrCast(GlobalLock(memory) orelse return null);
    defer _ = GlobalUnlock(memory);
    return try alloc.dupe(u8, base[0..GlobalSize(memory)]);
}

/// Encodes a 24- or 32-bit CF_DIB as an opaque RGB PNG. Clipboard bitmaps
/// rarely carry meaningful alpha, and many leave it zeroed.
fn dibToPng(alloc: std.mem.Allocator, dib: []const u8) ReadImageError![]u8 {
    if (dib.len < 40) return error.UnsupportedBitmap;
    const header_len = std.mem.readInt(u32, dib[0..4], .little);
    const width = std.mem.readInt(i32, dib[4..8], .little);
    const signed_height = std.mem.readInt(i32, dib[8..12], .little);
    const bits = std.mem.readInt(u16, dib[14..16], .little);
    const compression = std.mem.readInt(u32, dib[16..20], .little);
    const palette_len = std.mem.readInt(u32, dib[32..36], .little);
    if (header_len < 40 or header_len > dib.len) return error.UnsupportedBitmap;
    if (bits != 24 and bits != 32) return error.UnsupportedBitmap;
    if (compression != bi_rgb and !(compression == bi_bitfields and bits == 32)) return error.UnsupportedBitmap;
    if (width <= 0 or width > max_dimension or signed_height == 0 or @abs(signed_height) > max_dimension) return error.UnsupportedBitmap;

    const columns: usize = @intCast(width);
    const rows: usize = @abs(signed_height);
    const pixel_bytes: usize = bits / 8;
    const stride = (columns * pixel_bytes + 3) & ~@as(usize, 3);
    const masks_len: usize = if (compression == bi_bitfields and header_len == 40) 12 else 0;
    const offset = header_len + masks_len + @as(usize, palette_len) * 4;
    if (offset > dib.len or stride * rows > dib.len - offset) return error.UnsupportedBitmap;
    const pixels = dib[offset..][0 .. stride * rows];

    var idat: std.Io.Writer.Allocating = try .initCapacity(alloc, 64 * 1024);
    defer idat.deinit();
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    const compress = try alloc.create(flate.Compress);
    defer alloc.destroy(compress);
    compress.* = try .init(&idat.writer, window, .zlib, .fastest);
    const line = try alloc.alloc(u8, 1 + columns * 3);
    defer alloc.free(line);
    line[0] = 0;
    for (0..rows) |row| {
        const source_row = if (signed_height > 0) rows - 1 - row else row;
        const source = pixels[source_row * stride ..][0 .. columns * pixel_bytes];
        for (0..columns) |column| {
            const pixel = source[column * pixel_bytes ..];
            line[1 + column * 3 ..][0..3].* = .{ pixel[2], pixel[1], pixel[0] };
        }
        try compress.writer.writeAll(line);
    }
    try compress.finish();

    var png: std.Io.Writer.Allocating = .init(alloc);
    errdefer png.deinit();
    try png.writer.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(columns), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(rows), .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 };
    try writeChunk(&png.writer, "IHDR", &ihdr);
    try writeChunk(&png.writer, "IDAT", idat.written());
    try writeChunk(&png.writer, "IEND", "");
    return png.toOwnedSlice();
}

fn writeChunk(writer: *std.Io.Writer, kind: *const [4]u8, data: []const u8) std.Io.Writer.Error!void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, crc.final(), .big);
}

fn publish(format: c_uint, memory: HANDLE) bool {
    if (!open()) return release(memory);
    defer _ = CloseClipboard();
    if (!EmptyClipboard().toBool()) return release(memory);
    if (SetClipboardData(format, memory) == null) return release(memory);
    return true;
}

/// Another application may hold the clipboard for a moment, as clipboard
/// managers do right after every change.
fn open() bool {
    for (0..open_attempts) |_| {
        if (OpenClipboard(null).toBool()) return true;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

fn release(memory: HANDLE) bool {
    _ = GlobalFree(memory);
    return false;
}

const Encoding = enum { text, path };

/// Returns the UTF-16 length of `bytes` and writes it to `out` when given.
/// Invalid UTF-8 becomes U+FFFD. Text gets CRLF line endings and paths get
/// backslash separators.
fn encode(bytes: []const u8, encoding: Encoding, out: ?[*]u16) usize {
    var len: usize = 0;
    var index: usize = 0;
    var previous: u21 = 0;
    while (index < bytes.len) {
        const decoded = decode(bytes[index..]);
        index += decoded.len;
        var codepoint = decoded.codepoint;
        switch (encoding) {
            .text => if (codepoint == '\n' and previous != '\r') put(out, &len, '\r'),
            .path => if (codepoint == '/') {
                codepoint = '\\';
            },
        }
        previous = codepoint;
        if (codepoint < 0x10000) {
            put(out, &len, @intCast(codepoint));
        } else {
            const offset = codepoint - 0x10000;
            put(out, &len, @intCast(0xd800 + (offset >> 10)));
            put(out, &len, @intCast(0xdc00 + (offset & 0x3ff)));
        }
    }
    return len;
}

const Decoded = struct { codepoint: u21, len: usize };

fn decode(bytes: []const u8) Decoded {
    const invalid: Decoded = .{ .codepoint = std.unicode.replacement_character, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return invalid;
    if (len > bytes.len) return invalid;
    const codepoint = std.unicode.utf8Decode(bytes[0..len]) catch return invalid;
    return .{ .codepoint = codepoint, .len = len };
}

fn put(out: ?[*]u16, len: *usize, unit: u16) void {
    if (out) |units| units[len.*] = unit;
    len.* += 1;
}

const open_attempts = 20;
const max_dimension = 16384;
const cf_dib: c_uint = 8;
const cf_unicode_text: c_uint = 13;
const cf_hdrop: c_uint = 15;
const bi_rgb: u32 = 0;
const bi_bitfields: u32 = 3;
const gmem_moveable: c_uint = 0x2;
const gmem_zeroinit: c_uint = 0x40;

const DropFiles = extern struct {
    files_offset: u32,
    x: i32 = 0,
    y: i32 = 0,
    non_client: BOOL = .FALSE,
    wide: BOOL,
};

extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn SetClipboardData(format: c_uint, memory: HANDLE) callconv(.winapi) ?HANDLE;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(format: c_uint) callconv(.winapi) ?HANDLE;
extern "user32" fn IsClipboardFormatAvailable(format: c_uint) callconv(.winapi) BOOL;
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) c_uint;
extern "kernel32" fn GlobalSize(memory: HANDLE) callconv(.winapi) usize;
extern "kernel32" fn GlobalAlloc(flags: c_uint, bytes: usize) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GlobalLock(memory: HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(memory: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalFree(memory: HANDLE) callconv(.winapi) ?HANDLE;

fn expectEncoded(bytes: []const u8, encoding: Encoding, expected: []const u16) !void {
    var buffer: [64]u16 = undefined;
    const len = encode(bytes, encoding, &buffer);
    try std.testing.expectEqual(len, encode(bytes, encoding, null));
    try std.testing.expectEqualSlices(u16, expected, buffer[0..len]);
}

test "windows clipboard text uses crlf line endings once" {
    try expectEncoded("a\nb\r\nc", .text, &.{ 'a', '\r', '\n', 'b', '\r', '\n', 'c' });
}

test "windows clipboard encodes utf-16 surrogates and replaces invalid bytes" {
    try expectEncoded("\u{e9}\u{1f600}", .text, &.{ 0xe9, 0xd83d, 0xde00 });
    try expectEncoded("a\xffb\xe2\x82", .text, &.{ 'a', 0xfffd, 'b', 0xfffd, 0xfffd });
}

fn testDib(height: i32, pixels: []const u8) [56]u8 {
    var dib = std.mem.zeroes([56]u8);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], height, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    @memcpy(dib[40..][0..pixels.len], pixels);
    return dib;
}

test "windows clipboard encodes a bottom-up bitmap as rgb png rows" {
    const alloc = std.testing.allocator;
    // BGRA with zeroed alpha: bottom row blue, green; top row red, white.
    const dib = testDib(2, &.{ 255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 255, 255, 255, 0 });
    const png = try dibToPng(alloc, &dib);
    defer alloc.free(png);

    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x02\x08\x02\x00\x00\x00", png[0..29]);
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", png[37..41]);
    var input: std.Io.Reader = .fixed(png[41..][0..idat_len]);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &window);
    const rows = try decompress.reader.allocRemaining(alloc, .unlimited);
    defer alloc.free(rows);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 255, 255, 0, 0, 0, 255, 0, 255, 0 }, rows);
    try std.testing.expect(std.mem.endsWith(u8, png, "\x00\x00\x00\x00IEND\xae\x42\x60\x82"));
}

test "windows clipboard rejects bitmaps shorter than their header claims" {
    const dib = testDib(-3, &.{});
    try std.testing.expectError(error.UnsupportedBitmap, dibToPng(std.testing.allocator, &dib));
}

test "windows clipboard file paths use backslashes" {
    try expectEncoded("C:/fx/trace.txt", .path, &.{ 'C', ':', '\\', 'f', 'x', '\\', 't', 'r', 'a', 'c', 'e', '.', 't', 'x', 't' });
}
