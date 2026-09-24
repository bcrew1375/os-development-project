const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

fn request(number: abi.syscall.SyscallNumber, arguments: [5]u64) kernel.syscall.Request {
    return .{
        .number = @intFromEnum(number),
        .arguments = arguments,
    };
}

fn expectReturned(expected: u32, result: kernel.syscall.Result) !void {
    switch (result) {
        .returned => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedSyscallResult,
    }
}

fn expectFailure(
    expected_operation: kernel.syscall.Operation,
    expected_error: anyerror,
    expected_return_value: u32,
    result: kernel.syscall.Result,
) !void {
    switch (result) {
        .failure => |actual| {
            try std.testing.expectEqual(expected_operation, actual.operation);
            try std.testing.expectEqual(expected_error, actual.err);
            try std.testing.expectEqual(expected_return_value, actual.return_value);
        },
        else => return error.UnexpectedSyscallResult,
    }
}

fn resetProductionState() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
    kernel.memory_management.physical_memory_authority.resetForTest();
}

fn createProductionFrameCapability(size_in_bytes: u64) !abi.capability.CapabilityHandle {
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        size_in_bytes,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    return kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0,
        @intCast(size_in_bytes / 0x1000),
        .physical_frame,
        .{ .manage = true, .read = true, .write = true },
    );
}

fn initializeContext(process_handle: kernel.process.ProcessHandle) !void {
    try kernel.process.execution_context.initialize(.{
        .thread_handle = process_handle,
        .capability_space_handle = process_handle,
        .address_space_handle = process_handle,
        .process_handle = process_handle,
    });
}

test "Syscall: side-effect requests preserve native-width arguments" {
    const debug_result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        request(.debug_write, .{ 0x1234_5678_9abc_def0, 0x1020_3040_5060_7080, 0, 0, 0 }),
    );
    switch (debug_result) {
        .debug_write => |write| {
            try std.testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), write.address);
            try std.testing.expectEqual(@as(u64, 0x1020_3040_5060_7080), write.length);
        },
        else => return error.UnexpectedSyscallResult,
    }

    const exit_result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        request(.exit, .{ 0xfedc_ba98_7654_3210, 0, 0, 0, 0 }),
    );
    switch (exit_result) {
        .exit => |exit| try std.testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), exit.status),
        else => return error.UnexpectedSyscallResult,
    }
}

test "Syscall: unknown numbers return a typed unsupported result" {
    const result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        .{ .number = 0xffff_fffe },
    );
    switch (result) {
        .unsupported => |unsupported| try std.testing.expectEqual(@as(u32, 0xffff_fffe), unsupported.number),
        else => return error.UnexpectedSyscallResult,
    }
}

test "Syscall: injected services receive caller and all mapping arguments" {
    RecordingServices.reset();
    try expectReturned(
        77,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.create_address_space, .{ 0, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 42), RecordingServices.state.caller_process_handle);

    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.map_memory, .{ 17, 0x1234_5000, 0x6000, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 17), RecordingServices.state.address_space_capability);
    try std.testing.expect(RecordingServices.state.address_space_rights.manage);
    try std.testing.expectEqual(@as(u64, 0x1234_5000), RecordingServices.state.virtual_start);
    try std.testing.expectEqual(@as(u64, 0x6000), RecordingServices.state.size_in_bytes);

    try expectReturned(
        88,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.create_memory_object, .{ 0x9000, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(u64, 0x9000), RecordingServices.state.object_size_in_bytes);

    const permission_flags = abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE;
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.map_memory_object, .{ 17, 19, 0x4321_0000, 0xa000, permission_flags }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 19), RecordingServices.state.memory_object_capability);
    try std.testing.expect(RecordingServices.state.memory_object_rights.read);
    try std.testing.expect(!RecordingServices.state.memory_object_rights.write);
    try std.testing.expect(RecordingServices.state.memory_object_rights.execute);
    try std.testing.expectEqual(@as(u64, 0x4321_0000), RecordingServices.state.virtual_start);
    try std.testing.expectEqual(@as(u64, 0), RecordingServices.state.object_offset);
    try std.testing.expectEqual(@as(u64, 0xa000), RecordingServices.state.size_in_bytes);
    try std.testing.expectEqual(permission_flags, RecordingServices.state.permission_flags);
}

