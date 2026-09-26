const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

fn resetState() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
}

fn request(number: abi.syscall.SyscallNumber, arguments: [5]u64) kernel.syscall.Request {
    return .{ .number = @intFromEnum(number), .arguments = arguments };
}

fn createConfiguredThread(owner: kernel.process.ProcessHandle) !kernel.process.thread.Handle {
    return createConfiguredThreadInSpace(
        owner,
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
    );
}

fn createConfiguredThreadInSpace(
    owner: kernel.process.ProcessHandle,
    capability_space_handle: kernel.process.thread.CapabilitySpaceHandle,
) !kernel.process.thread.Handle {
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = capability_space_handle,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000 + owner * 0x1000,
        .stack_pointer = 0x0080_0000 + owner * 0x1000,
    });
    return handle;
}

fn initializeRunningThread(
    current: kernel.process.thread.Handle,
    ready: kernel.process.thread.Handle,
) !void {
    const object = try kernel.process.thread.get(current);
    try kernel.process.scheduler.initialize(
        try kernel.process.getAddressSpaceRoot(object.address_space_handle),
    );
    try kernel.process.thread.makeReady(current);
    try kernel.process.thread.startRunning(current);
    try kernel.process.scheduler.setCurrentThreadForTest(current);
    try kernel.process.scheduler.makeReady(ready);
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

test "IPC endpoint: waiter queues preserve FIFO and prevent primitive destruction" {
    resetState();
    const handle = try kernel.ipc.endpoint.create();
    const first = kernel.ipc.endpoint.Waiter{
        .thread_handle = 11,
        .architecture_context_handle = 21,
        .authorization = .{ .capability_space_handle = 31, .capability_handle = 41 },
    };
    const second = kernel.ipc.endpoint.Waiter{
        .thread_handle = 12,
        .architecture_context_handle = 22,
        .authorization = .{ .capability_space_handle = 32, .capability_handle = 42 },
    };
    try kernel.ipc.endpoint.enqueueReceiver(handle, first);
    try kernel.ipc.endpoint.enqueueReceiver(handle, second);
    try std.testing.expectError(error.EndpointInUse, kernel.ipc.endpoint.destroy(handle));
    try std.testing.expectEqual(first, try kernel.ipc.endpoint.popReceiver(handle));
    try std.testing.expectEqual(second, try kernel.ipc.endpoint.popReceiver(handle));

    const first_sender = kernel.ipc.endpoint.SenderWaiter{
        .waiter = first,
        .message = .{ .words = .{ 1, 2, 3 } },
    };
    const second_sender = kernel.ipc.endpoint.SenderWaiter{
        .waiter = second,
        .message = .{ .words = .{ 4, 5, 6 } },
    };
    try kernel.ipc.endpoint.enqueueSender(handle, first_sender);
    try kernel.ipc.endpoint.enqueueSender(handle, second_sender);
    try std.testing.expectEqual(first_sender, try kernel.ipc.endpoint.popSender(handle));
    try std.testing.expectEqual(second_sender, try kernel.ipc.endpoint.popSender(handle));
    try kernel.ipc.endpoint.destroy(handle);
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
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const receiver = try createConfiguredThread(1);
    const sender = try createConfiguredThread(2);
    try initializeRunningThread(receiver, sender);
    const endpoint_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_endpoint, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };

    const receiver_context = (try kernel.process.thread.get(receiver)).architecture_context_handle;
    try arch.thread_context.beginSyscall(receiver_context, 0x1000);
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_receive, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .blocked => {},
        else => return error.UnexpectedSyscallResult,
    }
    try std.testing.expectEqual(kernel.process.thread.State.blocked, (try kernel.process.thread.get(receiver)).state);
    try std.testing.expectEqual(@as(?kernel.process.thread.Handle, sender), kernel.process.scheduler.currentThreadForTest());

    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_send, .{ endpoint_capability, 0x1234, 0x5678, 0x9abc, 0 }),
    )) {
        .returned => |status| try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, status),
        else => return error.UnexpectedSyscallResult,
    }
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, .{
            .status = abi.syscall.SYSCALL_SUCCESS,
            .words = .{ 0x1234, 0x5678, 0x9abc },
        }),
        try arch.thread_context.getCompletedSyscallForTest(receiver_context),
    );
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(receiver)).state);
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.destroy_endpoint, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .returned => |status| try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, status),
        else => return error.UnexpectedSyscallResult,
    }
}

