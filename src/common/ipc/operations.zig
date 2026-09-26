//! Blocking buffered IPC policy and deferred syscall completion.

const abi = @import("abi");
const arch = @import("arch");
const endpoint = @import("endpoint.zig");
const process = @import("../process/main.zig");

pub const Error = error{
    EndpointCanceled,
} || endpoint.Error || process.ProcessError || process.scheduler.Error ||
    process.execution_context.ContextError || arch.ThreadContextError;

pub const Outcome = enum {
    completed,
    blocked,
};

pub const ReceiveOutcome = union(enum) {
    completed: abi.ipc.Message,
    blocked,
};

pub fn send(
    handle: endpoint.Handle,
    authorization: endpoint.Authorization,
    message: abi.ipc.Message,
) Error!Outcome {
    if (try endpoint.peekReceiver(handle)) |receiver| {
        try prepareWake(handle, receiver, .{ .endpoint_receive = handle });
        try arch.thread_context.completeSyscall(
            receiver.architecture_context_handle,
            messageResult(message),
        );
        _ = try endpoint.popReceiver(handle);
        try process.scheduler.commitEndpointWake(
            receiver.thread_handle,
            .{ .endpoint_receive = handle },
        );
        return .completed;
    }

    endpoint.send(handle, message) catch |err| switch (err) {
        error.EndpointFull => return blockSender(handle, authorization, message),
        else => return err,
    };
    return .completed;
}

pub fn receive(
    handle: endpoint.Handle,
    authorization: endpoint.Authorization,
) Error!ReceiveOutcome {
    const blocked_sender = try endpoint.peekSender(handle);
    if (blocked_sender) |sender| {
        try prepareWake(handle, sender.waiter, .{ .endpoint_send = handle });
    }
    const message = endpoint.receive(handle) catch |err| switch (err) {
        error.EndpointEmpty => return blockReceiver(handle, authorization),
        else => return err,
    };

    if (blocked_sender) |sender| {
        try arch.thread_context.completeSyscall(
            sender.waiter.architecture_context_handle,
            .fromStatus(abi.syscall.SYSCALL_SUCCESS),
        );
        try endpoint.send(handle, sender.message);
        _ = try endpoint.popSender(handle);
        try process.scheduler.commitEndpointWake(
            sender.waiter.thread_handle,
            .{ .endpoint_send = handle },
        );
    }

    return .{ .completed = message };
}

pub fn destroy(handle: endpoint.Handle) Error!void {
    if (try endpoint.messageCount(handle) != 0) return error.EndpointInUse;
    try cancelEndpoint(handle);
    try endpoint.destroy(handle);
}

pub fn cancelAuthorization(authorization: endpoint.Authorization) Error!void {
    while (endpoint.findByAuthorization(authorization)) |found| {
        try cancelWaiter(found.endpoint_handle, found.waiter);
    }
}

pub fn cancelEndpoint(handle: endpoint.Handle) Error!void {
    while (try endpoint.findForEndpoint(handle)) |waiter| {
        try cancelWaiter(handle, waiter);
    }
}

fn blockSender(
    handle: endpoint.Handle,
    authorization: endpoint.Authorization,
    message: abi.ipc.Message,
) Error!Outcome {
    const waiter = try currentWaiter(authorization);
    try endpoint.enqueueSender(handle, .{ .waiter = waiter, .message = message });
    errdefer endpoint.removeWaiter(handle, waiter.thread_handle) catch {};
    try process.scheduler.blockCurrentForEndpoint(.{ .endpoint_send = handle });
    return .blocked;
}

fn blockReceiver(
    handle: endpoint.Handle,
    authorization: endpoint.Authorization,
) Error!ReceiveOutcome {
    const waiter = try currentWaiter(authorization);
    try endpoint.enqueueReceiver(handle, waiter);
    errdefer endpoint.removeWaiter(handle, waiter.thread_handle) catch {};
    try process.scheduler.blockCurrentForEndpoint(.{ .endpoint_receive = handle });
    return .blocked;
}

fn currentWaiter(authorization: endpoint.Authorization) Error!endpoint.Waiter {
    const current = try process.execution_context.current();
    const object = try process.thread.get(current.thread_handle);
    return .{
        .thread_handle = current.thread_handle,
        .architecture_context_handle = object.architecture_context_handle,
        .authorization = authorization,
    };
}

fn prepareWake(
    handle: endpoint.Handle,
    waiter: endpoint.Waiter,
    reason: process.thread.BlockReason,
) Error!void {
    _ = handle;
    try process.scheduler.prepareEndpointWake(waiter.thread_handle, reason);
}

fn cancelWaiter(handle: endpoint.Handle, waiter: endpoint.CanceledWaiter) Error!void {
    const blocked = switch (waiter) {
        .sender => |sender| sender.waiter,
        .receiver => |receiver| receiver,
    };
    const reason: process.thread.BlockReason = switch (waiter) {
        .sender => .{ .endpoint_send = handle },
        .receiver => .{ .endpoint_receive = handle },
    };
    try prepareWake(handle, blocked, reason);
    try arch.thread_context.completeSyscall(
        blocked.architecture_context_handle,
        .fromStatus(abi.syscall.errorResult(.endpoint_canceled)),
    );
    try endpoint.removeWaiter(handle, blocked.thread_handle);
    try process.scheduler.commitEndpointWake(blocked.thread_handle, reason);
}

fn messageResult(message: abi.ipc.Message) arch.SyscallResultRegisters {
    return .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .words = .{ message.words[0], message.words[1], message.words[2] },
    };
}
