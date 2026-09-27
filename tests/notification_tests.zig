const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");
const std = @import("std");

fn resetState() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
}

fn request(number: abi.syscall.SyscallNumber, arguments: [5]u64) kernel.syscall.Request {
    return .{ .number = @intFromEnum(number), .arguments = arguments };
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

test "Notification: counted state saturates and reports sticky overflow once" {
    resetState();
    const handle = try kernel.ipc.notification.create();
    try kernel.ipc.notification.setPendingForTest(handle, std.math.maxInt(u32) - 1, false);
    try kernel.ipc.notification.addSignal(handle);
    try kernel.ipc.notification.addSignal(handle);
    try kernel.ipc.notification.addSignal(handle);

    const pending = (try kernel.ipc.notification.consume(handle)).?;
    try std.testing.expectEqual(std.math.maxInt(u32), pending.count);
    try std.testing.expect(pending.overflowed);
    try std.testing.expectEqual(@as(?kernel.ipc.notification.Pending, null), try kernel.ipc.notification.consume(handle));
}

test "Notification: lifecycle is bounded generation checked and rejects live binding" {
    resetState();
    var handles: [kernel.ipc.notification.MAX_NOTIFICATIONS]kernel.ipc.notification.Handle = undefined;
    for (&handles) |*handle| handle.* = try kernel.ipc.notification.create();
    try std.testing.expectError(error.OutOfNotifications, kernel.ipc.notification.create());

    const stale = handles[0];
    try kernel.ipc.notification.destroy(stale);
    const replacement = try kernel.ipc.notification.create();
    try std.testing.expect(stale != replacement);
    try std.testing.expectError(error.InvalidNotificationHandle, kernel.ipc.notification.addSignal(stale));

    const source = try kernel.ipc.interrupt_source.create(.timer, 1000);
    try kernel.ipc.notification.bindSource(replacement, source);
    try std.testing.expectError(error.NotificationInUse, kernel.ipc.notification.destroy(replacement));
}

test "Notification: wait blocks once and signal completes retained syscall" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const waiter = try createConfiguredThread(1);
    const survivor = try createConfiguredThread(2);
    try initializeRunningThread(waiter, survivor);
    const notification_handle = try kernel.ipc.notification.create();
    const context = (try kernel.process.thread.get(waiter)).architecture_context_handle;
    try arch.thread_context.beginSyscall(context, 0x1000);

    try std.testing.expectEqual(
        kernel.ipc.notification_operations.WaitOutcome.blocked,
        try kernel.ipc.notification_operations.wait(notification_handle, .{
            .capability_space_handle = 1,
            .capability_handle = 2,
        }),
    );
    try std.testing.expectEqual(survivor, kernel.process.scheduler.currentThreadForTest().?);
    try kernel.ipc.notification_operations.signal(notification_handle);

    const completed = (try arch.thread_context.getCompletedSyscallForTest(context)).?;
    try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, completed.status);
    try std.testing.expectEqual([3]u64{ 1, 0, 0 }, completed.words);
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(waiter)).state);
}

test "Notification: capability deletion cancels only its authorized waiter" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const waiter = try createConfiguredThread(3);
    const survivor = try createConfiguredThread(4);
    try initializeRunningThread(waiter, survivor);
    const capability_handle = try kernel.capability.createNotificationCapability(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
    );
    const notification_handle = try kernel.capability.resolveNotification(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        capability_handle,
        .{ .wait = true },
    );
    const context = (try kernel.process.thread.get(waiter)).architecture_context_handle;
    try arch.thread_context.beginSyscall(context, 0x1000);
    _ = try kernel.ipc.notification_operations.wait(notification_handle, .{
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .capability_handle = capability_handle,
    });

    try kernel.capability.deleteCapability(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        capability_handle,
    );
    const completed = (try arch.thread_context.getCompletedSyscallForTest(context)).?;
    try std.testing.expectEqual(
        abi.syscall.errorResult(.notification_canceled),
        completed.status,
    );
    try std.testing.expectEqual(kernel.process.thread.State.ready, (try kernel.process.thread.get(waiter)).state);
}

