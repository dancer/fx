//! Windows has no process groups, so a job object stands in for the group a
//! command's shell leads: terminating the job stops every process the command
//! started, and closing it does the same if fx exits first.
//!
//! The tree keeps its own duplicate of the process handle, because the waiter
//! closes the child's handle as soon as the shell exits.

const std = @import("std");
const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;

pub const Tree = struct {
    process: HANDLE,
    job: ?HANDLE,

    /// Puts the process in a new kill-on-close job. The tree still stops the
    /// process alone when the job is unavailable, such as inside a job that
    /// forbids nesting.
    pub fn init(process: HANDLE) ?Tree {
        const current = GetCurrentProcess();
        var owned: HANDLE = undefined;
        if (!DuplicateHandle(current, process, current, &owned, 0, .FALSE, duplicate_same_access).toBool()) return null;
        return .{ .process = owned, .job = killOnCloseJob(owned) };
    }

    pub fn terminate(self: Tree) void {
        if (self.job) |job| {
            if (TerminateJobObject(job, 1).toBool()) return;
        }
        _ = TerminateProcess(self.process, 1);
    }

    pub fn deinit(self: Tree) void {
        if (self.job) |job| windows.CloseHandle(job);
        windows.CloseHandle(self.process);
    }
};

fn killOnCloseJob(process: HANDLE) ?HANDLE {
    const job = CreateJobObjectW(null, null) orelse return null;
    var limits = std.mem.zeroes(ExtendedLimitInformation);
    limits.basic.limit_flags = job_object_limit_kill_on_job_close;
    if (SetInformationJobObject(job, job_object_extended_limit_information, &limits, @sizeOf(ExtendedLimitInformation)).toBool() and
        AssignProcessToJobObject(job, process).toBool())
    {
        return job;
    }
    windows.CloseHandle(job);
    return null;
}

const duplicate_same_access: DWORD = 0x2;
const job_object_extended_limit_information: c_int = 9;
const job_object_limit_kill_on_job_close: DWORD = 0x2000;

const BasicLimitInformation = extern struct {
    per_process_user_time_limit: i64,
    per_job_user_time_limit: i64,
    limit_flags: DWORD,
    minimum_working_set_size: usize,
    maximum_working_set_size: usize,
    active_process_limit: DWORD,
    affinity: usize,
    priority_class: DWORD,
    scheduling_class: DWORD,
};

const ExtendedLimitInformation = extern struct {
    basic: BasicLimitInformation,
    io_info: [6]u64,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory_used: usize,
    peak_job_memory_used: usize,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn DuplicateHandle(
    source_process: HANDLE,
    source: HANDLE,
    target_process: HANDLE,
    target: *HANDLE,
    desired_access: DWORD,
    inherit: BOOL,
    options: DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, len: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(job: HANDLE, exit_code: c_uint) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, exit_code: c_uint) callconv(.winapi) BOOL;
