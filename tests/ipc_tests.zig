const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

fn resetState() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
}

fn request(number: abi.syscall.SyscallNumber, arguments: [5]u64) kernel.syscall.Request {
    return .{ .number = @intFromEnum(number), .arguments = arguments };
}

test "IPC endpoint: bounded FIFO reports empty and full without partial delivery" {
    resetState();
    const handle = try kernel.ipc.endpoint.create();

    try std.testing.expectError(error.EndpointEmpty, kernel.ipc.endpoint.receive(handle));
    for (0..kernel.ipc.endpoint.MESSAGE_CAPACITY) |index| {
        const word: u32 = @intCast(index);
        try kernel.ipc.endpoint.send(handle, .{ .words = .{ word, word + 10, word + 20 } });
    }
    try std.testing.expectError(
        error.EndpointFull,
        kernel.ipc.endpoint.send(handle, .{ .words = .{ 99, 98, 97 } }),
    );

    for (0..kernel.ipc.endpoint.MESSAGE_CAPACITY) |index| {
        const word: u32 = @intCast(index);
        try std.testing.expectEqual(
            abi.ipc.Message{ .words = .{ word, word + 10, word + 20 } },
            try kernel.ipc.endpoint.receive(handle),
        );
    }
    try std.testing.expectError(error.EndpointEmpty, kernel.ipc.endpoint.receive(handle));
}

test "IPC endpoint: destruction rejects queued messages and invalidates stale handles" {
    resetState();
    const stale = try kernel.ipc.endpoint.create();
    try kernel.ipc.endpoint.send(stale, .{ .words = .{ 1, 2, 3 } });
    try std.testing.expectError(error.EndpointInUse, kernel.ipc.endpoint.destroy(stale));
    try std.testing.expectEqual(
        abi.ipc.Message{ .words = .{ 1, 2, 3 } },
        try kernel.ipc.endpoint.receive(stale),
    );
    try kernel.ipc.endpoint.destroy(stale);
    try std.testing.expectError(error.InvalidEndpointHandle, kernel.ipc.endpoint.receive(stale));

    const replacement = try kernel.ipc.endpoint.create();
    try std.testing.expect(stale != replacement);
    try std.testing.expectError(error.EndpointEmpty, kernel.ipc.endpoint.receive(replacement));
}

test "IPC endpoint: fixed registry reports exhaustion explicitly" {
    resetState();
    var handles: [kernel.ipc.endpoint.MAX_ENDPOINTS]kernel.ipc.endpoint.Handle = undefined;
    for (&handles) |*handle| handle.* = try kernel.ipc.endpoint.create();
    try std.testing.expectEqual(@as(usize, 0), kernel.ipc.endpoint.availableCount());
    try std.testing.expectError(error.OutOfEndpoints, kernel.ipc.endpoint.create());
    for (handles) |handle| try kernel.ipc.endpoint.destroy(handle);
}

test "IPC capability: send and receive require independently attenuated rights" {
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        target_space_capability,
        .{ .manage = true },
    );
    const send_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .send = true },
    );
    const receive_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .receive = true },
    );

    try kernel.capability.sendEndpointMessage(
        target_space,
        send_capability,
        .{ .words = .{ 0x11, 0x22, 0x33 } },
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.receiveEndpointMessage(target_space, send_capability),
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.sendEndpointMessage(target_space, receive_capability, .{}),
    );
    try std.testing.expectEqual(
        abi.ipc.Message{ .words = .{ 0x11, 0x22, 0x33 } },
        try kernel.capability.receiveEndpointMessage(target_space, receive_capability),
    );
    try std.testing.expectError(
        error.CapabilityHasDescendants,
        kernel.capability.destroyEndpointCapability(root_space, endpoint_capability),
    );
    try kernel.capability.deleteCapability(target_space, send_capability);
    try kernel.capability.deleteCapability(target_space, receive_capability);
    try kernel.capability.destroyEndpointCapability(root_space, endpoint_capability);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{}),
    );
}

test "IPC syscall: production dispatch returns three message registers" {
    resetState();
    try kernel.process.execution_context.initialize(.{
        .thread_handle = kernel.process.ROOT_PROCESS_HANDLE,
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = kernel.process.ROOT_PROCESS_HANDLE,
        .process_handle = kernel.process.ROOT_PROCESS_HANDLE,
    });
    const endpoint_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_endpoint, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };

    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_receive, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .failure => |failure| {
            try std.testing.expectEqual(error.EndpointEmpty, failure.err);
            try std.testing.expectEqual(
                abi.syscall.errorResult(.endpoint_empty),
                failure.return_value,
            );
        },
        else => return error.UnexpectedSyscallResult,
    }

    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_send, .{ endpoint_capability, 0x1234, 0x5678, 0x9abc, 0 }),
    )) {
        .returned => |status| try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, status),
        else => return error.UnexpectedSyscallResult,
    }
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.destroy_endpoint, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .failure => |failure| {
            try std.testing.expectEqual(error.EndpointInUse, failure.err);
            try std.testing.expectEqual(
                abi.syscall.errorResult(.object_in_use),
                failure.return_value,
            );
        },
        else => return error.UnexpectedSyscallResult,
    }
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_receive, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .returned_registers => |registers| {
            try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, registers.status);
            try std.testing.expectEqual([3]u64{ 0x1234, 0x5678, 0x9abc }, registers.words);
        },
        else => return error.UnexpectedSyscallResult,
    }
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.destroy_endpoint, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .returned => |status| try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, status),
        else => return error.UnexpectedSyscallResult,
    }
}
