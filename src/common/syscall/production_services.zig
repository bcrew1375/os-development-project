//! Production syscall service adapters and checked userspace request copies.

const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const capability = @import("../capability/main.zig");
const ipc = @import("../ipc/main.zig");
const process = @import("../process/main.zig");
const user_memory = @import("../user_memory.zig");

fn productionConfigureThreadFromUser(
    caller_space: u32,
    thread_capability: abi.capability.CapabilityHandle,
    configuration_address: u64,
) !void {
    var bytes: [@sizeOf(abi.process.ThreadConfiguration)]u8 = undefined;
    try user_memory.copyFromUser(&bytes, configuration_address, bytes.len);
    const configuration = std.mem.bytesToValue(abi.process.ThreadConfiguration, &bytes);
    const thread_handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .configure = true },
    );
    const capability_space_handle = try capability.resolveCapabilitySpace(
        caller_space,
        configuration.capability_space,
        .{},
    );
    const address_space_handle = try capability.resolveAddressSpace(
        caller_space,
        configuration.address_space,
        .{ .execute = true },
    );
    const lifecycle_endpoint_handle = if (configuration.lifecycle_endpoint == abi.capability.INVALID_CAPABILITY)
        @as(u32, 0)
    else
        try capability.resolveEndpoint(
            caller_space,
            configuration.lifecycle_endpoint,
            .{ .manage = true },
        );
    const fault_endpoint_handle = if (configuration.fault_endpoint == abi.capability.INVALID_CAPABILITY)
        @as(u32, 0)
    else
        try capability.resolveEndpoint(
            caller_space,
            configuration.fault_endpoint,
            .{ .manage = true },
        );
    try process.configureThread(thread_handle, .{
        .capability_space_handle = capability_space_handle,
        .address_space_handle = address_space_handle,
        .entry_point = configuration.entry_point,
        .stack_pointer = configuration.stack_pointer,
        .argument = configuration.argument,
        .lifecycle_endpoint_handle = lifecycle_endpoint_handle,
        .lifecycle_token = configuration.lifecycle_token,
        .fault_endpoint_handle = fault_endpoint_handle,
        .fault_token = configuration.fault_token,
    });
}

fn productionFaultReplyFromUser(
    caller_space: u32,
    endpoint_capability: u32,
    request_address: u64,
) !void {
    var bytes: [@sizeOf(abi.process.FaultReplyRequest)]u8 = undefined;
    try user_memory.copyFromUser(&bytes, request_address, bytes.len);
    const request = std.mem.bytesToValue(abi.process.FaultReplyRequest, &bytes);
    if (request.reserved != 0) return error.InvalidFaultReply;
    const endpoint_handle = try capability.resolveEndpoint(
        caller_space,
        endpoint_capability,
        .{ .manage = true },
    );
    switch (request.action) {
        .resume_thread => {
            if (request.value != 0) return error.InvalidFaultReply;
            const object = try process.scheduler.prepareFaultResume(
                request.thread_handle,
                endpoint_handle,
                request.fault_token,
            );
            try arch.thread_context.clearFaultFrame(object.architecture_context_handle);
            try process.scheduler.commitFaultResume(
                request.thread_handle,
                endpoint_handle,
                request.fault_token,
            );
        },
        .resume_at => {
            const object = try process.scheduler.prepareFaultResume(
                request.thread_handle,
                endpoint_handle,
                request.fault_token,
            );
            try arch.thread_context.setFaultInstructionPointer(
                object.architecture_context_handle,
                request.value,
            );
            try arch.thread_context.clearFaultFrame(object.architecture_context_handle);
            try process.scheduler.commitFaultResume(
                request.thread_handle,
                endpoint_handle,
                request.fault_token,
            );
        },
        .terminate => {
            _ = try process.thread.authorizeFaultReply(
                request.thread_handle,
                endpoint_handle,
                request.fault_token,
            );
            try process.scheduler.terminate(request.thread_handle, request.value);
        },
        _ => return error.InvalidFaultReply,
    }
}

