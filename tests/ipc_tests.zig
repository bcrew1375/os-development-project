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

test "IPC endpoint: batch delivery is all-or-nothing" {
    resetState();
    const handle = try kernel.ipc.endpoint.create();
    for (0..kernel.ipc.endpoint.MESSAGE_CAPACITY - 1) |index| {
        const word: u32 = @intCast(index);
        try kernel.ipc.endpoint.send(handle, .{ .words = .{ word, 0, 0 } });
    }
    const messages = [_]abi.ipc.Message{
        .{ .words = .{ 91, 92, 93 } },
        .{ .words = .{ 94, 95, 96 } },
    };
    try std.testing.expectError(error.EndpointFull, kernel.ipc.endpoint.sendBatch(handle, &messages));
    try std.testing.expectEqual(
        kernel.ipc.endpoint.MESSAGE_CAPACITY - 1,
        try kernel.ipc.endpoint.messageCount(handle),
    );
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

test "IPC capability transfer: blocked receiver gets attenuated exact-slot capability" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(root_space, target_space_capability, .{});
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const receive_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .receive = true },
    );
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const receiver = try createConfiguredThreadInSpace(9, target_space);
    const sender = try createConfiguredThread(10);
    try initializeRunningThread(receiver, sender);
    const receiver_context = (try kernel.process.thread.get(receiver)).architecture_context_handle;
    try arch.thread_context.beginSyscall(receiver_context, 0x5000);
    try std.testing.expectEqual(
        kernel.ipc.transfer_operations.ReceiveOutcome.blocked,
        try kernel.ipc.transfer_operations.receive(
            endpoint_handle,
            .{ .capability_space_handle = target_space, .capability_handle = receive_capability },
            target_space,
            .{ .destination_slot = 20 },
        ),
    );

    try std.testing.expectEqual(
        kernel.ipc.transfer_operations.Outcome.completed,
        try kernel.ipc.transfer_operations.send(
            endpoint_handle,
            .{ .capability_space_handle = root_space, .capability_handle = endpoint_capability },
            root_space,
            .{
                .source_capability = endpoint_capability,
                .rights_bits = abi.capability.rightsBits(.{ .send = true }),
                .message = .{ .words = .{ 7, 8, 9 } },
            },
        ),
    );
    const completed = (try arch.thread_context.getCompletedSyscallForTest(receiver_context)).?;
    try std.testing.expectEqual([3]u64{ 7, 8, 9 }, completed.words);
    try std.testing.expectEqual(@as(u32, 20), abi.capability.capabilitySlotIndex(@truncate(completed.capability.?)));
    _ = try kernel.capability.resolveEndpoint(target_space, @truncate(completed.capability.?), .{ .send = true });
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolveEndpoint(target_space, @truncate(completed.capability.?), .{ .receive = true }),
    );
}

test "IPC capability transfer: blocked sender wakes after direct receive" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(root_space, target_space_capability, .{});
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const receive_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .receive = true },
    );
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const sender = try createConfiguredThread(11);
    const receiver = try createConfiguredThreadInSpace(12, target_space);
    try initializeRunningThread(sender, receiver);
    const sender_context = (try kernel.process.thread.get(sender)).architecture_context_handle;
    try arch.thread_context.beginSyscall(sender_context, 0x6000);
    try std.testing.expectEqual(
        kernel.ipc.transfer_operations.Outcome.blocked,
        try kernel.ipc.transfer_operations.send(
            endpoint_handle,
            .{ .capability_space_handle = root_space, .capability_handle = endpoint_capability },
            root_space,
            .{
                .source_capability = endpoint_capability,
                .rights_bits = abi.capability.rightsBits(.{ .receive = true }),
                .message = .{ .words = .{ 10, 11, 12 } },
            },
        ),
    );

    const outcome = try kernel.ipc.transfer_operations.receive(
        endpoint_handle,
        .{ .capability_space_handle = target_space, .capability_handle = receive_capability },
        target_space,
        .{ .destination_slot = 21 },
    );
    const transfer = switch (outcome) {
        .completed => |completed| completed,
        .blocked => return error.UnexpectedTransferOutcome,
    };
    try std.testing.expectEqual(abi.ipc.Message{ .words = .{ 10, 11, 12 } }, transfer.message);
    try std.testing.expectEqual(@as(u32, 21), abi.capability.capabilitySlotIndex(transfer.capability));
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, .fromStatus(abi.syscall.SYSCALL_SUCCESS)),
        try arch.thread_context.getCompletedSyscallForTest(sender_context),
    );
}

