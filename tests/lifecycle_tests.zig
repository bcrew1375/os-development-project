const arch = @import("arch");
const abi = @import("abi");
const kernel = @import("kernel_common");
const std = @import("std");

fn setup() !void {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    kernel.process.resetForTest();
}

fn createConfiguredThread(owner: kernel.process.ProcessHandle) !kernel.process.thread.Handle {
    return createConfiguredThreadWithLifecycle(owner, 0, 0);
}

fn createConfiguredThreadWithLifecycle(
    owner: kernel.process.ProcessHandle,
    lifecycle_endpoint: kernel.ipc.endpoint.Handle,
    lifecycle_token: u32,
) !kernel.process.thread.Handle {
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000 + owner * 0x1000,
        .stack_pointer = 0x0080_0000 + owner * 0x1000,
        .lifecycle_endpoint_handle = lifecycle_endpoint,
        .lifecycle_token = lifecycle_token,
    });
    return handle;
}

fn createConfiguredThreadWithFaultManager(
    owner: kernel.process.ProcessHandle,
    fault_endpoint: kernel.ipc.endpoint.Handle,
    fault_token: u32,
) !kernel.process.thread.Handle {
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000 + owner * 0x1000,
        .stack_pointer = 0x0080_0000 + owner * 0x1000,
        .fault_endpoint_handle = fault_endpoint,
        .fault_token = fault_token,
    });
    return handle;
}

test "Lifecycle: normal exit queues one authoritative terminal event" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const lifecycle_endpoint = try kernel.ipc.endpoint.create();
    const exiting = try createConfiguredThreadWithLifecycle(1, lifecycle_endpoint, 41);
    const survivor = try createConfiguredThread(2);
    try initializeCurrent(exiting);
    try kernel.process.scheduler.makeReady(survivor);

    try kernel.process.lifecycle.exitCurrent(37);

    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.messageCount(lifecycle_endpoint));
    try std.testing.expectEqual(
        abi.process.LifecycleEvent{ .kind = .exited, .lifecycle_token = 41, .value = 37 },
        try abi.process.decodeLifecycleEvent(try kernel.ipc.endpoint.receive(lifecycle_endpoint)),
    );
    try std.testing.expectError(error.EndpointEmpty, kernel.ipc.endpoint.receive(lifecycle_endpoint));
    try std.testing.expectError(error.InvalidStateTransition, kernel.process.thread.exit(exiting, 38));
    try std.testing.expectError(error.EndpointEmpty, kernel.ipc.endpoint.receive(lifecycle_endpoint));
}

test "Lifecycle: fault wakes a blocked manager receiver with a coarse fault reason" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const lifecycle_endpoint = try kernel.ipc.endpoint.create();
    const manager = try createConfiguredThread(1);
    const faulting = try createConfiguredThreadWithLifecycle(2, lifecycle_endpoint, 73);
    try initializeCurrent(manager);
    try kernel.process.scheduler.makeReady(faulting);
    const manager_context = (try kernel.process.thread.get(manager)).architecture_context_handle;
    try arch.thread_context.beginSyscall(manager_context, 0x1000);
    try kernel.ipc.endpoint.enqueueReceiver(lifecycle_endpoint, .{
        .thread_handle = manager,
        .architecture_context_handle = manager_context,
        .authorization = .{ .capability_space_handle = 1, .capability_handle = 2 },
    });
    try kernel.process.scheduler.blockCurrentForEndpoint(.{ .endpoint_receive = lifecycle_endpoint });

    try kernel.process.lifecycle.faultCurrent(.{
        .kind = .invalid_opcode,
        .instruction_pointer = 0x0040_1234,
    });

    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.receiverCount(lifecycle_endpoint));
    try std.testing.expectEqual(kernel.process.thread.State.running, (try kernel.process.thread.get(manager)).state);
    const completion = (try arch.thread_context.getCompletedSyscallForTest(manager_context)) orelse
        return error.MissingSyscallCompletion;
    try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, completion.status);
    try std.testing.expectEqual(
        [_]u64{
            @intFromEnum(abi.process.LifecycleEventKind.faulted),
            73,
            @intFromEnum(abi.process.FaultReason.invalid_opcode),
        },
        completion.words,
    );
}

test "Lifecycle: configured endpoint remains pinned until the thread is destroyed" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const lifecycle_endpoint = try kernel.ipc.endpoint.create();
    const handle = try createConfiguredThreadWithLifecycle(1, lifecycle_endpoint, 99);
    try std.testing.expect(kernel.process.thread.referencesLifecycleEndpoint(lifecycle_endpoint));
    try std.testing.expectError(error.EndpointInUse, kernel.ipc.operations.destroy(lifecycle_endpoint));
    try kernel.process.thread.destroy(handle);
    try std.testing.expect(!kernel.process.thread.referencesLifecycleEndpoint(lifecycle_endpoint));
    try kernel.ipc.operations.destroy(lifecycle_endpoint);
}

