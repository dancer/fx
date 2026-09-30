//! Native Windows smoke check for the write_file/edit_file pipeline.
//!
//! The upstream test runner cannot host fx's Windows `Permissions` override,
//! so this executable drives target resolution, preparation, and apply the way
//! tool admission does and verifies the bytes on disk. Run it with
//! `zig build windows-file-smoke` on a Windows host.

const std = @import("std");
const builtin = @import("builtin");
const windows_io = @import("core/shared/windows_io.zig");
const io_mod = @import("core/shared/io.zig");
const permissions = @import("core/permissions/permissions.zig");
const file_mutation = @import("core/tooling/file_mutation.zig");
const contract = @import("core/tooling/file_mutation_contract.zig");
const types = @import("core/shared/types.zig");

pub const std_options_FilePermissions: ?type = if (builtin.os.tag == .windows) windows_io.Permissions else null;

const Outcome = union(enum) {
    committed: []const u8,
    failed: []const u8,
};

const Smoke = struct {
    alloc: std.mem.Allocator,
    root: []const u8,
    failures: usize = 0,

    fn print(comptime fmt: []const u8, args: anytype) void {
        var buffer: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, fmt ++ "\n", args) catch return;
        std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), line) catch {};
    }

    fn mutate(self: *Smoke, label: []const u8, input: contract.FileMutationInput) !Outcome {
        const call: types.ToolCall = .{
            .id = label,
            .name = switch (input) {
                .write => "write_file",
                .edit => "edit_file",
            },
            .arguments_json = label,
        };
        const policy = switch (try permissions.evaluateFileMutationTargets(self.alloc, self.root, input, .yolo, .{}, &.{}, &.{})) {
            .evaluated => |evaluated| evaluated,
            .target_resolution_failure => |failure| return .{ .failed = @tagName(failure) },
            .policy_denied => return .{ .failed = "policy_denied" },
        };
        const prepared = switch (try file_mutation.prepare(self.alloc, call, input, policy)) {
            .prepared => |prepared| prepared,
            .semantic_failure => |message| return .{ .failed = message },
        };
        var cancel = std.atomic.Value(bool).init(false);
        return switch (try file_mutation.apply(self.alloc, self.alloc, call, .{
            .input = input,
            .policy_targets = policy,
            .prepared = prepared,
        }, &cancel)) {
            .committed => |handoff| .{ .committed = handoff.tracker.raw_path },
            .rejected => |rejected| .{ .failed = @tagName(rejected.reason) },
        };
    }

    fn expectCommitted(
        self: *Smoke,
        label: []const u8,
        input: contract.FileMutationInput,
        check_path: []const u8,
        expected: []const u8,
    ) !void {
        switch (try self.mutate(label, input)) {
            .failed => |message| return self.fail(label, "committed", message),
            .committed => {},
        }
        const actual = try self.read(check_path);
        if (!std.mem.eql(u8, actual, expected)) return self.fail(label, expected, actual);
        print("ok    {s}", .{label});
    }

    fn expectFailed(self: *Smoke, label: []const u8, input: contract.FileMutationInput, expected: []const u8) !void {
        switch (try self.mutate(label, input)) {
            .committed => |committed_path| return self.fail(label, expected, committed_path),
            .failed => |message| {
                if (std.mem.find(u8, message, expected) == null) return self.fail(label, expected, message);
            },
        }
        print("ok    {s}", .{label});
    }

    fn fail(self: *Smoke, label: []const u8, expected: []const u8, actual: []const u8) void {
        self.failures += 1;
        print("FAIL  {s}\n      expected: {f}\n      actual:   {f}", .{ label, std.zig.fmtString(expected), std.zig.fmtString(actual) });
    }

    fn path(self: *Smoke, relative: []const u8) []const u8 {
        return std.fs.path.join(self.alloc, &.{ self.root, relative }) catch @panic("OOM");
    }

    fn read(self: *Smoke, relative: []const u8) ![]const u8 {
        const zio = io_mod.getIo();
        var file = try std.Io.Dir.cwd().openFile(zio, self.path(relative), .{});
        defer file.close(zio);
        return io_mod.readFileToEnd(self.alloc, &file, 1 << 20);
    }

    fn create(self: *Smoke, relative: []const u8, content: []const u8) !void {
        const zio = io_mod.getIo();
        var file = try std.Io.Dir.cwd().createFile(zio, self.path(relative), .{});
        defer file.close(zio);
        try file.writeStreamingAll(zio, content);
    }

    fn junction(self: *Smoke, link: []const u8, target: []const u8) !void {
        const result = try std.process.run(self.alloc, io_mod.getIo(), .{
            .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link, target },
        });
        if (result.term != .exited or result.term.exited != 0) return error.JunctionFailed;
    }

    fn write(self: *Smoke, target: []const u8, content: []const u8) contract.FileMutationInput {
        return .{ .write = .{ .path = self.dupe(target), .content = self.dupe(content) } };
    }

    fn edit(self: *Smoke, target: []const u8, old: []const u8, new: []const u8) contract.FileMutationInput {
        return .{ .edit = .{ .path = self.dupe(target), .old_string = self.dupe(old), .new_string = self.dupe(new) } };
    }

    fn dupe(self: *Smoke, bytes: []const u8) []u8 {
        return self.alloc.dupe(u8, bytes) catch @panic("OOM");
    }
};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.WindowsOnly;
    io_mod.setIo(init.io);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    _ = args.next();
    const scratch = args.next() orelse return error.MissingScratchDirectory;
    const failures = try runChecks(init.arena.allocator(), scratch);
    if (failures != 0) {
        Smoke.print("{d} Windows file smoke check(s) failed", .{failures});
        std.process.exit(1);
    }
    Smoke.print("all Windows file smoke checks passed", .{});
}