fn productionStartThreadCapability(caller_space: u32, thread_capability: u32) !void {
    const handle = try capability.resolveThread(caller_space, thread_capability, .{ .start = true });
    try process.scheduler.makeReady(handle);
}

fn productionSuspendThreadCapability(caller_space: u32, thread_capability: u32) !void {
    const handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .suspend_thread = true },
    );
    try process.scheduler.suspendThread(handle);
}

fn productionResumeThreadCapability(caller_space: u32, thread_capability: u32) !void {
    const handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .resume_thread = true },
    );
    try process.scheduler.resumeThread(handle);
}

fn productionTerminateThreadCapability(caller_space: u32, thread_capability: u32, status: u64) !void {
    const handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .terminate = true },
    );
    try process.scheduler.terminate(handle, status);
}

fn productionSendEndpointMessage(
    caller_space: u32,
    endpoint_capability: u32,
    message: abi.ipc.Message,
) !ipc.operations.Outcome {
    const handle = try capability.resolveEndpoint(
        caller_space,
        endpoint_capability,
        .{ .send = true },
    );
    return ipc.operations.send(handle, .{
        .capability_space_handle = caller_space,
        .capability_handle = endpoint_capability,
    }, message);
}

fn productionReceiveEndpointMessage(
    caller_space: u32,
    endpoint_capability: u32,
) !ipc.operations.ReceiveOutcome {
    const handle = try capability.resolveEndpoint(
        caller_space,
        endpoint_capability,
        .{ .receive = true },
    );
    return ipc.operations.receive(handle, .{
        .capability_space_handle = caller_space,
        .capability_handle = endpoint_capability,
    });
}

fn productionSendEndpointCapability(
    caller_space: u32,
    endpoint_capability: u32,
    request_address: u64,
) !ipc.transfer_operations.Outcome {
    var bytes: [@sizeOf(abi.ipc.TransferSendRequest)]u8 = undefined;
    try user_memory.copyFromUser(&bytes, request_address, bytes.len);
    const transfer_request = std.mem.bytesToValue(abi.ipc.TransferSendRequest, &bytes);
    const handle = try capability.resolveEndpoint(
        caller_space,
        endpoint_capability,
        .{ .send = true },
    );
    return ipc.transfer_operations.send(handle, .{
        .capability_space_handle = caller_space,
        .capability_handle = endpoint_capability,
    }, caller_space, transfer_request);
}

fn productionReceiveEndpointCapability(
    caller_space: u32,
    endpoint_capability: u32,
    request_address: u64,
) !ipc.transfer_operations.ReceiveOutcome {
    var bytes: [@sizeOf(abi.ipc.TransferReceiveRequest)]u8 = undefined;
    try user_memory.copyFromUser(&bytes, request_address, bytes.len);
    const transfer_request = std.mem.bytesToValue(abi.ipc.TransferReceiveRequest, &bytes);
    const handle = try capability.resolveEndpoint(
        caller_space,
        endpoint_capability,
        .{ .receive = true },
    );
    return ipc.transfer_operations.receive(handle, .{
        .capability_space_handle = caller_space,
        .capability_handle = endpoint_capability,
    }, caller_space, transfer_request);
}

fn productionWaitNotification(
    caller_space: u32,
    notification_capability: u32,
) !ipc.notification_operations.WaitOutcome {
    const handle = try capability.resolveNotification(
        caller_space,
        notification_capability,
        .{ .wait = true },
    );
    return ipc.notification_operations.wait(handle, .{
        .capability_space_handle = caller_space,
        .capability_handle = notification_capability,
    });
}

fn productionSignalNotification(caller_space: u32, notification_capability: u32) !void {
    const handle = try capability.resolveNotification(
        caller_space,
        notification_capability,
        .{ .signal = true },
    );
    try ipc.notification_operations.signal(handle);
}

