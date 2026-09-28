const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

const assertions = @import("../support/syscall/assertions.zig");
const production_fixtures = @import("../support/syscall/production_fixtures.zig");

const createProductionFrameCapability = production_fixtures.createProductionFrameCapability;
const expectFailure = assertions.expectFailure;
const expectReturned = assertions.expectReturned;
const initializeContext = production_fixtures.initializeContext;
const request = assertions.request;
const resetProductionState = production_fixtures.resetProductionState;

test "Syscall: production dispatch creates and maps capability-backed objects" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    resetProductionState();
    try initializeContext(kernel.process.ROOT_PROCESS_HANDLE);

    const address_space_result = kernel.syscall.dispatchFromCurrentContext(
        request(.create_address_space, .{ 0, 0, 0, 0, 0 }),
    );
    const address_space_capability = switch (address_space_result) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory, .{ address_space_capability, 0x0200_0000, 0x2000, 0, 0 }),
        ),
    );

    const frame_capability = try createProductionFrameCapability(0x3000);
    const memory_object_result = kernel.syscall.dispatchFromCurrentContext(
        request(.create_memory_object, .{ frame_capability, 0, 0, 0, 0 }),
    );
    const memory_object_capability = switch (memory_object_result) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory_object, .{
                address_space_capability,
                memory_object_capability,
                0x0300_0000,
                0x1000,
                abi.syscall.MAP_READ | abi.syscall.MAP_WRITE,
            }),
        ),
    );

    const address_space_handle = try kernel.capability.resolveAddressSpace(
        kernel.process.ROOT_PROCESS_HANDLE,
        address_space_capability,
        .{ .manage = true },
    );
    const address_space = try kernel.process.getAddressSpace(address_space_handle);
    try std.testing.expectEqual(@as(usize, 2), address_space.length);
    try std.testing.expectEqual(@as(u64, 0x0300_0000), address_space.virtual_memory_areas[1].start_address);
    try std.testing.expectEqual(@as(u64, 0x0300_1000), address_space.virtual_memory_areas[1].end_address);
    try std.testing.expectEqual(@as(u64, 0), address_space.virtual_memory_areas[1].memory_object_offset);
}

test "Syscall: production capability and invocation failures return stable statuses" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    resetProductionState();
    try initializeContext(kernel.process.ROOT_PROCESS_HANDLE);

    try expectFailure(
        .resolve_address_space,
        error.InvalidCapability,
        abi.syscall.errorResult(.invalid_capability),
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory, .{ abi.capability.INVALID_CAPABILITY, 0x1000, 0x1000, 0, 0 }),
        ),
    );

    const address_space_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_address_space, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    const frame_capability = try createProductionFrameCapability(0x1000);
    const memory_object_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_memory_object, .{ frame_capability, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };

    const foreign_space = try kernel.process.capability_spaces.create();
    try kernel.process.execution_context.replace(.{
        .thread_handle = 2,
        .capability_space_handle = foreign_space,
        .address_space_handle = 2,
        .process_handle = 2,
    });

    try expectFailure(
        .resolve_address_space,
        error.InvalidCapability,
        abi.syscall.errorResult(.invalid_capability),
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory, .{ address_space_capability, 0x1000, 0x1000, 0, 0 }),
        ),
    );

    try kernel.process.execution_context.replace(.{
        .thread_handle = kernel.process.execution_context.ROOT_THREAD_HANDLE,
        .capability_space_handle = kernel.process.execution_context.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = 1,
        .process_handle = kernel.process.ROOT_PROCESS_HANDLE,
    });

    try expectFailure(
        .resolve_address_space,
        error.InvalidCapabilityType,
        abi.syscall.errorResult(.invalid_capability),
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory, .{ memory_object_capability, 0x1000, 0x1000, 0, 0 }),
        ),
    );
    try expectFailure(
        .map_memory_object,
        error.InvalidMemoryPermissions,
        abi.syscall.errorResult(.invalid_permissions),
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory_object, .{
                address_space_capability,
                memory_object_capability,
                0x0400_0000,
                0x1000,
                0,
            }),
        ),
    );
}

test "Syscall: production lifecycle supports current query protect unmap and destroy" {
    resetProductionState();
    const root_capability = try kernel.capability.createAddressSpaceCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
    );
    const root_address_space = try kernel.capability.resolveAddressSpace(
        kernel.process.ROOT_PROCESS_HANDLE,
        root_capability,
        .{ .manage = true },
    );
    try kernel.process.execution_context.initializeRoot(root_address_space);

    try expectReturned(
        root_capability,
        kernel.syscall.dispatchFromCurrentContext(
            request(.current_address_space, .{ 0, 0, 0, 0, 0 }),
        ),
    );
    try expectFailure(
        .destroy_address_space,
        error.AddressSpaceInUse,
        abi.syscall.errorResult(.address_space_in_use),
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_address_space, .{ root_capability, 0, 0, 0, 0 }),
        ),
    );

    const child_capability = switch (kernel.syscall.dispatchFromCurrentContext(
        request(.create_address_space, .{ 0, 0, 0, 0, 0 }),
    )) {
        .returned => |handle| handle,
        else => return error.UnexpectedSyscallResult,
    };
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.map_memory, .{ child_capability, 0x0800_0000, 0x1000, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.protect_address_space, .{
                child_capability,
                0x0800_0000,
                0x1000,
                abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE,
                0,
            }),
        ),
    );
    try expectReturned(
        abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE,
        kernel.syscall.dispatchFromCurrentContext(
            request(.query_address_space, .{ child_capability, 0x0800_0000, 0x1000, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.unmap_address_space, .{ child_capability, 0x0800_0000, 0x1000, 0, 0 }),
        ),
    );
    try expectFailure(
        .unmap_address_space,
        error.UndefinedVirtualMemoryArea,
        abi.syscall.errorResult(.mapping_not_found),
        kernel.syscall.dispatchFromCurrentContext(
            request(.unmap_address_space, .{ child_capability, 0x0800_0000, 0x1000, 0, 0 }),
        ),
    );
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.destroy_address_space, .{ child_capability, 0, 0, 0, 0 }),
        ),
    );
    try expectFailure(
        .resolve_address_space,
        error.InvalidCapability,
        abi.syscall.errorResult(.invalid_capability),
        kernel.syscall.dispatchFromCurrentContext(
            request(.query_address_space, .{ child_capability, 0x0800_0000, 0x1000, 0, 0 }),
        ),
    );
}