test "Lifecycle: managed fault queues a complete event and suspends the faulting thread" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const fault_endpoint = try kernel.ipc.endpoint.create();
    const faulting = try createConfiguredThreadWithFaultManager(7, fault_endpoint, 0x1234);
    const survivor = try createConfiguredThread(8);
    try initializeCurrent(faulting);
    try kernel.process.scheduler.makeReady(survivor);
    const fault = kernel.process.thread.UserFault{
        .kind = .page_fault,
        .instruction_pointer = 0x0040_1234,
        .address = 0x00de_ad00,
        .architecture_error = 0x17,
    };

    try kernel.process.lifecycle.faultCurrentFromFrame(fault, 0x2000);

    const suspended = try kernel.process.thread.get(faulting);
    try std.testing.expectEqual(kernel.process.thread.State.blocked, suspended.state);
    try std.testing.expectEqualDeep(
        @as(?kernel.process.thread.BlockReason, .{ .fault_manager = fault_endpoint }),
        suspended.block_reason,
    );
    try std.testing.expectEqualDeep(@as(?kernel.process.thread.UserFault, fault), suspended.user_fault);
    try std.testing.expectEqual(@as(usize, abi.process.FAULT_EVENT_RECORD_COUNT), try kernel.ipc.endpoint.messageCount(fault_endpoint));
    const expected = abi.process.faultEventMessages(.{
        .fault_token = 0x1234,
        .thread_handle = faulting,
        .reason = .page_fault,
        .address = fault.address,
        .instruction_pointer = fault.instruction_pointer,
        .architecture_data = fault.architecture_error,
    });
    for (expected) |message| {
        try std.testing.expectEqual(message, try kernel.ipc.endpoint.receive(fault_endpoint));
    }
    try std.testing.expectError(
        error.InvalidStateTransition,
        kernel.process.scheduler.resumeThread(faulting),
    );
    try std.testing.expectEqual(
        @as(?u64, fault.instruction_pointer),
        try arch.thread_context.getFaultInstructionPointerForTest(
            suspended.architecture_context_handle,
        ),
    );
}

test "Lifecycle: unavailable fault capacity falls back without a partial event" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const fault_endpoint = try kernel.ipc.endpoint.create();
    for (0..kernel.ipc.endpoint.MESSAGE_CAPACITY - 3) |index| {
        const word: u32 = @intCast(index);
        try kernel.ipc.endpoint.send(fault_endpoint, .{ .words = .{ word, 0, 0 } });
    }
    const faulting = try createConfiguredThreadWithFaultManager(9, fault_endpoint, 0x5678);
    try initializeCurrent(faulting);

    try kernel.process.lifecycle.faultCurrentFromFrame(.{
        .kind = .invalid_opcode,
        .instruction_pointer = 0x0040_2000,
    }, 0x3000);

    const faulted = try kernel.process.thread.get(faulting);
    try std.testing.expectEqual(kernel.process.thread.State.faulted, faulted.state);
    try std.testing.expectEqual(
        kernel.ipc.endpoint.MESSAGE_CAPACITY - 3,
        try kernel.ipc.endpoint.messageCount(fault_endpoint),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        try arch.thread_context.getFaultInstructionPointerForTest(
            faulted.architecture_context_handle,
        ),
    );
}

test "Lifecycle: fault-manager endpoint remains pinned until thread destruction" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const fault_endpoint = try kernel.ipc.endpoint.create();
    const handle = try createConfiguredThreadWithFaultManager(10, fault_endpoint, 99);
    try std.testing.expect(kernel.process.thread.referencesFaultEndpoint(fault_endpoint));
    try std.testing.expectError(error.EndpointInUse, kernel.ipc.operations.destroy(fault_endpoint));
    try kernel.process.thread.destroy(handle);
    try kernel.ipc.operations.destroy(fault_endpoint);
}

test "Lifecycle: manager recovery is one-shot and supports IP replacement or termination" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const fault_endpoint = try kernel.ipc.endpoint.create();
    const faulting = try createConfiguredThreadWithFaultManager(11, fault_endpoint, 101);
    const survivor = try createConfiguredThread(12);
    try initializeCurrent(faulting);
    try kernel.process.scheduler.makeReady(survivor);
    try kernel.process.lifecycle.faultCurrentFromFrame(.{
        .kind = .invalid_opcode,
        .instruction_pointer = 0x0040_3000,
    }, 0x4000);
    const context = (try kernel.process.thread.get(faulting)).architecture_context_handle;

    const pending = try kernel.process.scheduler.prepareFaultResume(faulting, fault_endpoint, 101);
    try arch.thread_context.setFaultInstructionPointer(pending.architecture_context_handle, 0x0040_4000);
    try arch.thread_context.clearFaultFrame(pending.architecture_context_handle);
    try kernel.process.scheduler.commitFaultResume(faulting, fault_endpoint, 101);
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(faulting)).state);
    try std.testing.expectEqual(@as(?u64, null), try arch.thread_context.getFaultInstructionPointerForTest(context));
    try std.testing.expectError(
        error.InvalidStateTransition,
        kernel.process.scheduler.prepareFaultResume(faulting, fault_endpoint, 101),
    );

    try kernel.process.scheduler.terminate(faulting, 23);
    try std.testing.expectEqual(kernel.process.thread.State.exited, (try kernel.process.thread.get(faulting)).state);
    try std.testing.expectEqual(@as(?u64, 23), (try kernel.process.thread.get(faulting)).exit_status);
}

