//! Io adapter for gaps in std's Windows file handling, installed by
//! `io.setIo` the way the Darwin process-spawn adapter is.
//!
//! Permissions: Windows has no POSIX file modes. std models them as file
//! attributes, reports one placeholder value from every stat, and panics on
//! directory chmod. fx relies on the ACLs inherited from the user profile to
//! keep private state private instead, so `Permissions` stands in with mode
//! bits (letting shared `toMode`/`fromMode` call sites compile unchanged) and
//! the adapter reports the private modes fx verifies.
//!
//! No-follow opens: std opens those handles for asynchronous I/O but reports
//! them as synchronous, so any read Windows completes asynchronously reaches
//! an `unreachable`. The adapter reports the mode the handle really has.
//!
//! Write-only handles: std requests GENERIC_WRITE alone, which lacks the
//! FILE_READ_ATTRIBUTES that stat and length need, while fx verifies files
//! right after creating them the way POSIX fstat allows. The adapter adds
//! read access to handles opened for writing.

const std = @import("std");
const windows = std.os.windows;

pub const Permissions = enum(std.posix.mode_t) {
    default_file = 0o666,
    default_dir = 0o777,
    _,

    pub const executable_file: Permissions = .default_dir;
    pub const has_executable_bit = false;

    pub fn fromMode(mode: std.posix.mode_t) Permissions {
        return @enumFromInt(mode);
    }

    pub fn toMode(self: Permissions) std.posix.mode_t {
        return @intFromEnum(self);
    }

    pub fn readOnly(self: Permissions) bool {
        return self.toMode() & 0o222 == 0;
    }

    pub fn setReadOnly(self: Permissions, read_only: bool) Permissions {
        const mode = self.toMode();
        return .fromMode(if (read_only) mode & ~@as(std.posix.mode_t, 0o222) else mode | 0o222);
    }

    /// NORMAL is only valid alone, and is what clears a previous READONLY.
    pub fn toAttributes(self: Permissions) windows.FILE.ATTRIBUTE {
        return if (self.readOnly()) .{ .READONLY = true } else .{ .NORMAL = true };
    }
};

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;

pub fn wrap(original: std.Io) std.Io {
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.fileStat = file_stat;
        wrapped_vtable.dirStat = dir_stat;
        wrapped_vtable.dirStatFile = dir_stat_file;
        wrapped_vtable.dirSetPermissions = dir_set_permissions;
        wrapped_vtable.dirSetFilePermissions = dir_set_file_permissions;
        wrapped_vtable.dirOpenFile = dir_open_file;
        wrapped_vtable.dirCreateFile = dir_create_file;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

fn inner() *const std.Io.VTable {
    return wrapped_original_vtable.?;
}

/// Reports the modes fx's private-state checks expect, since access is
/// governed by inherited ACLs rather than anything stat can express.
fn with_private_mode(stat: std.Io.File.Stat) std.Io.File.Stat {
    var result = stat;
    result.permissions = .fromMode(if (stat.kind == .directory) 0o700 else 0o600);
    return result;
}

fn file_stat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
    return with_private_mode(try inner().fileStat(userdata, file));
}

fn dir_stat(userdata: ?*anyopaque, dir: std.Io.Dir) std.Io.Dir.StatError!std.Io.Dir.Stat {
    return with_private_mode(try inner().dirStat(userdata, dir));
}

fn dir_stat_file(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.StatFileOptions,
) std.Io.Dir.StatFileError!std.Io.File.Stat {
    return with_private_mode(try inner().dirStatFile(userdata, dir, sub_path, options));
}

fn dir_open_file(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    var readable = options;
    if (readable.mode == .write_only) readable.mode = .read_write;
    var file = try inner().dirOpenFile(userdata, dir, sub_path, readable);
    if (!options.follow_symlinks) file.flags.nonblocking = true;
    return file;
}

fn dir_create_file(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.CreateFileOptions,
) std.Io.File.OpenError!std.Io.File {
    var readable = options;
    readable.read = true;
    return inner().dirCreateFile(userdata, dir, sub_path, readable);
}

fn dir_set_permissions(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    permissions: std.Io.Dir.Permissions,
) std.Io.Dir.SetPermissionsError!void {
    _ = userdata;
    _ = dir;
    _ = permissions;
}

fn dir_set_file_permissions(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    permissions: std.Io.File.Permissions,
    options: std.Io.Dir.SetFilePermissionsOptions,
) std.Io.Dir.SetFilePermissionsError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    _ = options;
}

test "private modes follow the entry kind" {
    const base: std.Io.File.Stat = .{
        .inode = 0,
        .nlink = 1,
        .size = 0,
        .permissions = .default_file,
        .kind = .file,
        .atime = null,
        .mtime = .zero,
        .ctime = .zero,
        .block_size = 1,
    };
    var dir = base;
    dir.kind = .directory;

    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), with_private_mode(base).permissions.toMode());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), with_private_mode(dir).permissions.toMode());
}

test "read-only mode maps to the READONLY attribute and back" {
    const writable = Permissions.fromMode(0o600);
    const read_only = writable.setReadOnly(true);

    try std.testing.expect(read_only.readOnly());
    try std.testing.expect(read_only.toAttributes().READONLY);
    try std.testing.expect(!read_only.setReadOnly(false).readOnly());
    try std.testing.expect(writable.toAttributes().NORMAL);
}
