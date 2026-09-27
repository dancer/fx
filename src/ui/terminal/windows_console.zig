//! Windows console backend for the interactive terminal, in the role
//! `wasm_terminal.zig` plays for JavaScript hosts. Input is switched to
//! virtual-terminal mode so keys arrive as the same escape sequences a POSIX
//! tty sends, which keeps the shared input parser platform-neutral. Input is
//! read as UTF-16 and converted, so only the output code page needs UTF-8.

const std = @import("std");
const types = @import("../../core/shared/types.zig");
const io_mod = @import("../../core/shared/io.zig");
const terminal = @import("terminal.zig");

const windows = std.os.windows;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const UINT = windows.UINT;
const WCHAR = windows.WCHAR;

const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
const CP_UTF8: UINT = 65001;
const WAIT_OBJECT_0: DWORD = 0x0000;
const WAIT_TIMEOUT: DWORD = 0x0102;
const INFINITE: DWORD = 0xFFFF_FFFF;
const KEY_EVENT: u16 = 0x0001;
const VK_RETURN: u16 = 0x000D;

const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    UnicodeChar: WCHAR,
    dwControlKeyState: DWORD,
};

const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        /// The mouse record shares the 16-byte size of the key record.
        raw: [16]u8,
    },
};

comptime {
    std.debug.assert(@sizeOf(INPUT_RECORD) == 20);
}