test "Syscall: address-space lifecycle handlers enforce rights and preserve arguments" {
    RecordingServices.reset();
    try expectReturned(
        77,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.current_address_space, .{ 0, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), RecordingServices.state.call_count);
    try std.testing.expectEqual(@as(u32, 42), RecordingServices.state.caller_process_handle);
    try std.testing.expectEqual(@as(u32, 107), RecordingServices.state.address_space_capability);

    RecordingServices.reset();
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.protect_address_space, .{
                17,
                0x2000,
                0x3000,
                abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE,
                0,
            }),
        ),
    );
    try std.testing.expect(RecordingServices.state.address_space_rights.manage);
    try std.testing.expect(!RecordingServices.state.address_space_rights.read);
    try std.testing.expectEqual(@as(u64, 0x2000), RecordingServices.state.virtual_start);
    try std.testing.expectEqual(@as(u64, 0x3000), RecordingServices.state.size_in_bytes);
    try std.testing.expectEqual(
        abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE,
        RecordingServices.state.permission_flags,
    );

    RecordingServices.reset();
    try expectReturned(
        abi.syscall.MAP_READ | abi.syscall.MAP_WRITE,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.query_address_space, .{ 17, 0x5000, 0x1000, 0, 0 }),
        ),
    );
    try std.testing.expect(RecordingServices.state.address_space_rights.read);
    try std.testing.expect(!RecordingServices.state.address_space_rights.manage);
    try std.testing.expectEqual(@as(u64, 0x5000), RecordingServices.state.virtual_start);
    try std.testing.expectEqual(@as(u64, 0x1000), RecordingServices.state.size_in_bytes);

    RecordingServices.reset();
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.unmap_address_space, .{ 17, 0x6000, 0x2000, 0, 0 }),
        ),
    );
    try std.testing.expect(RecordingServices.state.address_space_rights.manage);
    try std.testing.expectEqual(@as(u64, 0x6000), RecordingServices.state.virtual_start);
    try std.testing.expectEqual(@as(u64, 0x2000), RecordingServices.state.size_in_bytes);

    RecordingServices.reset();
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.destroy_address_space, .{ 17, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 42), RecordingServices.state.caller_process_handle);
    try std.testing.expectEqual(@as(u32, 17), RecordingServices.state.address_space_capability);
}

test "Syscall: physical-memory lifecycle requests decode and forward all arguments" {
    RecordingServices.reset();
    const offset: u64 = 0x1234_5678_9abc_d000;
    const rights = abi.capability.Rights{ .read = true, .manage = true };
    try expectReturned(
        99,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.retype_untyped_memory, .{
                17,
                abi.syscall.lowU32(offset),
                abi.syscall.highU32(offset),
                3,
                abi.syscall.packRetypeTarget(.physical_frame, rights),
            }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 42), RecordingServices.state.caller_process_handle);
    try std.testing.expectEqual(@as(u32, 17), RecordingServices.state.physical_memory_capability);
    try std.testing.expectEqual(offset, RecordingServices.state.physical_offset);
    try std.testing.expectEqual(@as(u32, 3), RecordingServices.state.page_count);
    try std.testing.expectEqual(abi.capability.ObjectType.physical_frame, RecordingServices.state.target_type);
    try std.testing.expectEqual(rights, RecordingServices.state.physical_memory_rights);

    RecordingServices.reset();
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.delete_physical_memory, .{ 23, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 23), RecordingServices.state.physical_memory_capability);

    RecordingServices.reset();
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.revoke_physical_memory, .{ 29, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(u32, 29), RecordingServices.state.physical_memory_capability);
}

