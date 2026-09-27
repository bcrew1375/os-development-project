//! Notification blocking, wakeup, cancellation, and interrupt-source policy.

const abi = @import("abi");
const arch = @import("arch");
const interrupt_source = @import("interrupt_source.zig");
const notification = @import("notification.zig");
const process = @import("../process/main.zig");

pub const Error = error{
    NotificationCanceled,
} || notification.Error || interrupt_source.Error || process.ProcessError ||
    process.scheduler.Error || process.execution_context.ContextError || arch.ThreadContextError;

pub const WaitOutcome = union(enum) {
    completed: notification.Pending,
    blocked,
};

pub fn wait(
    handle: notification.Handle,
    authorization: notification.Authorization,
) Error!WaitOutcome {
    if (try notification.consume(handle)) |pending| return .{ .completed = pending };
    const current = try process.execution_context.current();
    const object = try process.thread.get(current.thread_handle);
    try notification.setWaiter(handle, .{
        .thread_handle = current.thread_handle,
        .architecture_context_handle = object.architecture_context_handle,
        .authorization = authorization,
    });
    errdefer notification.clearWaiter(handle, current.thread_handle) catch {};
    try armBoundSourceForInitialWait(handle);
    try process.scheduler.blockCurrentForEndpoint(.{ .notification_wait = handle });
    return .blocked;
}

pub fn signal(handle: notification.Handle) Error!void {
    const waiter = try notification.getWaiter(handle) orelse {
        try notification.addSignal(handle);
        return;
    };
    const reason: process.thread.BlockReason = .{ .notification_wait = handle };
    try process.scheduler.prepareEndpointWake(waiter.thread_handle, reason);
    try arch.thread_context.completeSyscall(
        waiter.architecture_context_handle,
        pendingResult(.{ .count = 1, .overflowed = false }),
    );
    try notification.clearWaiter(handle, waiter.thread_handle);
    try process.scheduler.commitEndpointWake(waiter.thread_handle, reason);
}

pub fn deliverInterrupt(kind: abi.notification.InterruptSourceKind) Error!void {
    const source_handle = interrupt_source.find(kind) orelse return;
    const notification_handle = interrupt_source.maskForDelivery(source_handle) catch |err| switch (err) {
        error.InterruptSourceAlreadyAcknowledged, error.InterruptSourceNotBound => return,
        else => return err,
    };
    arch.interrupts.maskInterruptSource(kind);
    try signal(notification_handle);
}

pub fn bind(source_handle: interrupt_source.Handle, notification_handle: notification.Handle) Error!void {
    try notification.bindSource(notification_handle, source_handle);
    errdefer notification.unbindSource(notification_handle, source_handle) catch {};
    try interrupt_source.bind(source_handle, notification_handle);
    const state = try interrupt_source.get(source_handle);
    switch (state.kind) {
        .timer => arch.platform.initializeTimer(state.parameter),
        _ => unreachable,
    }
    arch.interrupts.maskInterruptSource(state.kind);
}

pub fn unbind(source_handle: interrupt_source.Handle) Error!void {
    const state = try interrupt_source.get(source_handle);
    arch.interrupts.maskInterruptSource(state.kind);
    const notification_handle = try interrupt_source.unbind(source_handle);
    try notification.unbindSource(notification_handle, source_handle);
}

pub fn acknowledge(source_handle: interrupt_source.Handle) Error!void {
    const kind = try interrupt_source.acknowledge(source_handle);
    arch.interrupts.unmaskInterruptSource(kind);
}

pub fn destroyNotification(handle: notification.Handle) Error!void {
    if (try notification.getWaiter(handle)) |waiter| try cancelWaiter(handle, waiter);
    try notification.destroy(handle);
}

pub fn cancelAuthorization(authorization: notification.Authorization) Error!void {
    if (notification.findByAuthorization(authorization)) |found| {
        try cancelWaiter(found.handle, found.waiter);
    }
}

fn cancelWaiter(handle: notification.Handle, waiter: notification.Waiter) Error!void {
    const reason: process.thread.BlockReason = .{ .notification_wait = handle };
    try process.scheduler.prepareEndpointWake(waiter.thread_handle, reason);
    try arch.thread_context.prepareSyscallCompletion(waiter.architecture_context_handle);
    try arch.thread_context.completeSyscall(
        waiter.architecture_context_handle,
        .fromStatus(abi.syscall.errorResult(.notification_canceled)),
    );
    try notification.clearWaiter(handle, waiter.thread_handle);
    try process.scheduler.commitEndpointWake(waiter.thread_handle, reason);
}

fn armBoundSourceForInitialWait(handle: notification.Handle) Error!void {
    const source_handle = try notification.boundSource(handle) orelse return;
    const state = try interrupt_source.get(source_handle);
    if (!state.masked) return;
    const kind = try interrupt_source.arm(source_handle);
    arch.interrupts.unmaskInterruptSource(kind);
}

pub fn pendingResult(pending: notification.Pending) arch.SyscallResultRegisters {
    return .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .words = .{ pending.count, @intFromBool(pending.overflowed), 0 },
    };
}