extern "kernel32" fn GetConsoleMode(console: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(console: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(console: HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleW(console: HANDLE, buffer: [*]WCHAR, to_read: DWORD, read: *DWORD, control: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn PeekConsoleInputW(console: HANDLE, buffer: [*]INPUT_RECORD, length: DWORD, read: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleInputW(console: HANDLE, buffer: [*]INPUT_RECORD, length: DWORD, read: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
extern "kernel32" fn SetConsoleOutputCP(code_page: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const anyopaque, add: BOOL) callconv(.winapi) BOOL;

pub const Size = struct {
    cols: u16,
    rows: u16,
};

/// Console state saved before raw mode so it can be restored exactly.
pub const Modes = struct {
    input: DWORD = 0,
    /// Null when stdout is redirected, leaving no output mode to manage.
    output: ?DWORD = null,
};

var original_output_code_page: ?UINT = null;

/// The console decodes written bytes with its output code page, and fx
/// writes UTF-8 everywhere, so switch it for the whole run. The code page is
/// shared with the parent shell, hence `endUtf8Output` on every exit path.
pub fn beginUtf8Output() void {
    if (original_output_code_page != null) return;
    const current = GetConsoleOutputCP();
    if (current == 0 or current == CP_UTF8) return;
    if (SetConsoleOutputCP(CP_UTF8).toBool()) original_output_code_page = current;
}

pub fn endUtf8Output() void {
    const code_page = original_output_code_page orelse return;
    _ = SetConsoleOutputCP(code_page);
    original_output_code_page = null;
}

fn stdinHandle() HANDLE {
    return std.Io.File.stdin().handle;
}

fn stdoutHandle() HANDLE {
    return std.Io.File.stdout().handle;
}

/// With no handler routine this toggles whether the process ignores Ctrl+C,
/// which is Windows' equivalent of setting SIGINT to SIG_IGN.
pub fn ignoreCtrlC(ignore: bool) bool {
    return SetConsoleCtrlHandler(null, .fromBool(ignore)).toBool();
}

pub fn isConsole(handle: HANDLE) bool {
    var mode: DWORD = 0;
    return GetConsoleMode(handle, &mode).toBool();
}

pub fn isInteractive() bool {
    return isConsole(stdinHandle()) and isConsole(stdoutHandle());
}

pub fn captureModes() !Modes {
    var modes: Modes = .{};
    if (!GetConsoleMode(stdinHandle(), &modes.input).toBool()) return error.NotATerminal;
    var output: DWORD = 0;
    if (GetConsoleMode(stdoutHandle(), &output).toBool()) modes.output = output;
    return modes;
}

pub fn enableRawMode(original: Modes) !void {
    const input = (original.input & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)) |
        ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT;
    if (!SetConsoleMode(stdinHandle(), input).toBool()) return error.Unexpected;
    if (original.output) |output| {
        const vt_output = output | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        if (!SetConsoleMode(stdoutHandle(), vt_output).toBool()) return error.Unexpected;
    }
    pending = .{};
}

pub fn restoreModes(original: Modes) void {
    _ = SetConsoleMode(stdinHandle(), original.input);
    if (original.output) |output| _ = SetConsoleMode(stdoutHandle(), output);
}

pub fn querySize() !Size {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (!GetConsoleScreenBufferInfo(stdoutHandle(), &info).toBool()) return error.UnableToReadTerminalSize;
    const cols = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
    const rows = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
    if (cols <= 0 or rows <= 0) return error.UnableToReadTerminalSize;
    return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
}

pub fn queryLayout(footer_rows: u16) !types.Layout {
    const size = try querySize();
    return terminal.layoutFromSize(size.rows, size.cols, footer_rows);
}

/// UTF-8 decoded from console input but not yet handed to a caller, since
/// callers may read one byte at a time. A high surrogate is held back until
/// its partner arrives so pairs are never split across reads.
const Pending = struct {
    bytes: [128]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    high_surrogate: ?WCHAR = null,

    fn buffered(self: Pending) []const u8 {
        return self.bytes[self.start..self.end];
    }
};

var pending: Pending = .{};

/// Waits up to `timeout_ms` (negative waits indefinitely) for text input.
/// Resize, focus, and mouse records are drained along the way so they can
/// never leave the wait spinning; the event loop polls geometry separately.
pub fn pollInput(timeout_ms: i32) !bool {
    if (pending.buffered().len > 0) return true;
    const handle = stdinHandle();
    const deadline: ?i64 = if (timeout_ms < 0) null else io_mod.milliTimestamp() + timeout_ms;
    while (true) {
        const wait_ms: DWORD = if (deadline) |at| @intCast(@max(at - io_mod.milliTimestamp(), 0)) else INFINITE;
        switch (WaitForSingleObject(handle, wait_ms)) {
            WAIT_OBJECT_0 => {},
            WAIT_TIMEOUT => return false,
            else => return error.Unexpected,
        }
        if (try discardUntilText(handle)) return true;
        if (deadline) |at| if (io_mod.milliTimestamp() >= at) return false;
    }
}

/// Returns true once a text-producing key is queued, consuming any
/// non-text records ahead of it.
fn discardUntilText(handle: HANDLE) !bool {
    var records: [32]INPUT_RECORD = undefined;
    var count: DWORD = 0;
    if (!PeekConsoleInputW(handle, &records, records.len, &count).toBool()) return error.Unexpected;
    for (records[0..count]) |record| {
        if (producesText(record)) return true;
    }
    if (count == 0) return false;
    var discarded: DWORD = 0;
    if (!ReadConsoleInputW(handle, &records, count, &discarded).toBool()) return error.Unexpected;
    return false;
}

fn producesText(record: INPUT_RECORD) bool {
    if (record.EventType != KEY_EVENT) return false;
    const key = record.Event.KeyEvent;
    return key.bKeyDown.toBool() and key.UnicodeChar != 0;
}

pub fn read(out: []u8) !usize {
    if (out.len == 0) return 0;
    if (pending.buffered().len == 0) try fill();
    const available = pending.buffered();
    const n = @min(out.len, available.len);
    @memcpy(out[0..n], available[0..n]);
    pending.start += n;
    return n;
}

fn fill() !void {
    var units: [32]WCHAR = undefined;
    var offset: usize = 0;
    if (pending.high_surrogate) |high| {
        units[0] = high;
        offset = 1;
        pending.high_surrogate = null;
    }
    var count: DWORD = 0;
    const want: DWORD = @intCast(units.len - offset);
    if (!ReadConsoleW(stdinHandle(), units[offset..].ptr, want, &count, null).toBool()) return error.Unexpected;
    var len = offset + count;
    if (len > 0 and std.unicode.utf16IsHighSurrogate(units[len - 1])) {
        pending.high_surrogate = units[len - 1];
        len -= 1;
    }
    pending.start = 0;
    pending.end = std.unicode.wtf16LeToWtf8(&pending.bytes, units[0..len]);
}

/// A queued Enter means a line-mode read returns a whole line rather than
/// blocking, which is what polling a canonical POSIX tty reports.
fn enterQueued(handle: HANDLE) bool {
    var records: [128]INPUT_RECORD = undefined;
    var count: DWORD = 0;
    if (!PeekConsoleInputW(handle, &records, records.len, &count).toBool()) return false;
    for (records[0..count]) |record| {
        if (record.EventType != KEY_EVENT) continue;
        const key = record.Event.KeyEvent;
        if (key.bKeyDown.toBool() and key.wVirtualKeyCode == VK_RETURN) return true;
    }
    return false;
}

/// Reads one line-mode line without blocking: null until Enter is queued,
/// then its UTF-8 bytes, terminator stripped, written to `out`.
pub fn readQueuedLine(out: []u8) !?usize {
    const handle = stdinHandle();
    if (!isConsole(handle) or !enterQueued(handle)) return null;
    var len: usize = 0;
    var overflow = false;
    while (true) {
        var units: [256]WCHAR = undefined;
        var count: DWORD = 0;
        if (!ReadConsoleW(handle, &units, units.len, &count, null).toBool()) return error.Unexpected;
        if (count == 0) break;
        var chunk: []const WCHAR = units[0..count];
        const complete = chunk[chunk.len - 1] == '\n';
        while (chunk.len > 0 and (chunk[chunk.len - 1] == '\n' or chunk[chunk.len - 1] == '\r')) {
            chunk = chunk[0 .. chunk.len - 1];
        }
        var utf8: [units.len * 3]u8 = undefined;
        const n = std.unicode.wtf16LeToWtf8(&utf8, chunk);
        if (len + n > out.len) {
            overflow = true;
        } else {
            @memcpy(out[len..][0..n], utf8[0..n]);
            len += n;
        }
        if (complete) break;
    }
    if (overflow) return error.LineTooLong;
    return len;
}

/// Returns true once Enter is pressed within `timeout_ms`, consuming the
/// line. Typing without Enter does not end the wait early.
pub fn waitForEnter(timeout_ms: u64) bool {
    if (!isConsole(stdinHandle())) return false;
    const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
    while (true) {
        var discard: [1024]u8 = undefined;
        if (readQueuedLine(&discard)) |line| {
            if (line != null) return true;
        } else |err| return err == error.LineTooLong;
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return false;
        // Queued keystrokes keep the input handle signaled, so pace checks
        // with a sleep rather than a wait that would return immediately.
        Sleep(@intCast(@min(remaining, 25)));
    }
}

test "input record matches the Win32 layout" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(INPUT_RECORD));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(INPUT_RECORD, "Event"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(KEY_EVENT_RECORD, "UnicodeChar"));
}

test "only key-down records with a character produce text" {
    var record: INPUT_RECORD = .{ .EventType = KEY_EVENT, .Event = .{ .raw = @splat(0) } };
    record.Event.KeyEvent.bKeyDown = .TRUE;
    record.Event.KeyEvent.UnicodeChar = 'a';
    try std.testing.expect(producesText(record));

    record.Event.KeyEvent.UnicodeChar = 0;
    try std.testing.expect(!producesText(record));

    record.Event.KeyEvent.UnicodeChar = 'a';
    record.Event.KeyEvent.bKeyDown = .FALSE;
    try std.testing.expect(!producesText(record));

    record.EventType = 0x0004;
    record.Event.KeyEvent.bKeyDown = .TRUE;
    try std.testing.expect(!producesText(record));
}
