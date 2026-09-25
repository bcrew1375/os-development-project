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
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000 + owner * 0x1000,
        .stack_pointer = 0x0080_0000 + owner * 0x1000,
    });
    return handle;
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