fn productionBindInterruptSource(
    caller_space: u32,
    source_capability: u32,
    notification_capability: u32,
) !void {
    const source_handle = try capability.resolveInterruptSource(
        caller_space,
        source_capability,
        .{ .bind = true },
    );
    const notification_handle = try capability.resolveNotification(
        caller_space,
        notification_capability,
        .{ .bind = true },
    );
    try ipc.notification_operations.bind(source_handle, notification_handle);
}

fn productionUnbindInterruptSource(caller_space: u32, source_capability: u32) !void {
    const source_handle = try capability.resolveInterruptSource(
        caller_space,
        source_capability,
        .{ .bind = true },
    );
    try ipc.notification_operations.unbind(source_handle);
}

fn productionAcknowledgeInterruptSource(caller_space: u32, source_capability: u32) !void {
    const source_handle = try capability.resolveInterruptSource(
        caller_space,
        source_capability,
        .{ .acknowledge = true },
    );
    try ipc.notification_operations.acknowledge(source_handle);
}

pub const ProductionServices = struct {
    pub const currentAddressSpaceHandle = process.execution_context.currentAddressSpaceHandle;
    pub const findAddressSpaceCapability = capability.findAddressSpaceCapability;
    pub const createAddressSpaceCapability = capability.createAddressSpaceCapability;
    pub const resolveAddressSpace = capability.resolveAddressSpace;
    pub const destroyAddressSpaceCapability = capability.destroyAddressSpaceCapability;
    pub const retypeUntypedMemoryCapability = capability.retypeUntypedMemoryCapability;
    pub const deletePhysicalMemoryCapability = capability.deletePhysicalMemoryCapability;
    pub const revokePhysicalMemoryCapability = capability.revokePhysicalMemoryCapability;
    pub const createMemoryObjectCapability = capability.createMemoryObjectCapability;
    pub const destroyMemoryObjectCapability = capability.destroyMemoryObjectCapability;
    pub const resolveMemoryObject = capability.resolveMemoryObject;
    pub const mapMemory = process.mapMemory;
    pub const mapMemoryObject = process.mapMemoryObject;
    pub const protectAddressSpace = process.protectAddressSpace;
    pub const queryAddressSpace = process.queryAddressSpace;
    pub const unmapAddressSpace = process.unmapAddressSpace;
    pub const createCapabilitySpaceCapability = capability.createCapabilitySpaceCapability;
    pub const createThreadCapability = capability.createThreadCapability;
    pub const createEndpointCapability = capability.createEndpointCapability;
    pub const createNotificationCapability = capability.createNotificationCapability;
    pub const createInterruptSourceCapability = capability.createInterruptSourceCapability;
    pub const configureThreadFromUser = productionConfigureThreadFromUser;
    pub const startThreadCapability = productionStartThreadCapability;
    pub const suspendThreadCapability = productionSuspendThreadCapability;
    pub const resumeThreadCapability = productionResumeThreadCapability;
    pub const terminateThreadCapability = productionTerminateThreadCapability;
    pub const faultReplyFromUser = productionFaultReplyFromUser;
    pub const installCapability = capability.installCapability;
    pub const destroyThreadCapability = capability.destroyThreadCapability;
    pub const destroyCapabilitySpaceCapability = capability.destroyCapabilitySpaceCapability;
    pub const deleteCapabilityFromSpace = capability.deleteCapabilityFromSpace;
    pub const destroyEndpointCapability = capability.destroyEndpointCapability;
    pub const destroyNotificationCapability = capability.destroyNotificationCapability;
    pub const destroyInterruptSourceCapability = capability.destroyInterruptSourceCapability;
    pub const sendEndpointMessage = productionSendEndpointMessage;
    pub const receiveEndpointMessage = productionReceiveEndpointMessage;
    pub const sendEndpointCapability = productionSendEndpointCapability;
    pub const receiveEndpointCapability = productionReceiveEndpointCapability;
    pub const waitNotification = productionWaitNotification;
    pub const signalNotification = productionSignalNotification;
    pub const bindInterruptSource = productionBindInterruptSource;
    pub const unbindInterruptSource = productionUnbindInterruptSource;
    pub const acknowledgeInterruptSource = productionAcknowledgeInterruptSource;
};
