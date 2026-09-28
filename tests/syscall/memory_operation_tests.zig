const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const assertions = @import("../support/syscall/assertions.zig");
const service_fakes = @import("../support/syscall/service_fakes.zig");

const RecordingServices = service_fakes.RecordingServices;
const expectReturned = assertions.expectReturned;
const request = assertions.request;

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