test "IPC syscall: full buffer blocks sender and receive promotes retained message" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const sender = try createConfiguredThread(3);
    const receiver = try createConfiguredThread(4);
    try initializeRunningThread(sender, receiver);
    const endpoint_capability = try kernel.capability.createEndpointCapability(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
    );
    const endpoint_handle = try kernel.capability.resolveEndpoint(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        endpoint_capability,
        .{},
    );
    for (0..kernel.ipc.endpoint.MESSAGE_CAPACITY) |index| {
        const word: u32 = @intCast(index);
        try kernel.ipc.endpoint.send(endpoint_handle, .{ .words = .{ word, word, word } });
    }

    const sender_context = (try kernel.process.thread.get(sender)).architecture_context_handle;
    try arch.thread_context.beginSyscall(sender_context, 0x2000);
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_send, .{ endpoint_capability, 99, 98, 97, 0 }),
    )) {
        .blocked => {},
        else => return error.UnexpectedSyscallResult,
    }
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.senderCount(endpoint_handle));

    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_receive, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .returned_registers => |registers| try std.testing.expectEqual(
            [3]u64{ 0, 0, 0 },
            registers.words,
        ),
        else => return error.UnexpectedSyscallResult,
    }
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.senderCount(endpoint_handle));
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, .fromStatus(abi.syscall.SYSCALL_SUCCESS)),
        try arch.thread_context.getCompletedSyscallForTest(sender_context),
    );
    for (1..kernel.ipc.endpoint.MESSAGE_CAPACITY) |index| {
        const word: u32 = @intCast(index);
        try std.testing.expectEqual(
            abi.ipc.Message{ .words = .{ word, word, word } },
            try kernel.ipc.endpoint.receive(endpoint_handle),
        );
    }
    try std.testing.expectEqual(
        abi.ipc.Message{ .words = .{ 99, 98, 97 } },
        try kernel.ipc.endpoint.receive(endpoint_handle),
    );
}

test "IPC cancellation: deleting an exact capability wakes only its blocked receiver" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        target_space_capability,
        .{ .manage = true },
    );
    const waiting_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .receive = true },
    );
    const unrelated_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .receive = true },
    );
    const handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const first = try createConfiguredThreadInSpace(5, target_space);
    const second = try createConfiguredThread(6);
    try initializeRunningThread(first, second);
    const first_context = (try kernel.process.thread.get(first)).architecture_context_handle;
    try arch.thread_context.beginSyscall(first_context, 0x3000);
    try std.testing.expectEqual(
        kernel.ipc.operations.ReceiveOutcome.blocked,
        try kernel.ipc.operations.receive(handle, .{
            .capability_space_handle = target_space,
            .capability_handle = waiting_capability,
        }),
    );

    try kernel.capability.deleteCapability(target_space, unrelated_capability);
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.receiverCount(handle));
    try kernel.capability.deleteCapability(target_space, waiting_capability);
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.receiverCount(handle));
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, .fromStatus(abi.syscall.errorResult(.endpoint_canceled))),
        try arch.thread_context.getCompletedSyscallForTest(first_context),
    );
}

test "IPC cancellation: endpoint destruction completes blocked receiver" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const receiver = try createConfiguredThread(7);
    const survivor = try createConfiguredThread(8);
    try initializeRunningThread(receiver, survivor);
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const receiver_context = (try kernel.process.thread.get(receiver)).architecture_context_handle;
    try arch.thread_context.beginSyscall(receiver_context, 0x4000);
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_receive, .{ endpoint_capability, 0, 0, 0, 0 }),
    )) {
        .blocked => {},
        else => return error.UnexpectedSyscallResult,
    }

    try kernel.capability.destroyEndpointCapability(root_space, endpoint_capability);
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, .fromStatus(abi.syscall.errorResult(.endpoint_canceled))),
        try arch.thread_context.getCompletedSyscallForTest(receiver_context),
    );
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(receiver)).state);
}