test "Syscall: injected failures map deterministically to ABI values" {
    const cases = [_]struct {
        operation: kernel.syscall.Operation,
        err: anyerror,
        expected_return_value: u32,
        syscall_number: abi.syscall.SyscallNumber,
    }{
        .{ .operation = .create_address_space, .err = error.OutOfAddressSpaces, .expected_return_value = abi.syscall.errorResult(.out_of_resources), .syscall_number = .create_address_space },
        .{ .operation = .resolve_address_space, .err = error.InvalidCapability, .expected_return_value = abi.syscall.errorResult(.invalid_capability), .syscall_number = .map_memory },
        .{ .operation = .map_memory, .err = error.MemoryRangeOverflow, .expected_return_value = abi.syscall.errorResult(.invalid_range), .syscall_number = .map_memory },
        .{ .operation = .create_memory_object, .err = error.OutOfMemoryObjects, .expected_return_value = abi.syscall.errorResult(.out_of_resources), .syscall_number = .create_memory_object },
        .{ .operation = .resolve_memory_object, .err = error.InsufficientCapabilityRights, .expected_return_value = abi.syscall.errorResult(.insufficient_rights), .syscall_number = .map_memory_object },
        .{ .operation = .map_memory_object, .err = error.ObjectRangeOutOfBounds, .expected_return_value = abi.syscall.errorResult(.invalid_range), .syscall_number = .map_memory_object },
        .{ .operation = .protect_address_space, .err = error.InvalidMemoryPermissions, .expected_return_value = abi.syscall.errorResult(.invalid_permissions), .syscall_number = .protect_address_space },
        .{ .operation = .query_address_space, .err = error.UndefinedVirtualMemoryArea, .expected_return_value = abi.syscall.errorResult(.mapping_not_found), .syscall_number = .query_address_space },
        .{ .operation = .unmap_address_space, .err = error.UndefinedVirtualMemoryArea, .expected_return_value = abi.syscall.errorResult(.mapping_not_found), .syscall_number = .unmap_address_space },
        .{ .operation = .destroy_address_space, .err = error.AddressSpaceInUse, .expected_return_value = abi.syscall.errorResult(.address_space_in_use), .syscall_number = .destroy_address_space },
        .{ .operation = .retype_untyped_memory, .err = error.OverlappingAuthority, .expected_return_value = abi.syscall.errorResult(.invalid_range), .syscall_number = .retype_untyped_memory },
        .{ .operation = .delete_physical_memory, .err = error.CapabilityHasDescendants, .expected_return_value = abi.syscall.errorResult(.invalid_range), .syscall_number = .delete_physical_memory },
        .{ .operation = .revoke_physical_memory, .err = error.InvalidCapability, .expected_return_value = abi.syscall.errorResult(.invalid_capability), .syscall_number = .revoke_physical_memory },
    };

    for (cases) |case| {
        FailingServices.failure_operation = case.operation;
        const arguments: [5]u64 = switch (case.syscall_number) {
            .map_memory => .{ 1, 0x1000, 0x1000, 0, 0 },
            .create_memory_object => .{ 0x1000, 0, 0, 0, 0 },
            .map_memory_object => .{ 1, 2, 0x2000, 0x1000, abi.syscall.MAP_READ },
            .protect_address_space => .{ 1, 0x2000, 0x1000, abi.syscall.MAP_READ, 0 },
            .query_address_space, .unmap_address_space => .{ 1, 0x2000, 0x1000, 0, 0 },
            .destroy_address_space => .{ 1, 0, 0, 0, 0 },
            .retype_untyped_memory => .{
                1,
                0,
                0,
                1,
                abi.syscall.packRetypeTarget(.physical_frame, .{ .manage = true }),
            },
            .delete_physical_memory, .revoke_physical_memory => .{ 1, 0, 0, 0, 0 },
            else => .{ 0, 0, 0, 0, 0 },
        };
        try expectFailure(
            case.operation,
            case.err,
            case.expected_return_value,
            kernel.syscall.dispatchWithServices(
                FailingServices,
                kernel.process.ROOT_PROCESS_HANDLE,
                request(case.syscall_number, arguments),
            ),
        );
    }
}