test "IPC capability transfer: occupied destination preserves blocked receiver and source" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(root_space, target_space_capability, .{});
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const receive_capability = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .receive = true },
    );
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const receiver = try createConfiguredThreadInSpace(13, target_space);
    const sender = try createConfiguredThread(14);
    try initializeRunningThread(receiver, sender);
    const receiver_context = (try kernel.process.thread.get(receiver)).architecture_context_handle;
    try arch.thread_context.beginSyscall(receiver_context, 0x7000);
    _ = try kernel.ipc.transfer_operations.receive(
        endpoint_handle,
        .{ .capability_space_handle = target_space, .capability_handle = receive_capability },
        target_space,
        .{ .destination_slot = 22 },
    );
    const occupied = try kernel.capability.prepareExactInstall(
        root_space,
        endpoint_capability,
        target_space,
        22,
        .{},
    );
    _ = kernel.capability.commitExactInstall(occupied);

    try std.testing.expectError(
        error.CapabilitySlotOccupied,
        kernel.ipc.transfer_operations.send(
            endpoint_handle,
            .{ .capability_space_handle = root_space, .capability_handle = endpoint_capability },
            root_space,
            .{
                .source_capability = endpoint_capability,
                .rights_bits = abi.capability.rightsBits(.{ .send = true }),
                .message = .{ .words = .{ 1, 2, 3 } },
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.transferReceiverCount(endpoint_handle));
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, null),
        try arch.thread_context.getCompletedSyscallForTest(receiver_context),
    );
    _ = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{ .grant = true });
}

test "IPC capability transfer: ordinary and transfer waiters do not cross-match" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const first = try createConfiguredThread(15);
    const second = try createConfiguredThread(16);
    try initializeRunningThread(first, second);
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const first_context = (try kernel.process.thread.get(first)).architecture_context_handle;
    try arch.thread_context.beginSyscall(first_context, 0x8000);
    _ = try kernel.ipc.operations.receive(
        endpoint_handle,
        .{ .capability_space_handle = root_space, .capability_handle = endpoint_capability },
    );

    const second_context = (try kernel.process.thread.get(second)).architecture_context_handle;
    try arch.thread_context.beginSyscall(second_context, 0x9000);
    try std.testing.expectEqual(
        kernel.ipc.transfer_operations.Outcome.blocked,
        try kernel.ipc.transfer_operations.send(
            endpoint_handle,
            .{ .capability_space_handle = root_space, .capability_handle = endpoint_capability },
            root_space,
            .{
                .source_capability = endpoint_capability,
                .rights_bits = abi.capability.rightsBits(.{}),
                .message = .{ .words = .{ 4, 5, 6 } },
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.receiverCount(endpoint_handle));
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.transferSenderCount(endpoint_handle));
}

test "IPC capability transfer: deleting source capability cancels blocked transfer sender" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(root_space, target_space_capability, .{});
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const source = try kernel.capability.createEndpointCapability(target_space);
    const sender = try createConfiguredThreadInSpace(17, target_space);
    const survivor = try createConfiguredThread(18);
    try initializeRunningThread(sender, survivor);
    const sender_context = (try kernel.process.thread.get(sender)).architecture_context_handle;
    try arch.thread_context.beginSyscall(sender_context, 0xa000);
    try std.testing.expectEqual(
        kernel.ipc.transfer_operations.Outcome.blocked,
        try kernel.ipc.transfer_operations.send(
            endpoint_handle,
            .{ .capability_space_handle = target_space, .capability_handle = endpoint_capability },
            target_space,
            .{
                .source_capability = source,
                .rights_bits = abi.capability.rightsBits(.{ .send = true }),
                .message = .{ .words = .{ 1, 2, 3 } },
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.transferSenderCount(endpoint_handle));

    try kernel.capability.deleteCapability(target_space, source);
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.transferSenderCount(endpoint_handle));
    try std.testing.expectEqual(
        @as(?arch.SyscallResultRegisters, .fromStatus(abi.syscall.errorResult(.endpoint_canceled))),
        try arch.thread_context.getCompletedSyscallForTest(sender_context),
    );
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(sender)).state);
}

test "IPC capability transfer: forged stale and ungranted source handles are rejected" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(root_space, target_space_capability, .{});
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const endpoint_authorization = kernel.ipc.endpoint.Authorization{
        .capability_space_handle = root_space,
        .capability_handle = endpoint_capability,
    };

    const forged: abi.capability.CapabilityHandle = 0x0000_dead;
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.ipc.transfer_operations.send(endpoint_handle, endpoint_authorization, root_space, .{
            .source_capability = forged,
            .rights_bits = abi.capability.rightsBits(.{}),
            .message = .{},
        }),
    );

    const ungranted = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        endpoint_capability,
        .{ .send = true },
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.ipc.transfer_operations.send(endpoint_handle, endpoint_authorization, target_space, .{
            .source_capability = ungranted,
            .rights_bits = abi.capability.rightsBits(.{ .send = true }),
            .message = .{},
        }),
    );

    try kernel.capability.deleteCapability(target_space, ungranted);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.ipc.transfer_operations.send(endpoint_handle, endpoint_authorization, target_space, .{
            .source_capability = ungranted,
            .rights_bits = abi.capability.rightsBits(.{}),
            .message = .{},
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.transferReceiverCount(endpoint_handle));
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.transferSenderCount(endpoint_handle));
}

