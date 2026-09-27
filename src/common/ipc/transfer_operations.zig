//! Direct-rendezvous IPC capability transfer and atomic syscall completion.

const abi = @import("abi");
const arch = @import("arch");
const capability = @import("../capability/main.zig");
const endpoint = @import("endpoint.zig");
const process = @import("../process/main.zig");

pub const Error = capability.CapabilityError || endpoint.Error || process.ProcessError ||
    process.scheduler.Error || process.execution_context.ContextError || arch.ThreadContextError;

pub const Outcome = enum {
    completed,
    blocked,
};

pub const ReceiveResult = struct {
    message: abi.ipc.Message,
    capability: abi.capability.CapabilityHandle,
};

pub const ReceiveOutcome = union(enum) {
    completed: ReceiveResult,
    blocked,
};

pub fn send(
    handle: endpoint.Handle,
    endpoint_authorization: endpoint.Authorization,
    source_space: capability.space.Handle,
    request: abi.ipc.TransferSendRequest,
) Error!Outcome {
    const rights = abi.capability.rightsFromBits(request.rights_bits) orelse {
        return error.InvalidCapabilityRights;
    };
    try capability.validateTransferSource(source_space, request.source_capability, rights);

    if (try endpoint.peekTransferReceiver(handle)) |receiver| {
        const prepared = try prepareRendezvous(
            handle,
            source_space,
            request.source_capability,
            rights,
            receiver,
        );
        const installed = capability.commitExactInstall(prepared);
        arch.thread_context.completeSyscall(
            receiver.waiter.architecture_context_handle,
            receiveRegisters(request.message, installed),
        ) catch unreachable;
        _ = endpoint.popTransferReceiver(handle) catch unreachable;
        process.scheduler.commitEndpointWake(
            receiver.waiter.thread_handle,
            .{ .endpoint_transfer_receive = handle },
        ) catch unreachable;
        return .completed;
    }

    return blockSender(
        handle,
        endpoint_authorization,
        source_space,
        request.source_capability,
        rights,
        request.message,
    );
}

pub fn receive(
    handle: endpoint.Handle,
    endpoint_authorization: endpoint.Authorization,
    destination_space: capability.space.Handle,
    request: abi.ipc.TransferReceiveRequest,
) Error!ReceiveOutcome {
    try capability.validateExactDestination(destination_space, request.destination_slot);

    if (try endpoint.peekTransferSender(handle)) |sender| {
        const prepared = try capability.prepareExactInstall(
            sender.source_authorization.capability_space_handle,
            sender.source_capability,
            destination_space,
            request.destination_slot,
            sender.rights,
        );
        try process.scheduler.prepareEndpointWake(
            sender.waiter.thread_handle,
            .{ .endpoint_transfer_send = handle },
        );
        try arch.thread_context.prepareSyscallCompletion(
            sender.waiter.architecture_context_handle,
        );
        const installed = capability.commitExactInstall(prepared);
        arch.thread_context.completeSyscall(
            sender.waiter.architecture_context_handle,
            .fromStatus(abi.syscall.SYSCALL_SUCCESS),
        ) catch unreachable;
        _ = endpoint.popTransferSender(handle) catch unreachable;
        process.scheduler.commitEndpointWake(
            sender.waiter.thread_handle,
            .{ .endpoint_transfer_send = handle },
        ) catch unreachable;
        return .{ .completed = .{
            .message = sender.message,
            .capability = installed,
        } };
    }

    return blockReceiver(handle, endpoint_authorization, destination_space, request.destination_slot);
}

fn prepareRendezvous(
    handle: endpoint.Handle,
    source_space: capability.space.Handle,
    source_capability: abi.capability.CapabilityHandle,
    rights: abi.capability.Rights,
    receiver: endpoint.TransferReceiverWaiter,
) Error!capability.PreparedInstall {
    const prepared = try capability.prepareExactInstall(
        source_space,
        source_capability,
        receiver.destination_space,
        receiver.destination_slot,
        rights,
    );
    try process.scheduler.prepareEndpointWake(
        receiver.waiter.thread_handle,
        .{ .endpoint_transfer_receive = handle },
    );
    try arch.thread_context.prepareSyscallCompletion(receiver.waiter.architecture_context_handle);
    return prepared;
}

fn blockSender(
    handle: endpoint.Handle,
    endpoint_authorization: endpoint.Authorization,
    source_space: capability.space.Handle,
    source_capability: abi.capability.CapabilityHandle,
    rights: abi.capability.Rights,
    message: abi.ipc.Message,
) Error!Outcome {
    const waiter = try currentWaiter(endpoint_authorization);
    try endpoint.enqueueTransferSender(handle, .{
        .waiter = waiter,
        .source_authorization = .{
            .capability_space_handle = source_space,
            .capability_handle = source_capability,
        },
        .source_capability = source_capability,
        .rights = rights,
        .message = message,
    });
    errdefer endpoint.removeWaiter(handle, waiter.thread_handle) catch {};
    try process.scheduler.blockCurrentForEndpoint(.{ .endpoint_transfer_send = handle });
    return .blocked;
}

fn blockReceiver(
    handle: endpoint.Handle,
    endpoint_authorization: endpoint.Authorization,
    destination_space: capability.space.Handle,
    destination_slot: u32,
) Error!ReceiveOutcome {
    const waiter = try currentWaiter(endpoint_authorization);
    try endpoint.enqueueTransferReceiver(handle, .{
        .waiter = waiter,
        .destination_space = destination_space,
        .destination_slot = destination_slot,
    });
    errdefer endpoint.removeWaiter(handle, waiter.thread_handle) catch {};
    try process.scheduler.blockCurrentForEndpoint(.{ .endpoint_transfer_receive = handle });
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

fn receiveRegisters(
    message: abi.ipc.Message,
    installed: abi.capability.CapabilityHandle,
) arch.SyscallResultRegisters {
    return .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .words = .{ message.words[0], message.words[1], message.words[2] },
        .capability = installed,
    };
}
