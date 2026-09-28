const abi = @import("abi");
const memory_management = @import("memory_management");
const std = @import("std");

const RecordingEnvironment = @import("support/recording_environment.zig").RecordingEnvironment;
const memory_manager = memory_management.operations;
const manager = memory_manager.MemoryManager(RecordingEnvironment);

test "memory manager emits address-space and region syscalls" {
    RecordingEnvironment.reset(&.{ 42, abi.syscall.SYSCALL_SUCCESS });
    const address_space = try manager.createAddressSpace();
    try std.testing.expectEqual(@as(u32, 42), address_space.capability);
    try manager.mapRegion(address_space, 0x2000, 0x3000);

    const create_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.create_address_space), create_call.number);
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, create_call.arguments);
    const map_call = RecordingEnvironment.syscalls[1].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.map_memory), map_call.number);
    try std.testing.expectEqual([_]usize{ 42, 0x2000, 0x3000 }, map_call.arguments);

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectError(error.InternalFailure, manager.createAddressSpace());

    RecordingEnvironment.reset(&.{abi.syscall.errorResult(.invalid_range)});
    try std.testing.expectError(error.InvalidRange, manager.mapRegion(address_space, 0x2000, 0x3000));
}

test "memory manager emits memory-object mapping syscall and flags" {
    RecordingEnvironment.reset(&.{ 71, abi.syscall.SYSCALL_SUCCESS });
    const memory_object = try manager.createMemoryObject(.{ .capability = 0x5000 });
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const permissions = memory_manager.MAP_READ | memory_manager.MAP_WRITE | memory_manager.MAP_EXECUTE;
    try manager.mapMemoryObject(address_space, memory_object, 0x8000, 0x5000, permissions);

    const create_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.create_memory_object), create_call.number);
    try std.testing.expectEqual([_]usize{ 0x5000, 0, 0 }, create_call.arguments);
    const map_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.map_memory_object), map_call.number);
    try std.testing.expectEqual([_]usize{ 19, 71, 0x8000, 0x5000, permissions }, map_call.arguments);

    RecordingEnvironment.reset(&.{ 71, abi.syscall.errorResult(.invalid_permissions) });
    const failed_object = try manager.createMemoryObject(.{ .capability = 0x1000 });
    try std.testing.expectError(
        error.InvalidPermissions,
        manager.mapMemoryObject(address_space, failed_object, 0, 0x1000, 0),
    );

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectError(
        error.InternalFailure,
        manager.createMemoryObject(.{ .capability = 0x1000 }),
    );
}

test "memory manager forwards every permission flag combination" {
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const memory_object = memory_manager.MemoryObject{ .capability = 71 };

    for (0..8) |permission_flags| {
        RecordingEnvironment.reset(&.{abi.syscall.SYSCALL_SUCCESS});
        try manager.mapMemoryObject(
            address_space,
            memory_object,
            0x8000,
            0x1000,
            @intCast(permission_flags),
        );
        try std.testing.expectEqual(
            permission_flags,
            RecordingEnvironment.syscalls[0].five.arguments[4],
        );
    }
}

