//! Chooses the shell that runs command scripts on Windows. Models write POSIX
//! shell, so Git Bash runs them whenever Git for Windows is installed, and
//! Windows PowerShell, which every install has, is the fallback. Both read the
//! script from stdin: cmd.exe and the C runtime disagree about quoting, so a
//! script passed on a command line loses its double quotes.
//!
//! FX_WINDOWS_SHELL overrides the choice with `powershell` or the absolute
//! path of a bash.exe, powershell.exe, or pwsh.exe.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { bash, powershell };

pub const Shell = struct {
    kind: Kind,
    path: []const u8,
};

/// Dot-sources the UTF-8 script read from stdin with a status check appended,
/// so the exit code follows the script's last statement the way a POSIX
/// shell's does: its native exit code, or 1 for a failed cmdlet. Windows
/// PowerShell mangles double quotes in its own arguments, so this uses none.
pub const powershell_launcher =
    "[Console]::InputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);" ++
    "$ProgressPreference='SilentlyContinue';" ++
    "$global:LASTEXITCODE=0;" ++
    ". ([ScriptBlock]::Create([Console]::In.ReadToEnd()+[char]10+" ++
    "'if(-not $?){if($LASTEXITCODE){exit $LASTEXITCODE};exit 1}'))";

pub fn powershellArgv(path: []const u8) [8][]const u8 {
    return .{ path, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", powershell_launcher };
}

/// The shell a resolved path names, for callers that carry only the path.
pub fn fromPath(path: []const u8) Shell {
    const name = std.fs.path.basename(path);
    const is_powershell = std.ascii.eqlIgnoreCase(name, "powershell.exe") or std.ascii.eqlIgnoreCase(name, "pwsh.exe");
    return .{ .kind = if (is_powershell) .powershell else .bash, .path = path };
}

pub fn resolve(alloc: Allocator) Allocator.Error!Shell {
    if (io_mod.getenv("FX_WINDOWS_SHELL")) |configured| {
        if (std.ascii.eqlIgnoreCase(configured, "powershell")) return powershell(alloc);
        if (isFile(configured)) return fromPath(try alloc.dupe(u8, configured));
    }
    if (try gitBashPath(alloc)) |path| return .{ .kind = .bash, .path = path };
    return powershell(alloc);
}

fn powershell(alloc: Allocator) Allocator.Error!Shell {
    const system_root = io_mod.getenv("SystemRoot") orelse "C:\\Windows";
    return .{
        .kind = .powershell,
        .path = try std.fs.path.join(alloc, &.{ system_root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe" }),
    };
}

/// Git Bash beside the git.exe on PATH, then in the default install
/// locations. bash.exe on PATH itself is skipped because System32 carries the
/// WSL launcher under that name.
fn gitBashPath(alloc: Allocator) Allocator.Error!?[]const u8 {
    if (io_mod.getenv("PATH")) |path_list| {
        var dirs = std.mem.tokenizeScalar(u8, path_list, ';');
        while (dirs.next()) |entry| {
            const dir = std.mem.trimEnd(u8, std.mem.trim(u8, entry, " \""), "\\/");
            if (dir.len == 0) continue;
            const git = try std.fs.path.join(alloc, &.{ dir, "git.exe" });
            defer alloc.free(git);
            if (!isFile(git)) continue;
            // git.exe lives in cmd\, bin\, or mingw64\bin\ under the Git root.
            var root = std.fs.path.dirname(dir);
            for (0..2) |_| {
                const candidate_root = root orelse break;
                if (try bashUnder(alloc, candidate_root)) |bash| return bash;
                root = std.fs.path.dirname(candidate_root);
            }
        }
    }
    const installs = [_]struct { env: []const u8, sub: []const u8 }{
        .{ .env = "ProgramFiles", .sub = "Git" },
        .{ .env = "ProgramW6432", .sub = "Git" },
        .{ .env = "LOCALAPPDATA", .sub = "Programs\\Git" },
    };
    for (installs) |install| {
        const base = io_mod.getenv(install.env) orelse continue;
        const root = try std.fs.path.join(alloc, &.{ base, install.sub });
        defer alloc.free(root);
        if (try bashUnder(alloc, root)) |bash| return bash;
    }
    return null;
}

fn bashUnder(alloc: Allocator, root: []const u8) Allocator.Error!?[]const u8 {
    const bash = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
    if (isFile(bash)) return bash;
    alloc.free(bash);
    return null;
}

fn isFile(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .file;
}
