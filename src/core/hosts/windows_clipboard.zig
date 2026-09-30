//! Native Windows clipboard. Text goes on as CF_UNICODETEXT with CRLF line
//! endings and files as a CF_HDROP list, so pastes work in any application
//! without a helper process or a console code page in between.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
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
const cf_unicode_text: c_uint = 13;
const cf_hdrop: c_uint = 15;
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

test "windows clipboard file paths use backslashes" {
    try expectEncoded("C:/fx/trace.txt", .path, &.{ 'C', ':', '\\', 'f', 'x', '\\', 't', 'r', 'a', 'c', 'e', '.', 't', 'x', 't' });
}