test "memory manager emits typed physical-memory lifecycle syscalls" {
    RecordingEnvironment.reset(&.{ 81, 82, abi.syscall.SYSCALL_SUCCESS, abi.syscall.SYSCALL_SUCCESS });
    const source = memory_manager.UntypedMemory{ .capability = 17 };
    const offset: u64 = 0x1234_5678_9abc_d000;
    const child_rights = abi.capability.Rights{ .read = true, .manage = true };
    const frame_rights = abi.capability.Rights{ .read = true, .write = true };

    const child = try manager.retypeUntypedMemory(source, offset, 3, child_rights);
    try std.testing.expectEqual(@as(u32, 81), child.capability);
    const frame = try manager.retypePhysicalFrames(child, 0x2000, 2, frame_rights);
    try std.testing.expectEqual(@as(u32, 82), frame.capability);
    try manager.deletePhysicalMemory(frame);
    try manager.revokePhysicalMemory(child);

    const child_call = RecordingEnvironment.syscalls[0].five;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.retype_untyped_memory),
        child_call.number,
    );
    try std.testing.expectEqual([_]usize{
        17,
        abi.syscall.lowU32(offset),
        abi.syscall.highU32(offset),
        3,
        abi.syscall.packRetypeTarget(.untyped_memory, child_rights),
    }, child_call.arguments);

    const frame_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual([_]usize{
        81,
        0x2000,
        0,
        2,
        abi.syscall.packRetypeTarget(.physical_frame, frame_rights),
    }, frame_call.arguments);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.delete_physical_memory),
        RecordingEnvironment.syscalls[2].three.number,
    );
    try std.testing.expectEqual(
        [_]usize{ 82, 0, 0 },
        RecordingEnvironment.syscalls[2].three.arguments,
    );
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.revoke_physical_memory),
        RecordingEnvironment.syscalls[3].three.number,
    );
    try std.testing.expectEqual(
        [_]usize{ 81, 0, 0 },
        RecordingEnvironment.syscalls[3].three.arguments,
    );
}

test "memory manager emits complete address-space lifecycle syscalls" {
    const permissions = memory_manager.MAP_READ | memory_manager.MAP_EXECUTE;
    RecordingEnvironment.reset(&.{ 31, abi.syscall.SYSCALL_SUCCESS, permissions, abi.syscall.SYSCALL_SUCCESS, abi.syscall.SYSCALL_SUCCESS });

    const address_space = try manager.currentAddressSpace();
    try std.testing.expectEqual(@as(u32, 31), address_space.capability);
    try manager.protectAddressSpace(address_space, 0x4000, 0x2000, permissions);
    try std.testing.expectEqual(
        permissions,
        try manager.queryAddressSpace(address_space, 0x4000, 0x2000),
    );
    try manager.unmapAddressSpace(address_space, 0x4000, 0x2000);
    try manager.destroyAddressSpace(address_space);

    const current_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.current_address_space),
        current_call.number,
    );
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, current_call.arguments);

    const protect_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.protect_address_space),
        protect_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0x4000, 0x2000, permissions, 0 }, protect_call.arguments);

    const query_call = RecordingEnvironment.syscalls[2].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.query_address_space),
        query_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0x4000, 0x2000 }, query_call.arguments);

    const unmap_call = RecordingEnvironment.syscalls[3].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.unmap_address_space),
        unmap_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0x4000, 0x2000 }, unmap_call.arguments);

    const destroy_call = RecordingEnvironment.syscalls[4].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_address_space),
        destroy_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0, 0 }, destroy_call.arguments);
}

test "memory manager translates every structured ABI error" {
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const cases = [_]struct {
        code: abi.syscall.ErrorCode,
        expected: anyerror,
    }{
        .{ .code = .invalid_capability, .expected = error.InvalidCapability },
        .{ .code = .insufficient_rights, .expected = error.InsufficientRights },
        .{ .code = .out_of_resources, .expected = error.OutOfResources },
        .{ .code = .invalid_range, .expected = error.InvalidRange },
        .{ .code = .invalid_permissions, .expected = error.InvalidPermissions },
        .{ .code = .mapping_not_found, .expected = error.MappingNotFound },
        .{ .code = .address_space_in_use, .expected = error.AddressSpaceInUse },
        .{ .code = .unsupported, .expected = error.Unsupported },
        .{ .code = .internal_failure, .expected = error.InternalFailure },
    };

    for (cases) |case| {
        RecordingEnvironment.reset(&.{abi.syscall.errorResult(case.code)});
        try std.testing.expectError(
            case.expected,
            manager.mapRegion(address_space, 0x2000, 0x1000),
        );
    }

    RecordingEnvironment.reset(&.{abi.syscall.SYSCALL_FAILURE});
    try std.testing.expectError(
        error.InternalFailure,
        manager.mapRegion(address_space, 0x2000, 0x1000),
    );
}