test "Syscall: oversized handles and flags fail before service invocation" {
    RecordingServices.reset();
    try expectFailure(
        .convert_argument,
        error.ArgumentOutOfRange,
        abi.syscall.errorResult(.invalid_range),
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.map_memory, .{ @as(u64, std.math.maxInt(u32)) + 1, 0, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), RecordingServices.state.call_count);

    try expectFailure(
        .convert_argument,
        error.ArgumentOutOfRange,
        abi.syscall.errorResult(.invalid_range),
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.map_memory_object, .{ 1, 2, 0, 0, @as(u64, std.math.maxInt(u32)) + 1 }),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), RecordingServices.state.call_count);

    try expectFailure(
        .retype_untyped_memory,
        error.InvalidCapabilityRights,
        abi.syscall.errorResult(.insufficient_rights),
        kernel.syscall.dispatchWithServices(
            RecordingServices,
            42,
            request(.retype_untyped_memory, .{ 1, 0, 0, 1, 0xffff_ff00 }),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), RecordingServices.state.call_count);
}

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

    try kernel.process.execution_context.replace(.{
        .thread_handle = 2,
        .capability_space_handle = 2,
        .address_space_handle = 2,
        .process_handle = 2,
    });

    try expectFailure(
        .resolve_address_space,
        error.CapabilityOwnerMismatch,
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

const RecordingServices = struct {
    const State = struct {
        call_count: usize = 0,
        caller_process_handle: u32 = 0,
        address_space_capability: u32 = 0,
        memory_object_capability: u32 = 0,
        address_space_rights: abi.capability.Rights = .{},
        memory_object_rights: abi.capability.Rights = .{},
        object_size_in_bytes: u64 = 0,
        virtual_start: u64 = 0,
        object_offset: u64 = 0,
        size_in_bytes: u64 = 0,
        permission_flags: u32 = 0,
        physical_memory_capability: u32 = 0,
        physical_offset: u64 = 0,
        page_count: u32 = 0,
        target_type: abi.capability.ObjectType = .null,
        physical_memory_rights: abi.capability.Rights = .{},
    };

    var state: State = .{};

    fn reset() void {
        state = .{};
    }

    pub fn currentAddressSpaceHandle() !u32 {
        state.call_count += 1;
        return 107;
    }

    pub fn findAddressSpaceCapability(caller_process_handle: u32, address_space_handle: u32) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.address_space_capability = address_space_handle;
        return 77;
    }

    pub fn createAddressSpaceCapability(caller_process_handle: u32) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        return 77;
    }

    pub fn resolveAddressSpace(caller_process_handle: u32, handle: u32, rights: abi.capability.Rights) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.address_space_capability = handle;
        state.address_space_rights = rights;
        return 107;
    }

    pub fn mapMemory(_: u32, virtual_start: u64, size_in_bytes: u64) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
    }

    pub fn createMemoryObjectCapability(caller_process_handle: u32, size_in_bytes: u64) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.object_size_in_bytes = size_in_bytes;
        return 88;
    }

    pub fn resolveMemoryObject(caller_process_handle: u32, handle: u32, rights: abi.capability.Rights) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.memory_object_capability = handle;
        state.memory_object_rights = rights;
        return 109;
    }

    pub fn mapMemoryObject(
        _: u32,
        _: u32,
        virtual_start: u64,
        object_offset: u64,
        size_in_bytes: u64,
        permission_flags: u32,
    ) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.object_offset = object_offset;
        state.size_in_bytes = size_in_bytes;
        state.permission_flags = permission_flags;
    }

    pub fn protectAddressSpace(_: u32, virtual_start: u64, size_in_bytes: u64, permission_flags: u32) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
        state.permission_flags = permission_flags;
    }

    pub fn queryAddressSpace(_: u32, virtual_start: u64, size_in_bytes: u64) !u32 {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
        return abi.syscall.MAP_READ | abi.syscall.MAP_WRITE;
    }

    pub fn unmapAddressSpace(_: u32, virtual_start: u64, size_in_bytes: u64) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
    }

    pub fn destroyAddressSpaceCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.address_space_capability = handle;
    }

    pub fn destroyMemoryObjectCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.memory_object_capability = handle;
    }

    pub fn retypeUntypedMemoryCapability(
        caller_process_handle: u32,
        source_capability: u32,
        offset: u64,
        page_count: u32,
        target_type: abi.capability.ObjectType,
        rights: abi.capability.Rights,
    ) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.physical_memory_capability = source_capability;
        state.physical_offset = offset;
        state.page_count = page_count;
        state.target_type = target_type;
        state.physical_memory_rights = rights;
        return 99;
    }

    pub fn deletePhysicalMemoryCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.physical_memory_capability = handle;
    }

    pub fn revokePhysicalMemoryCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.physical_memory_capability = handle;
    }
};

