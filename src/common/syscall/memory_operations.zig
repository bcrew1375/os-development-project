//! Address-space, memory-object, and physical-memory syscall policy.

const abi = @import("abi");
const process = @import("../process/main.zig");
const error_mapping = @import("error_mapping.zig");
const types = @import("types.zig");

const Operation = types.Operation;
const Result = types.Result;
const failure = error_mapping.failure;
const resolveOperation = error_mapping.resolveOperation;
const toU32 = error_mapping.toU32;

pub fn currentAddressSpace(comptime Services: type, caller_process_handle: process.ProcessHandle) Result {
    const address_space_handle = Services.currentAddressSpaceHandle() catch |err| {
        return failure(.current_address_space, err);
    };
    const capability_handle = Services.findAddressSpaceCapability(
        caller_process_handle,
        address_space_handle,
    ) catch |err| {
        return failure(.current_address_space, err);
    };
    return .{ .returned = capability_handle };
}

pub fn createAddressSpace(comptime Services: type, caller_process_handle: process.ProcessHandle) Result {
    const handle = Services.createAddressSpaceCapability(caller_process_handle) catch |err| {
        return failure(.create_address_space, err);
    };
    return .{ .returned = handle };
}

pub fn mapMemory(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const address_space_handle = resolveAddressSpace(
        Services,
        caller_process_handle,
        arguments[0],
        .{ .manage = true },
    ) catch |err| return failure(resolveOperation(err), err);
    Services.mapMemory(address_space_handle, arguments[1], arguments[2]) catch |err| {
        return failure(.map_memory, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn createMemoryObject(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    frame_capability_value: u64,
) Result {
    const frame_capability = toU32(frame_capability_value) catch |err| {
        return failure(.convert_argument, err);
    };
    const handle = Services.createMemoryObjectCapability(
        caller_process_handle,
        frame_capability,
    ) catch |err| {
        return failure(.create_memory_object, err);
    };
    return .{ .returned = handle };
}

pub fn destroyMemoryObject(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    capability_value: u64,
) Result {
    const capability_handle = toU32(capability_value) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.destroyMemoryObjectCapability(
        caller_process_handle,
        capability_handle,
    ) catch |err| return failure(.destroy_memory_object, err);
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn mapMemoryObject(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const address_space_capability = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err);
    };
    const memory_object_capability = toU32(arguments[1]) catch |err| {
        return failure(.convert_argument, err);
    };
    const permission_flags = toU32(arguments[4]) catch |err| {
        return failure(.convert_argument, err);
    };

    const address_space_handle = Services.resolveAddressSpace(
        caller_process_handle,
        address_space_capability,
        .{ .manage = true },
    ) catch |err| {
        return failure(.resolve_address_space, err);
    };
    const memory_object_handle = Services.resolveMemoryObject(
        caller_process_handle,
        memory_object_capability,
        rightsFromMapFlags(permission_flags),
    ) catch |err| {
        return failure(.resolve_memory_object, err);
    };
    Services.mapMemoryObject(
        address_space_handle,
        memory_object_handle,
        arguments[2],
        0,
        arguments[3],
        permission_flags,
    ) catch |err| {
        return failure(.map_memory_object, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn protectAddressSpace(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const address_space_handle = resolveAddressSpace(
        Services,
        caller_process_handle,
        arguments[0],
        .{ .manage = true },
    ) catch |err| return failure(resolveOperation(err), err);
    const permission_flags = toU32(arguments[3]) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.protectAddressSpace(
        address_space_handle,
        arguments[1],
        arguments[2],
        permission_flags,
    ) catch |err| return failure(.protect_address_space, err);
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn queryAddressSpace(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const address_space_handle = resolveAddressSpace(
        Services,
        caller_process_handle,
        arguments[0],
        .{ .read = true },
    ) catch |err| return failure(resolveOperation(err), err);
    const permission_flags = Services.queryAddressSpace(
        address_space_handle,
        arguments[1],
        arguments[2],
    ) catch |err| return failure(.query_address_space, err);
    return .{ .returned = permission_flags };
}

pub fn unmapAddressSpace(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const address_space_handle = resolveAddressSpace(
        Services,
        caller_process_handle,
        arguments[0],
        .{ .manage = true },
    ) catch |err| return failure(resolveOperation(err), err);
    Services.unmapAddressSpace(
        address_space_handle,
        arguments[1],
        arguments[2],
    ) catch |err| return failure(.unmap_address_space, err);
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn destroyAddressSpace(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    capability_value: u64,
) Result {
    const capability_handle = toU32(capability_value) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.destroyAddressSpaceCapability(
        caller_process_handle,
        capability_handle,
    ) catch |err| return failure(.destroy_address_space, err);
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn retypeUntypedMemory(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const source_capability = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err);
    };
    const offset_low = toU32(arguments[1]) catch |err| {
        return failure(.convert_argument, err);
    };
    const offset_high = toU32(arguments[2]) catch |err| {
        return failure(.convert_argument, err);
    };
    const page_count = toU32(arguments[3]) catch |err| {
        return failure(.convert_argument, err);
    };
    const encoded_target = toU32(arguments[4]) catch |err| {
        return failure(.convert_argument, err);
    };
    const rights = abi.capability.rightsFromBits(
        abi.syscall.retypeTargetRightsBits(encoded_target),
    ) orelse return failure(.retype_untyped_memory, error.InvalidCapabilityRights);

    const handle = Services.retypeUntypedMemoryCapability(
        caller_process_handle,
        source_capability,
        abi.syscall.joinU64(offset_low, offset_high),
        page_count,
        abi.syscall.retypeTargetObjectType(encoded_target),
        rights,
    ) catch |err| return failure(.retype_untyped_memory, err);
    return .{ .returned = handle };
}

pub fn deletePhysicalMemory(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    capability_value: u64,
) Result {
    const capability_handle = toU32(capability_value) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.deletePhysicalMemoryCapability(
        caller_process_handle,
        capability_handle,
    ) catch |err| return failure(.delete_physical_memory, err);
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn revokePhysicalMemory(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    capability_value: u64,
) Result {
    const capability_handle = toU32(capability_value) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.revokePhysicalMemoryCapability(
        caller_process_handle,
        capability_handle,
    ) catch |err| return failure(.revoke_physical_memory, err);
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

fn resolveAddressSpace(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    capability_value: u64,
    required_rights: abi.capability.Rights,
) !process.AddressSpaceHandle {
    const capability_handle = try toU32(capability_value);
    return Services.resolveAddressSpace(
        caller_process_handle,
        capability_handle,
        required_rights,
    );
}

fn rightsFromMapFlags(permission_flags: u32) abi.capability.Rights {
    return .{
        .read = (permission_flags & abi.syscall.MAP_READ) != 0,
        .write = (permission_flags & abi.syscall.MAP_WRITE) != 0,
        .execute = (permission_flags & abi.syscall.MAP_EXECUTE) != 0,
    };
}
