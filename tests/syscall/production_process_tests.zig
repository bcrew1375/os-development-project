const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

const assertions = @import("../support/syscall/assertions.zig");
const production_fixtures = @import("../support/syscall/production_fixtures.zig");

const expectFailure = assertions.expectFailure;
const expectReturned = assertions.expectReturned;
const initializeContext = production_fixtures.initializeContext;
const request = assertions.request;
const resetProductionState = production_fixtures.resetProductionState;

test "Syscall: production thread and capability-space lifecycle uses checked user configuration" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetProductionState();

    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const root_address_capability = try kernel.capability.createAddressSpaceCapability(root_space);
    const root_address_space = try kernel.capability.resolveAddressSpace(
        root_space,
        root_address_capability,
        .{ .manage = true },
    );
    const root = try kernel.process.getAddressSpaceRoot(root_address_space);
    try kernel.process.execution_context.initializeRoot(root_address_space);
    try arch.mmu.mapTableInAddressSpace(root, 0x0040_0000, 0, .{ .user = true, .write = true });
    try arch.mmu.mapPageInAddressSpace(root, 0x0040_0000, 0x1000, .{ .user = true, .write = true });
    arch.mmu.switchAddressSpaceRoot(root);

    const space_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_capability_space, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    const thread_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_thread, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    const lifecycle_endpoint = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_endpoint, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    const configuration = abi.process.ThreadConfiguration{
        .capability_space = space_capability,
        .address_space = root_address_capability,
        .entry_point = 0x0050_0000,
        .stack_pointer = 0x0080_0000,
        .argument = 0x1234,
        .lifecycle_endpoint = lifecycle_endpoint,
        .lifecycle_token = 77,
    };
    try arch.mmu.writePhysicalMemoryForTest(0x1000, std.mem.asBytes(&configuration));
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.configure_thread, .{ thread_capability, 0x0040_0000, 0, 0, 0 }),
        ),
    );

    const thread_handle = try kernel.capability.resolveThread(
        root_space,
        thread_capability,
        .{ .configure = true },
    );
    const configured = try kernel.process.thread.get(thread_handle);
    try std.testing.expect(configured.isConfigured());
    try std.testing.expectEqual(@as(u64, 0x1234), configured.argument);
    try std.testing.expectEqual(@as(u32, 77), configured.lifecycle_token);
    try expectFailure(
        .destroy_endpoint,
        error.EndpointInUse,
        abi.syscall.errorResult(.object_in_use),
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_endpoint, .{ lifecycle_endpoint, 0, 0, 0, 0 }),
        ),
    );
    try kernel.process.scheduler.initialize(root);

    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.start_thread, .{ thread_capability, 0, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.suspend_thread, .{ thread_capability, 0, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.resume_thread, .{ thread_capability, 0, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.terminate_thread, .{ thread_capability, 41, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(?u64, 41), (try kernel.process.thread.get(thread_handle)).exit_status);
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_thread, .{ thread_capability, 0, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_endpoint, .{ lifecycle_endpoint, 0, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_capability_space, .{ space_capability, 0, 0, 0, 0 }),
        ),
    );
}

test "Syscall: thread configuration rejects unmapped user pointers without mutation" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetProductionState();
    try initializeContext(kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE);
    const thread_capability = try kernel.capability.createThreadCapability(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
    );

    try expectFailure(
        .configure_thread,
        error.UserPageNotMapped,
        abi.syscall.errorResult(.invalid_user_memory),
        kernel.syscall.dispatchFromCurrentContext(
            request(.configure_thread, .{ thread_capability, 0x0040_0000, 0, 0, 0 }),
        ),
    );
    const handle = try kernel.capability.resolveThread(
        kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        thread_capability,
        .{ .configure = true },
    );
    try std.testing.expect(!(try kernel.process.thread.get(handle)).isConfigured());
}

test "Syscall: delegated capabilities can be removed through target-space authority" {
    resetProductionState();
    try initializeContext(kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE);
    const target_space_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_capability_space, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    const thread_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_thread, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    const installed = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.install_capability, .{
            target_space_capability,
            thread_capability,
            abi.capability.rightsBits(.{ .terminate = true }),
            0,
            0,
        }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.delete_capability, .{ target_space_capability, installed, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_thread, .{ thread_capability, 0, 0, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_capability_space, .{ target_space_capability, 0, 0, 0, 0 }),
        ),
    );
}