const FailingServices = struct {
    var failure_operation: kernel.syscall.Operation = .create_address_space;

    pub fn currentAddressSpaceHandle() !u32 {
        if (failure_operation == .current_address_space) return error.ExecutionContextUninitialized;
        return 1;
    }

    pub fn findAddressSpaceCapability(_: u32, _: u32) !u32 {
        if (failure_operation == .current_address_space) return error.InvalidCapability;
        return 1;
    }

    pub fn createAddressSpaceCapability(_: u32) !u32 {
        if (failure_operation == .create_address_space) return error.OutOfAddressSpaces;
        return 1;
    }

    pub fn resolveAddressSpace(_: u32, _: u32, _: abi.capability.Rights) !u32 {
        if (failure_operation == .resolve_address_space) return error.InvalidCapability;
        return 1;
    }

    pub fn mapMemory(_: u32, _: u64, _: u64) !void {
        if (failure_operation == .map_memory) return error.MemoryRangeOverflow;
    }

    pub fn createMemoryObjectCapability(_: u32, _: u64) !u32 {
        if (failure_operation == .create_memory_object) return error.OutOfMemoryObjects;
        return 2;
    }

    pub fn resolveMemoryObject(_: u32, _: u32, _: abi.capability.Rights) !u32 {
        if (failure_operation == .resolve_memory_object) return error.InsufficientCapabilityRights;
        return 2;
    }

    pub fn mapMemoryObject(_: u32, _: u32, _: u64, _: u64, _: u64, _: u32) !void {
        if (failure_operation == .map_memory_object) return error.ObjectRangeOutOfBounds;
    }

    pub fn protectAddressSpace(_: u32, _: u64, _: u64, _: u32) !void {
        if (failure_operation == .protect_address_space) return error.InvalidMemoryPermissions;
    }

    pub fn queryAddressSpace(_: u32, _: u64, _: u64) !u32 {
        if (failure_operation == .query_address_space) return error.UndefinedVirtualMemoryArea;
        return abi.syscall.MAP_READ;
    }

    pub fn unmapAddressSpace(_: u32, _: u64, _: u64) !void {
        if (failure_operation == .unmap_address_space) return error.UndefinedVirtualMemoryArea;
    }

    pub fn destroyAddressSpaceCapability(_: u32, _: u32) !void {
        if (failure_operation == .destroy_address_space) return error.AddressSpaceInUse;
    }

    pub fn destroyMemoryObjectCapability(_: u32, _: u32) !void {
        if (failure_operation == .destroy_memory_object) return error.MemoryObjectInUse;
    }

    pub fn retypeUntypedMemoryCapability(
        _: u32,
        _: u32,
        _: u64,
        _: u32,
        _: abi.capability.ObjectType,
        _: abi.capability.Rights,
    ) !u32 {
        if (failure_operation == .retype_untyped_memory) return error.OverlappingAuthority;
        return 3;
    }

    pub fn deletePhysicalMemoryCapability(_: u32, _: u32) !void {
        if (failure_operation == .delete_physical_memory) return error.CapabilityHasDescendants;
    }

    pub fn revokePhysicalMemoryCapability(_: u32, _: u32) !void {
        if (failure_operation == .revoke_physical_memory) return error.InvalidCapability;
    }
};