test "Notification: timer binding masks delivery and acknowledgment rearms source" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    const notification_handle = try kernel.ipc.notification.create();
    const source_handle = try kernel.ipc.interrupt_source.create(.timer, 250);

    try kernel.ipc.notification_operations.bind(source_handle, notification_handle);
    try std.testing.expectEqual(@as(?usize, 250), arch.impl.platform.getStateForTest().timer_frequency);
    try std.testing.expect(arch.impl.interrupts.getStateForTest().timer_masked);

    const waiter = try createConfiguredThread(5);
    const survivor = try createConfiguredThread(6);
    try initializeRunningThread(waiter, survivor);
    const context = (try kernel.process.thread.get(waiter)).architecture_context_handle;
    try arch.thread_context.beginSyscall(context, 0x1000);
    _ = try kernel.ipc.notification_operations.wait(notification_handle, .{
        .capability_space_handle = 1,
        .capability_handle = 1,
    });
    try std.testing.expect(!arch.impl.interrupts.getStateForTest().timer_masked);

    try kernel.ipc.notification_operations.deliverInterrupt(.timer);
    try std.testing.expect(arch.impl.interrupts.getStateForTest().timer_masked);
    try std.testing.expectEqual(@as(u32, 0), (try kernel.ipc.notification.pendingForTest(notification_handle)).count);
    const completed = (try arch.thread_context.getCompletedSyscallForTest(context)).?;
    try std.testing.expectEqual([3]u64{ 1, 0, 0 }, completed.words);

    try kernel.ipc.notification_operations.deliverInterrupt(.timer);
    try std.testing.expectEqual(@as(u32, 0), (try kernel.ipc.notification.pendingForTest(notification_handle)).count);
    try kernel.ipc.notification_operations.acknowledge(source_handle);
    try std.testing.expect(!arch.impl.interrupts.getStateForTest().timer_masked);
    try kernel.ipc.notification_operations.unbind(source_handle);
    try std.testing.expect(arch.impl.interrupts.getStateForTest().timer_masked);
}

test "Notification: capability rights authorize wait signal bind and acknowledge independently" {
    resetState();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const child_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const child_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        child_space_capability,
        .{},
    );
    const notification_capability = try kernel.capability.createNotificationCapability(root_space);
    const wait_only = try kernel.capability.installCapability(
        root_space,
        child_space_capability,
        notification_capability,
        .{ .wait = true },
    );
    _ = try kernel.capability.resolveNotification(child_space, wait_only, .{ .wait = true });
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolveNotification(child_space, wait_only, .{ .signal = true }),
    );

    const source_capability = try kernel.capability.createInterruptSourceCapability(root_space, .timer, 1000);
    const acknowledge_only = try kernel.capability.installCapability(
        root_space,
        child_space_capability,
        source_capability,
        .{ .acknowledge = true },
    );
    _ = try kernel.capability.resolveInterruptSource(
        child_space,
        acknowledge_only,
        .{ .acknowledge = true },
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolveInterruptSource(child_space, acknowledge_only, .{ .bind = true }),
    );
}

test "Notification: production syscalls return counted state and enforce source lifecycle" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetState();
    try kernel.process.execution_context.initialize(.{
        .thread_handle = 1,
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = 1,
        .process_handle = kernel.process.ROOT_PROCESS_HANDLE,
    });

    const notification_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_notification, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    _ = kernel.syscall.dispatchFromCurrentContext(
        request(.notification_signal, .{ notification_capability, 0, 0, 0, 0 }),
    );
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.notification_wait, .{ notification_capability, 0, 0, 0, 0 }),
    )) {
        .returned_registers => |result| {
            try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, result.status);
            try std.testing.expectEqual([3]u64{ 1, 0, 0 }, result.words);
        },
        else => return error.UnexpectedSyscallResult,
    }

    const source_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_interrupt_source, .{ @intFromEnum(abi.notification.InterruptSourceKind.timer), 1000, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.bind_interrupt_source, .{ source_capability, notification_capability, 0, 0, 0 }),
    )) {
        .returned => |status| try std.testing.expectEqual(abi.syscall.SYSCALL_SUCCESS, status),
        else => return error.UnexpectedSyscallResult,
    }
    switch (kernel.syscall.dispatchFromCurrentContext(
        request(.destroy_interrupt_source, .{ source_capability, 0, 0, 0, 0 }),
    )) {
        .failure => |failure| try std.testing.expectEqual(error.InterruptSourceInUse, failure.err),
        else => return error.UnexpectedSyscallResult,
    }
}
