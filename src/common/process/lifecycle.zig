//! Current-thread exit and user-fault containment policy.

const execution_context = @import("execution_context.zig");
const abi = @import("abi");
const arch = @import("arch");
const kernel_delivery = @import("../ipc/kernel_delivery.zig");
const scheduler = @import("scheduler/main.zig");
const thread = @import("thread.zig");

pub const Error = execution_context.ContextError || scheduler.Error || thread.Error ||
    kernel_delivery.Error || abi.process.MessageError;

/// Records normal termination for the current thread and schedules its replacement.
pub fn exitCurrent(status: u64) Error!void {
    const current = try execution_context.current();
    const object = try thread.get(current.thread_handle);
    try publish(object, .exited, @truncate(status));
    try thread.exit(current.thread_handle, status);
    try scheduler.scheduleAfterCurrentStops();
}

/// Records a userspace exception on the current thread and schedules its replacement.
pub fn faultCurrent(fault: thread.UserFault) Error!void {
    try faultCurrentWithFrame(fault, null);
}

pub fn faultCurrentFromFrame(fault: thread.UserFault, trap_frame_address: usize) Error!void {
    try faultCurrentWithFrame(fault, trap_frame_address);
}

fn faultCurrentWithFrame(fault: thread.UserFault, trap_frame_address: ?usize) Error!void {
    const current = try execution_context.current();
    const object = try thread.get(current.thread_handle);
    if (object.fault_endpoint_handle != 0 and trap_frame_address != null) {
        const messages = abi.process.faultEventMessages(.{
            .fault_token = object.fault_token,
            .thread_handle = current.thread_handle,
            .reason = faultReason(fault.kind),
            .address = fault.address,
            .instruction_pointer = fault.instruction_pointer,
            .architecture_data = fault.architecture_error,
        });
        arch.thread_context.retainFaultFrame(
            object.architecture_context_handle,
            trap_frame_address.?,
            fault.instruction_pointer,
        ) catch return terminalFault(current.thread_handle, object, fault);
        kernel_delivery.deliverBatch(object.fault_endpoint_handle, &messages) catch {
            arch.thread_context.clearFaultFrame(object.architecture_context_handle) catch {};
            return terminalFault(current.thread_handle, object, fault);
        };
        try thread.suspendForFault(current.thread_handle, fault);
        try scheduler.scheduleAfterCurrentStops();
        return;
    }
    try terminalFault(current.thread_handle, object, fault);
}

fn terminalFault(handle: thread.Handle, object: thread.Thread, fault: thread.UserFault) Error!void {
    try publish(object, .faulted, @intFromEnum(faultReason(fault.kind)));
    try thread.recordFault(handle, fault);
    try scheduler.scheduleAfterCurrentStops();
}

fn publish(object: thread.Thread, kind: abi.process.LifecycleEventKind, value: u32) Error!void {
    if (object.lifecycle_endpoint_handle == 0) return;
    const message = try abi.process.lifecycleEvent(kind, object.lifecycle_token, value);
    try kernel_delivery.deliver(object.lifecycle_endpoint_handle, message);
}

fn faultReason(kind: thread.UserFaultKind) abi.process.FaultReason {
    return switch (kind) {
        .divide_by_zero => .divide_by_zero,
        .invalid_opcode => .invalid_opcode,
        .general_protection => .general_protection,
        .page_fault => .page_fault,
        .alignment_check => .alignment_check,
    };
}
