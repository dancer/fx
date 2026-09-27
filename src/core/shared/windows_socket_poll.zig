//! Readiness polling for `std.Io.net` sockets on Windows. Zig opens those
//! sockets directly on the AFD driver rather than through Winsock, so WSAPoll
//! rejects them as non-sockets. AFD's own poll request, which Winsock itself
//! builds on, works on them, and is issued through `std.Io` the same way Zig's
//! networking talks to AFD.

const std = @import("std");
const io_mod = @import("io.zig");

const windows = std.os.windows;

pub const Interest = enum { accept, receive };

pub const Readiness = enum {
    timeout,
    /// The requested event fired.
    ready,
    /// The connection closed, reset, or failed without the requested event.
    closed,
};

// AFD poll event bits, as used by Winsock, libuv, and wepoll.
const AFD_POLL_RECEIVE: windows.ULONG = 0x0001;
const AFD_POLL_DISCONNECT: windows.ULONG = 0x0008;
const AFD_POLL_ABORT: windows.ULONG = 0x0010;
const AFD_POLL_LOCAL_CLOSE: windows.ULONG = 0x0020;
const AFD_POLL_ACCEPT: windows.ULONG = 0x0080;

const closed_events = AFD_POLL_DISCONNECT | AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE;

const PollHandleInfo = extern struct {
    Handle: windows.HANDLE,
    Events: windows.ULONG,
    Status: windows.NTSTATUS,
};

const PollInfo = extern struct {
    /// Negative values are relative, in 100-nanosecond units.
    Timeout: windows.LARGE_INTEGER,
    NumberOfHandles: windows.ULONG,
    Exclusive: windows.ULONG,
    Handles: [1]PollHandleInfo,
};

/// Waits up to `timeout_ms` for a pending connection (`accept`) or data
/// (`receive`) on `handle`. A zero timeout checks once without waiting.
pub fn wait(handle: windows.HANDLE, interest: Interest, timeout_ms: u32) !Readiness {
    const wanted: windows.ULONG = switch (interest) {
        .accept => AFD_POLL_ACCEPT,
        .receive => AFD_POLL_RECEIVE,
    };
    var info: PollInfo = .{
        .Timeout = -@as(windows.LARGE_INTEGER, timeout_ms) * 10_000,
        .NumberOfHandles = 1,
        .Exclusive = 0,
        .Handles = .{.{ .Handle = handle, .Events = wanted | closed_events, .Status = .SUCCESS }},
    };
    const result = try io_mod.getIo().operate(.{ .device_io_control = .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.POLL,
        .in = std.mem.asBytes(&info),
        .out = std.mem.asBytes(&info),
    } });
    switch (result.device_io_control.u.Status) {
        .SUCCESS => {},
        .TIMEOUT => return .timeout,
        else => |status| return windows.unexpectedStatus(status),
    }
    return classify(info.NumberOfHandles, info.Handles[0].Events, wanted);
}

fn classify(signaled_handles: windows.ULONG, events: windows.ULONG, wanted: windows.ULONG) Readiness {
    if (signaled_handles == 0) return .timeout;
    if (events & wanted != 0) return .ready;
    if (events & closed_events != 0) return .closed;
    return .timeout;
}

test "poll request matches the AFD layout" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PollInfo));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PollInfo, "Handles"));
}

test "readiness prefers the requested event over a close" {
    try std.testing.expectEqual(Readiness.timeout, classify(0, AFD_POLL_RECEIVE, AFD_POLL_RECEIVE));
    try std.testing.expectEqual(Readiness.ready, classify(1, AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT, AFD_POLL_RECEIVE));
    try std.testing.expectEqual(Readiness.closed, classify(1, AFD_POLL_ABORT, AFD_POLL_ACCEPT));
}
