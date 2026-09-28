const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const assertions = @import("../support/syscall/assertions.zig");
const service_fakes = @import("../support/syscall/service_fakes.zig");

const FailingServices = service_fakes.FailingServices;
const RecordingServices = service_fakes.RecordingServices;
const expectFailure = assertions.expectFailure;
const request = assertions.request;

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