fn initializeCurrent(handle: kernel.process.thread.Handle) !void {
    const object = try kernel.process.thread.get(handle);
    try kernel.process.scheduler.initialize(
        try kernel.process.getAddressSpaceRoot(object.address_space_handle),
    );
    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);
    try kernel.process.scheduler.setCurrentThreadForTest(handle);
}

test "Lifecycle: exit records status and schedules another runnable thread" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const exiting = try createConfiguredThread(1);
    const survivor = try createConfiguredThread(2);
    try initializeCurrent(exiting);
    try kernel.process.scheduler.makeReady(survivor);

    try kernel.process.lifecycle.exitCurrent(37);

    const exited = try kernel.process.thread.get(exiting);
    try std.testing.expectEqual(kernel.process.thread.State.exited, exited.state);
    try std.testing.expectEqual(@as(?u64, 37), exited.exit_status);
    try std.testing.expectEqual(@as(?kernel.process.thread.UserFault, null), exited.user_fault);
    try std.testing.expectEqual(
        @as(?kernel.process.thread.Handle, survivor),
        kernel.process.scheduler.currentThreadForTest(),
    );
    try std.testing.expectEqual(
        kernel.process.thread.State.running,
        (try kernel.process.thread.get(survivor)).state,
    );
}

test "Lifecycle: user fault records architecture data and selects idle" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const handle = try createConfiguredThread(3);
    try initializeCurrent(handle);
    const fault = kernel.process.thread.UserFault{
        .kind = .page_fault,
        .instruction_pointer = 0x0040_1234,
        .address = 0x00de_ad00,
        .architecture_error = 0x17,
    };

    try kernel.process.lifecycle.faultCurrent(fault);

    const faulted = try kernel.process.thread.get(handle);
    try std.testing.expectEqual(kernel.process.thread.State.faulted, faulted.state);
    try std.testing.expectEqual(@as(?u64, null), faulted.exit_status);
    try std.testing.expectEqualDeep(@as(?kernel.process.thread.UserFault, fault), faulted.user_fault);
    try std.testing.expectEqual(
        @as(?kernel.process.thread.Handle, null),
        kernel.process.scheduler.currentThreadForTest(),
    );
    try std.testing.expectError(
        error.ExecutionContextUninitialized,
        kernel.process.execution_context.current(),
    );
}

test "Lifecycle: terminating a blocked IPC thread removes its waiter" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const blocked = try createConfiguredThread(4);
    const survivor = try createConfiguredThread(5);
    try initializeCurrent(blocked);
    try kernel.process.scheduler.makeReady(survivor);
    const endpoint_handle = try kernel.ipc.endpoint.create();
    try kernel.ipc.endpoint.enqueueReceiver(endpoint_handle, .{
        .thread_handle = blocked,
        .architecture_context_handle = (try kernel.process.thread.get(blocked)).architecture_context_handle,
        .authorization = .{ .capability_space_handle = 1, .capability_handle = 2 },
    });
    try kernel.process.scheduler.blockCurrentForEndpoint(.{ .endpoint_receive = endpoint_handle });
    try std.testing.expectEqual(@as(usize, 1), try kernel.ipc.endpoint.receiverCount(endpoint_handle));

    try kernel.process.scheduler.terminate(blocked, 9);
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.receiverCount(endpoint_handle));
    try std.testing.expectEqual(kernel.process.thread.State.exited, (try kernel.process.thread.get(blocked)).state);
}

test "Lifecycle: faulting a thread removes any retained IPC waiter" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const handle = try createConfiguredThread(6);
    try initializeCurrent(handle);
    const endpoint_handle = try kernel.ipc.endpoint.create();
    try kernel.ipc.endpoint.enqueueReceiver(endpoint_handle, .{
        .thread_handle = handle,
        .architecture_context_handle = (try kernel.process.thread.get(handle)).architecture_context_handle,
        .authorization = .{ .capability_space_handle = 1, .capability_handle = 2 },
    });
    const fault = kernel.process.thread.UserFault{
        .kind = .invalid_opcode,
        .instruction_pointer = 0x0040_1234,
    };

    try kernel.process.lifecycle.faultCurrent(fault);
    try std.testing.expectEqual(@as(usize, 0), try kernel.ipc.endpoint.receiverCount(endpoint_handle));
    const faulted = try kernel.process.thread.get(handle);
    try std.testing.expectEqual(kernel.process.thread.State.faulted, faulted.state);
    try std.testing.expectEqualDeep(@as(?kernel.process.thread.UserFault, fault), faulted.user_fault);
}