test "IPC capability transfer: revoking memory authority invalidates transferred descendant" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(root_space, target_space_capability, .{});
    const endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const endpoint_handle = try kernel.capability.resolveEndpoint(root_space, endpoint_capability, .{});
    const root_untyped = try kernel.capability.createUntypedMemoryCapability(
        root_space,
        0,
        0x2000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    const root_frame = try kernel.capability.retypeUntypedMemoryCapability(
        root_space,
        root_untyped,
        0,
        1,
        .physical_frame,
        .{ .manage = true, .read = true, .grant = true },
    );
    const receiver = try createConfiguredThreadInSpace(19, target_space);
    const sender = try createConfiguredThread(20);
    try initializeRunningThread(receiver, sender);
    const receiver_context = (try kernel.process.thread.get(receiver)).architecture_context_handle;
    try arch.thread_context.beginSyscall(receiver_context, 0xb000);
    _ = try kernel.ipc.transfer_operations.receive(
        endpoint_handle,
        .{ .capability_space_handle = target_space, .capability_handle = endpoint_capability },
        target_space,
        .{ .destination_slot = 30 },
    );
    _ = try kernel.ipc.transfer_operations.send(
        endpoint_handle,
        .{ .capability_space_handle = root_space, .capability_handle = endpoint_capability },
        root_space,
        .{
            .source_capability = root_frame,
            .rights_bits = abi.capability.rightsBits(.{ .read = true }),
            .message = .{ .words = .{ 9, 8, 7 } },
        },
    );
    const completed = (try arch.thread_context.getCompletedSyscallForTest(receiver_context)).?;
    const transferred_handle: abi.capability.CapabilityHandle = @truncate(completed.capability.?);
    _ = try kernel.capability.resolvePhysicalFrame(target_space, transferred_handle, .{ .read = true });

    try kernel.capability.revokePhysicalMemoryCapability(root_space, root_untyped);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolvePhysicalFrame(target_space, transferred_handle, .{}),
    );
}

test "IPC capability transfer: production syscall copies requests and writes back 4 registers" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const receiver = try createConfiguredThread(21);
    const sender = try createConfiguredThread(22);
    try initializeRunningThread(receiver, sender);
    const endpoint_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_endpoint, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };

    const root = (try kernel.process.thread.get(receiver)).address_space_handle;
    const root_mmu = try kernel.process.getAddressSpaceRoot(root);
    try arch.mmu.mapTableInAddressSpace(root_mmu, 0x0040_0000, 0, .{ .user = true, .write = true });
    try arch.mmu.mapPageInAddressSpace(root_mmu, 0x0040_0000, 0x1000, .{ .user = true, .write = true });
    // Production request decoding copies from the currently active user address
    // space, so activate the receiver's root before dispatching its syscall.
    arch.mmu.switchAddressSpaceRoot(root_mmu);

    const recv_request = abi.ipc.TransferReceiveRequest{ .destination_slot = 44 };
    try arch.impl.mmu.writePhysicalMemoryForTest(0x1000, std.mem.asBytes(&recv_request));
    const receiver_context = (try kernel.process.thread.get(receiver)).architecture_context_handle;
    try arch.thread_context.beginSyscall(receiver_context, 0xc000);
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_receive_capability, .{ endpoint_capability, 0x0040_0000, 0, 0, 0 }),
    )) {
        .blocked => {},
        else => return error.UnexpectedSyscallResult,
    }

    const sender_address_space = (try kernel.process.thread.get(sender)).address_space_handle;
    const sender_mmu = try kernel.process.getAddressSpaceRoot(sender_address_space);
    try arch.mmu.mapTableInAddressSpace(sender_mmu, 0x0040_0000, 0, .{ .user = true, .write = true });
    try arch.mmu.mapPageInAddressSpace(sender_mmu, 0x0040_0000, 0x2000, .{ .user = true, .write = true });
    const send_request = abi.ipc.TransferSendRequest{
        .source_capability = endpoint_capability,
        .rights_bits = abi.capability.rightsBits(.{ .receive = true }),
        .message = .{ .words = .{ 0xaaaa, 0xbbbb, 0xcccc } },
    };
    try arch.impl.mmu.writePhysicalMemoryForTest(0x2000, std.mem.asBytes(&send_request));
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.endpoint_send_capability, .{ endpoint_capability, 0x0040_0000, 0, 0, 0 }),
    )) {
        .returned => |status| try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, status),
        else => return error.UnexpectedSyscallResult,
    }

    const completed = (try arch.thread_context.getCompletedSyscallForTest(receiver_context)).?;
    try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, completed.status);
    try std.testing.expectEqual([3]u64{ 0xaaaa, 0xbbbb, 0xcccc }, completed.words);
    try std.testing.expectEqual(@as(u32, 44), abi.capability.capabilitySlotIndex(@truncate(completed.capability.?)));
}
