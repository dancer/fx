//! The C runtime passes `main` its arguments and environment in the ANSI code
//! page, which mangles anything outside it. These rebuild both as UTF-8 from
//! the process's wide-character originals, in the shapes a POSIX `main`
//! receives, so the rest of startup stays platform-neutral.
//!
//! Everything returned lives for the rest of the process, like the C
//! runtime's own `argv` and `envp`.

const std = @import("std");
const io = @import("io.zig");

pub fn commandLine() []const u16 {
    return std.os.windows.peb().ProcessParameters.CommandLine.slice();
}

pub fn utf8Args(alloc: std.mem.Allocator) ![]const [*:0]const u8 {
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = commandLine() }, alloc);
    var list: std.ArrayList([*:0]const u8) = .empty;
    while (args.next()) |arg| try list.append(alloc, arg.ptr);
    return list.toOwnedSlice(alloc);
}

pub fn utf8Environ(alloc: std.mem.Allocator) !io.RawEnviron {
    var map = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer map.deinit();
    const block = try map.createPosixBlock(alloc, .{});
    return block.slice.ptr;
}

test "UTF-8 args include the program name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try utf8Args(arena.allocator());
    try std.testing.expect(args.len >= 1);
    try std.testing.expect(std.mem.span(args[0]).len > 0);
}

test "UTF-8 environ is null-terminated and carries PATH" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const environ = try utf8Environ(arena.allocator());
    var found_path = false;
    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(std.mem.span(entry), "PATH=")) found_path = true;
    }
    try std.testing.expect(found_path);
}
