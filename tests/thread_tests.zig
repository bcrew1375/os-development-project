const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel_common");

fn testSetup() void {
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
    arch.impl.test_support.resetState();
}

fn configureRunnableThread(
    owner: kernel.process.ProcessHandle,
) !kernel.process.thread.Handle {
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
        .argument = 0x1234,
    });
    return handle;
}

test "Thread: creation publishes an unconfigured new object" {
    testSetup();

    const handle = try kernel.process.createThread(42);
    const created = try kernel.process.thread.get(handle);
    try std.testing.expectEqual(
        @as(kernel.process.ProcessHandle, 42),
        created.owner_process_handle,
    );
    try std.testing.expectEqual(kernel.process.thread.State.new, created.state);
    try std.testing.expect(!created.isConfigured());
    try std.testing.expectEqual(@as(usize, 1), kernel.process.thread.activeCount());
}

test "Thread: readiness requires a configured architecture context" {
    testSetup();
    const owner: kernel.process.ProcessHandle = 42;
    const handle = try kernel.process.createThread(owner);

    try std.testing.expectError(error.ThreadNotConfigured, kernel.process.thread.makeReady(handle));
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = 7,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
    });
    try kernel.process.thread.makeReady(handle);
    try std.testing.expectEqual(
        kernel.process.thread.State.ready,
        (try kernel.process.thread.get(handle)).state,
    );
}

test "Thread: configuration publishes architecture execution resources" {
    testSetup();
    const owner: kernel.process.ProcessHandle = 42;
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const address_space_root = try kernel.process.getAddressSpaceRoot(address_space);
    const handle = try kernel.process.createThread(owner);

    try kernel.process.configureThread(handle, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
        .argument = 0x1234,
    });

    const configured = try kernel.process.thread.get(handle);
    try std.testing.expect(configured.isConfigured());
    const context = try arch.thread_context.getForTest(configured.architecture_context_handle);
    try std.testing.expectEqual(address_space_root, context.configuration.address_space_root);
    try std.testing.expectEqual(@as(usize, 0x0040_0000), context.configuration.entry_point);
    try std.testing.expectEqual(@as(usize, 0x0080_0000), context.configuration.stack_pointer);
    try std.testing.expectEqual(@as(usize, 0x1234), context.configuration.argument);
}

test "Thread: architecture allocation failure leaves configuration unpublished" {
    testSetup();
    const owner: kernel.process.ProcessHandle = 42;
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    const available_before = arch.thread_context.availableCount();
    arch.thread_context.failNextCreateForTest();

    try std.testing.expectError(error.OutOfThreadContexts, kernel.process.configureThread(handle, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
    }));
    try std.testing.expect(!(try kernel.process.thread.get(handle)).isConfigured());
    try std.testing.expectEqual(available_before, arch.thread_context.availableCount());
}

test "Thread: configuration validates handles and address-space ownership" {
    testSetup();
    const handle = try kernel.process.createThread(42);
    const foreign_address_space = try kernel.process.createAddressSpaceForOwner(9);

    try std.testing.expectError(
        error.ThreadOwnerMismatch,
        kernel.process.configureThread(handle, .{
            .capability_space_handle = 42,
            .address_space_handle = foreign_address_space,
            .entry_point = 0x0040_0000,
            .stack_pointer = 0x0080_0000,
        }),
    );
    try std.testing.expectError(
        error.InvalidAddressSpaceHandle,
        kernel.process.configureThread(handle, .{
            .capability_space_handle = 42,
            .address_space_handle = 0,
            .entry_point = 0x0040_0000,
            .stack_pointer = 0x0080_0000,
        }),
    );
}

test "Thread: legal cooperative lifecycle transitions preserve records" {
    testSetup();
    const handle = try configureRunnableThread(42);

    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);
    try kernel.process.thread.block(handle);
    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);
    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);
    try kernel.process.thread.exit(handle, 17);

    const exited = try kernel.process.thread.get(handle);
    try std.testing.expectEqual(kernel.process.thread.State.exited, exited.state);
    try std.testing.expectEqual(@as(?u64, 17), exited.exit_status);
    try std.testing.expectEqual(
        @as(?kernel.process.thread.UserFault, null),
        exited.user_fault,
    );
    try std.testing.expectError(
        error.InvalidStateTransition,
        kernel.process.thread.makeReady(handle),
    );
}

test "Thread: a user fault is terminal and records attribution" {
    testSetup();
    const handle = try configureRunnableThread(42);
    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);

    const fault = kernel.process.thread.UserFault{
        .kind = .page_fault,
        .instruction_pointer = 0x0040_1234,
        .address = 0x00ff_f000,
        .architecture_error = 5,
    };
    try kernel.process.thread.recordFault(handle, fault);

    const faulted = try kernel.process.thread.get(handle);
    try std.testing.expectEqual(kernel.process.thread.State.faulted, faulted.state);
    try std.testing.expectEqualDeep(
        @as(?kernel.process.thread.UserFault, fault),
        faulted.user_fault,
    );
    try std.testing.expectError(
        error.InvalidStateTransition,
        kernel.process.thread.startRunning(handle),
    );
}

test "Thread: live references prevent address-space destruction" {
    testSetup();
    const owner: kernel.process.ProcessHandle = 42;
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
    });

    try std.testing.expectError(
        error.AddressSpaceInUse,
        kernel.process.destroyAddressSpace(address_space),
    );
    try kernel.process.thread.destroy(handle);
    try std.testing.expectEqual(
        arch.impl.thread_context.MAX_CONTEXTS,
        arch.thread_context.availableCount(),
    );
    try kernel.process.destroyAddressSpace(address_space);
}

test "Thread: context handles become stale and storage is reused on destruction" {
    testSetup();
    const owner: kernel.process.ProcessHandle = 42;
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
    });
    const stale_context = (try kernel.process.thread.get(handle)).architecture_context_handle;
    try kernel.process.thread.destroy(handle);
    try std.testing.expectError(
        error.InvalidThreadContextHandle,
        arch.thread_context.getForTest(stale_context),
    );

    const replacement = try kernel.process.createThread(owner);
    try kernel.process.configureThread(replacement, .{
        .capability_space_handle = owner,
        .address_space_handle = address_space,
        .entry_point = 0x0040_1000,
        .stack_pointer = 0x0080_1000,
    });
    try std.testing.expect(
        (try kernel.process.thread.get(replacement)).architecture_context_handle != stale_context,
    );
}

test "Thread: storage exhaustion is explicit and destroyed handles become stale" {
    testSetup();
    var handles: [kernel.process.thread.MAX_THREADS]kernel.process.thread.Handle = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try kernel.process.createThread(@intCast(index + 1));
    }
    try std.testing.expectError(error.OutOfThreads, kernel.process.createThread(99));

    const stale = handles[0];
    try kernel.process.thread.destroy(stale);
    const replacement = try kernel.process.createThread(99);
    try std.testing.expect(replacement != stale);
    try std.testing.expectError(error.InvalidThreadHandle, kernel.process.thread.get(stale));
    try std.testing.expectEqual(
        @as(kernel.process.ProcessHandle, 99),
        (try kernel.process.thread.get(replacement)).owner_process_handle,
    );
}

test "Thread: runnable and running objects cannot be destroyed" {
    testSetup();
    const handle = try configureRunnableThread(42);
    try kernel.process.thread.makeReady(handle);
    try std.testing.expectError(error.ThreadInUse, kernel.process.thread.destroy(handle));
    try kernel.process.thread.startRunning(handle);
    try std.testing.expectError(error.ThreadInUse, kernel.process.thread.destroy(handle));
}
