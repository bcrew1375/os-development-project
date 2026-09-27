//! Kernel-originated endpoint message delivery without a sender capability.

const abi = @import("abi");
const arch = @import("arch");
const endpoint = @import("endpoint.zig");
const process = @import("../process/main.zig");

pub const Error = endpoint.Error || process.scheduler.Error || arch.ThreadContextError;

/// Delivers directly to a blocked receiver when possible, otherwise queues the message.
pub fn deliver(handle: endpoint.Handle, message: abi.ipc.Message) Error!void {
    if (try endpoint.peekReceiver(handle)) |receiver| {
        try process.scheduler.prepareEndpointWake(
            receiver.thread_handle,
            .{ .endpoint_receive = handle },
        );
        try arch.thread_context.completeSyscall(
            receiver.architecture_context_handle,
            .{
                .status = abi.syscall.SYSCALL_SUCCESS,
                .words = .{ message.words[0], message.words[1], message.words[2] },
            },
        );
        _ = try endpoint.popReceiver(handle);
        try process.scheduler.commitEndpointWake(
            receiver.thread_handle,
            .{ .endpoint_receive = handle },
        );
        return;
    }
    try endpoint.send(handle, message);
}

/// Delivers a complete ordered record sequence without exposing partial events.
pub fn deliverBatch(handle: endpoint.Handle, messages: []const abi.ipc.Message) Error!void {
    if (messages.len == 0) return;
    if (try endpoint.peekReceiver(handle)) |receiver| {
        if (messages.len - 1 > try endpoint.availableMessageCount(handle)) {
            return error.EndpointFull;
        }
        try process.scheduler.prepareEndpointWake(
            receiver.thread_handle,
            .{ .endpoint_receive = handle },
        );
        try arch.thread_context.prepareSyscallCompletion(receiver.architecture_context_handle);
        try endpoint.sendBatch(handle, messages[1..]);
        try arch.thread_context.completeSyscall(
            receiver.architecture_context_handle,
            .{
                .status = abi.syscall.SYSCALL_SUCCESS,
                .words = .{ messages[0].words[0], messages[0].words[1], messages[0].words[2] },
            },
        );
        _ = try endpoint.popReceiver(handle);
        try process.scheduler.commitEndpointWake(
            receiver.thread_handle,
            .{ .endpoint_receive = handle },
        );
        return;
    }
    try endpoint.sendBatch(handle, messages);
}