fn runChecks(alloc: std.mem.Allocator, base_arg: []const u8) !usize {
    const zio = io_mod.getIo();

    std.Io.Dir.cwd().deleteTree(zio, base_arg) catch {};
    try std.Io.Dir.cwd().createDirPath(zio, base_arg);
    defer std.Io.Dir.cwd().deleteTree(zio, base_arg) catch {};
    const base = try io_mod.realpathAlloc(alloc, base_arg);
    const workspace = try std.fs.path.join(alloc, &.{ base, "workspace" });
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    for ([_][]const u8{ workspace, outside, try std.fs.path.join(alloc, &.{ workspace, "lib", "new" }) }) |dir| {
        try std.Io.Dir.cwd().createDirPath(zio, dir);
    }

    var smoke: Smoke = .{ .alloc = alloc, .root = workspace };
    try smoke.junction(smoke.path("inner"), smoke.path("lib\\new"));
    try smoke.junction(smoke.path("escape"), outside);
    try smoke.create("crlf.txt", "one\r\ntwo\r\n");
    try smoke.create("crlf-rewrite.txt", "x\r\ny\r\n");
    try smoke.create("held.txt", "held\n");
    try smoke.create("read-only.txt", "locked\n");
    var read_only = try std.Io.Dir.cwd().openFile(zio, smoke.path("read-only.txt"), .{ .mode = .read_write });
    defer read_only.close(zio);
    try read_only.setPermissions(zio, .fromMode(0o444));
    defer read_only.setPermissions(zio, .fromMode(0o644)) catch {};

    const notes_abs = smoke.path("notes.txt");
    const notes_forward = try std.mem.replaceOwned(u8, alloc, notes_abs, "\\", "/");
    const notes_lower = try std.ascii.allocLowerString(alloc, notes_abs);
    const outside_file = try std.fs.path.join(alloc, &.{ outside, "outside.txt" });

    try smoke.expectCommitted("write relative", smoke.write("notes.txt", "a\n"), "notes.txt", "a\n");
    try smoke.expectCommitted("write creates parents", smoke.write("lib/new/deep.txt", "deep\n"), "lib\\new\\deep.txt", "deep\n");
    try smoke.expectCommitted("edit relative", smoke.edit("notes.txt", "a", "b"), "notes.txt", "b\n");
    try smoke.expectCommitted("edit backslash relative", smoke.edit("lib\\new\\deep.txt", "deep", "deeper"), "lib\\new\\deep.txt", "deeper\n");
    try smoke.expectCommitted("edit absolute", smoke.edit(notes_abs, "b", "c"), "notes.txt", "c\n");
    try smoke.expectCommitted("edit absolute forward slashes", smoke.edit(notes_forward, "c", "d"), "notes.txt", "d\n");
    try smoke.expectCommitted("edit absolute lowercase", smoke.edit(notes_lower, "d", "e"), "notes.txt", "e\n");
    try smoke.expectCommitted("edit name case mismatch", smoke.edit("NOTES.txt", "e", "f"), "notes.txt", "f\n");
    try smoke.expectCommitted("edit through dot-dot", smoke.edit("lib/../notes.txt", "f", "g"), "notes.txt", "g\n");
    try smoke.expectCommitted("edit through inner junction", smoke.edit("inner/deep.txt", "deeper", "inner"), "lib\\new\\deep.txt", "inner\n");
    try smoke.expectCommitted("edit crlf multi-line", smoke.edit("crlf.txt", "one\ntwo", "1\n2"), "crlf.txt", "1\r\n2\r\n");
    try smoke.expectCommitted("edit crlf inserts crlf", smoke.edit("crlf.txt", "2", "2\n3"), "crlf.txt", "1\r\n2\r\n3\r\n");
    try smoke.expectCommitted("write keeps crlf", smoke.write("crlf-rewrite.txt", "a\nb\n"), "crlf-rewrite.txt", "a\r\nb\r\n");
    try smoke.expectCommitted("write outside workspace", smoke.write(outside_file, "out\n"), "..\\outside\\outside.txt", "out\n");
    try smoke.expectCommitted("edit outside workspace", smoke.edit(outside_file, "out", "moved"), "..\\outside\\outside.txt", "moved\n");
    {
        var held = try std.Io.Dir.cwd().openFile(zio, smoke.path("held.txt"), .{});
        defer held.close(zio);
        try smoke.expectCommitted("edit file held open", smoke.edit("held.txt", "held", "replaced"), "held.txt", "replaced\n");
    }

    try smoke.expectFailed("edit read-only file", smoke.edit("read-only.txt", "locked", "open"), "io_failure");
    try smoke.expectFailed("escape through junction", smoke.write("escape/x.txt", "x"), "path_outside_workspace");
    try smoke.expectFailed("alternate data stream", smoke.write("notes.txt:stream", "x"), "bad_path_name");
    try smoke.expectFailed("drive-relative path", smoke.write("C:relative.txt", "x"), "bad_path_name");
    try smoke.expectFailed("rooted path without drive", smoke.write("\\fx-smoke\\x.txt", "x"), "invalid_path");
    try smoke.expectFailed("edit missing file", smoke.edit("missing.txt", "a", "b"), "file_not_found");

    const read_only_content = try smoke.read("read-only.txt");
    if (!std.mem.eql(u8, read_only_content, "locked\n")) smoke.fail("read-only file untouched", "locked\n", read_only_content);
    return smoke.failures;
}
