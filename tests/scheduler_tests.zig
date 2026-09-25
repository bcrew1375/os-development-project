const arch = @import("arch");
const kernel = @import("kernel_common");
const std = @import("std");

fn setup() !void {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    kernel.process.resetForTest();
}

fn createConfiguredThread(owner: kernel.process.ProcessHandle) !kernel.process.thread.Handle {
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000 + owner * 0x1000,
        .stack_pointer = 0x0080_0000 + owner * 0x1000,
        .argument = owner,
    });
    return handle;
}

fn initializeWithRunningThread(
    handle: kernel.process.thread.Handle,
) !arch.ThreadContextHandle {
    const object = try kernel.process.thread.get(handle);
    const root = try kernel.process.getAddressSpaceRoot(object.address_space_handle);
    try kernel.process.scheduler.initialize(root);
    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);
    try kernel.process.scheduler.setCurrentThreadForTest(handle);
    return object.architecture_context_handle;
}

test "Scheduler: initialization reserves idle without consuming a userspace context" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const available_before = arch.thread_context.availableCount();
    const root = try arch.mmu.createAddressSpaceRoot();
    try kernel.process.scheduler.initialize(root);

    try std.testing.expectEqual(available_before, arch.thread_context.availableCount());
    try std.testing.expect(kernel.process.scheduler.idleContextForTest() != arch.INVALID_THREAD_CONTEXT_HANDLE);
    const configuration = arch.thread_context.getKernelConfigurationForTest().?;
    try std.testing.expectEqual(root, configuration.address_space_root);
    try std.testing.expectError(
        error.SchedulerAlreadyInitialized,
        kernel.process.scheduler.initialize(root),
    );
}

test "Scheduler: ready queue rejects duplicates and preserves state" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const handle = try createConfiguredThread(1);
    const object = try kernel.process.thread.get(handle);
    try kernel.process.scheduler.initialize(
        try kernel.process.getAddressSpaceRoot(object.address_space_handle),
    );
    try kernel.process.scheduler.makeReady(handle);

    try std.testing.expectEqual(@as(usize, 1), kernel.process.scheduler.readyCountForTest());
    try std.testing.expectError(
        error.ThreadAlreadyQueued,
        kernel.process.scheduler.makeReady(handle),
    );
    try std.testing.expectEqual(
        kernel.process.thread.State.ready,
        (try kernel.process.thread.get(handle)).state,
    );
    try std.testing.expectEqual(@as(usize, 1), kernel.process.scheduler.readyCountForTest());
}

test "Scheduler: cooperative yield follows FIFO order and installs identity" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const first = try createConfiguredThread(1);
    const second = try createConfiguredThread(2);
    const third = try createConfiguredThread(3);
    const first_context = try initializeWithRunningThread(first);
    try kernel.process.scheduler.makeReady(second);
    try kernel.process.scheduler.makeReady(third);

    try kernel.process.scheduler.yieldCurrent();
    const second_object = try kernel.process.thread.get(second);
    try std.testing.expectEqual(@as(?kernel.process.thread.Handle, second), kernel.process.scheduler.currentThreadForTest());
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(first)).state);
    try std.testing.expectEqual(kernel.process.thread.State.running, second_object.state);
    try std.testing.expectEqual(second, (try kernel.process.execution_context.current()).thread_handle);
    try std.testing.expectEqualDeep(
        @as(?arch.thread_context.SwitchOperation, .{
            .current = first_context,
            .next = second_object.architecture_context_handle,
        }),
        arch.thread_context.getLastSwitchForTest(),
    );

    try kernel.process.scheduler.yieldCurrent();
    try std.testing.expectEqual(@as(?kernel.process.thread.Handle, third), kernel.process.scheduler.currentThreadForTest());
    try std.testing.expectEqual(third, (try kernel.process.execution_context.current()).thread_handle);
    try std.testing.expectEqual(@as(usize, 2), kernel.process.scheduler.readyCountForTest());
}

test "Scheduler: a sole running thread yields to itself without switching" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const handle = try createConfiguredThread(7);
    _ = try initializeWithRunningThread(handle);
    try kernel.process.scheduler.yieldCurrent();

    try std.testing.expectEqual(@as(?kernel.process.thread.Handle, handle), kernel.process.scheduler.currentThreadForTest());
    try std.testing.expectEqual(kernel.process.thread.State.running, (try kernel.process.thread.get(handle)).state);
    try std.testing.expectEqual(@as(usize, 0), kernel.process.scheduler.readyCountForTest());
    try std.testing.expectEqual(@as(?arch.thread_context.SwitchOperation, null), arch.thread_context.getLastSwitchForTest());
}

test "Scheduler: stopping the last thread selects idle and clears execution identity" {
    try setup();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const handle = try createConfiguredThread(9);
    const current_context = try initializeWithRunningThread(handle);
    try kernel.process.thread.exit(handle, 0);
    try kernel.process.scheduler.scheduleAfterCurrentStops();

    try std.testing.expectEqual(@as(?kernel.process.thread.Handle, null), kernel.process.scheduler.currentThreadForTest());
    try std.testing.expectError(
        error.ExecutionContextUninitialized,
        kernel.process.execution_context.current(),
    );
    try std.testing.expectEqualDeep(
        @as(?arch.thread_context.SwitchOperation, .{
            .current = current_context,
            .next = kernel.process.scheduler.idleContextForTest(),
        }),
        arch.thread_context.getLastSwitchForTest(),
    );
}
