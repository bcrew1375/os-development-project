//! Current-thread exit and user-fault containment policy.

const execution_context = @import("execution_context.zig");
const scheduler = @import("scheduler/main.zig");
const thread = @import("thread.zig");

pub const Error = execution_context.ContextError || scheduler.Error || thread.Error;

/// Records normal termination for the current thread and schedules its replacement.
pub fn exitCurrent(status: u64) Error!void {
    const current = try execution_context.current();
    try thread.exit(current.thread_handle, status);
    try scheduler.scheduleAfterCurrentStops();
}

/// Records a userspace exception on the current thread and schedules its replacement.
pub fn faultCurrent(fault: thread.UserFault) Error!void {
    const current = try execution_context.current();
    try thread.recordFault(current.thread_handle, fault);
    try scheduler.scheduleAfterCurrentStops();
}
