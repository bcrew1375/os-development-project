//! Architecture-independent syscall decoding and kernel policy dispatch.

const abi = @import("abi");
const capability = @import("../capability/main.zig");
const process = @import("../process/main.zig");

/// Canonical syscall input after architecture register extraction.
pub const Request = struct {
    number: u32,
    arguments: [5]u64 = .{ 0, 0, 0, 0, 0 },
};

/// Kernel operation that failed while servicing a syscall.
pub const Operation = enum {
    resolve_execution_context,
    current_address_space,
    create_address_space,
    resolve_address_space,
    map_memory,
    create_memory_object,
    resolve_memory_object,
    map_memory_object,
    protect_address_space,
    query_address_space,
    unmap_address_space,
    destroy_address_space,
    convert_argument,
};

/// Failure information retained for architecture diagnostics and ABI writeback.
pub const Failure = struct {
    operation: Operation,
    err: anyerror,
    return_value: u32,
};

/// Result of common syscall policy before architecture-specific side effects.
pub const Result = union(enum) {
    returned: u32,
    debug_write: struct {
        address: u64,
        length: u64,
    },
    exit: struct {
        status: u64,
    },
    unsupported: struct {
        number: u32,
    },
    failure: Failure,
};

/// Dispatches a production syscall using the installed execution context.
pub fn dispatchFromCurrentContext(request: Request) Result {
    const caller_process_handle = process.execution_context.currentProcessHandle() catch |err| {
        return failure(.resolve_execution_context, err);
    };
    return dispatchWithServices(ProductionServices, caller_process_handle, request);
}

/// Dispatches policy through a statically supplied service implementation.
pub fn dispatchWithServices(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    request: Request,
) Result {
    const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(request.number);
    return switch (syscall_number) {
        .debug_write => .{ .debug_write = .{
            .address = request.arguments[0],
            .length = request.arguments[1],
        } },
        .exit => .{ .exit = .{ .status = request.arguments[0] } },
        .current_address_space => currentAddressSpace(Services, caller_process_handle),
        .create_address_space => createAddressSpace(Services, caller_process_handle),
        .map_memory => mapMemory(Services, caller_process_handle, request.arguments),
        .create_memory_object => createMemoryObject(
            Services,
            caller_process_handle,
            request.arguments[0],
        ),
        .map_memory_object => mapMemoryObject(Services, caller_process_handle, request.arguments),
        .protect_address_space => protectAddressSpace(Services, caller_process_handle, request.arguments),
        .query_address_space => queryAddressSpace(Services, caller_process_handle, request.arguments),
        .unmap_address_space => unmapAddressSpace(Services, caller_process_handle, request.arguments),
        .destroy_address_space => destroyAddressSpace(
            Services,
            caller_process_handle,
            request.arguments[0],
        ),
        _ => .{ .unsupported = .{ .number = request.number } },
    };
}

fn currentAddressSpace(comptime Services: type, caller_process_handle: process.ProcessHandle) Result {
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

fn createAddressSpace(comptime Services: type, caller_process_handle: process.ProcessHandle) Result {
    const handle = Services.createAddressSpaceCapability(caller_process_handle) catch |err| {
        return failure(.create_address_space, err);
    };
    return .{ .returned = handle };
}

fn mapMemory(
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

fn createMemoryObject(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    size_in_bytes: u64,
) Result {
    const handle = Services.createMemoryObjectCapability(
        caller_process_handle,
        size_in_bytes,
    ) catch |err| {
        return failure(.create_memory_object, err);
    };
    return .{ .returned = handle };
}

fn mapMemoryObject(
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

fn protectAddressSpace(
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

fn queryAddressSpace(
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

fn unmapAddressSpace(
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

fn destroyAddressSpace(
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

fn resolveOperation(err: anyerror) Operation {
    return if (err == error.ArgumentOutOfRange) .convert_argument else .resolve_address_space;
}

fn failure(operation: Operation, err: anyerror) Result {
    return .{ .failure = .{
        .operation = operation,
        .err = err,
        .return_value = abi.syscall.errorResult(errorCode(err)),
    } };
}

fn errorCode(err: anyerror) abi.syscall.ErrorCode {
    return switch (err) {
        error.InvalidCapability,
        error.CapabilityOwnerMismatch,
        error.InvalidCapabilityType,
        error.InvalidAddressSpaceHandle,
        error.InvalidMemoryObjectHandle,
        => .invalid_capability,
        error.InsufficientCapabilityRights => .insufficient_rights,
        error.OutOfCapabilities,
        error.OutOfAddressSpaces,
        error.OutOfMemoryObjects,
        error.OutOfVirtualMemoryAreas,
        error.AddressSpaceRootAllocationFailed,
        error.PhysicalMemoryAllocationFailed,
        => .out_of_resources,
        error.ArgumentOutOfRange,
        error.EmptyMemoryRange,
        error.MemoryRangeOverflow,
        error.KernelAddressRange,
        error.ObjectRangeOverflow,
        error.ObjectRangeOutOfBounds,
        error.UnalignedMemoryObjectRange,
        error.InvalidVirtualMemoryAreaRange,
        error.UnalignedVirtualMemoryArea,
        error.OverlappingVirtualMemoryArea,
        => .invalid_range,
        error.InvalidMemoryPermissions,
        error.ProtectionViolation,
        => .invalid_permissions,
        error.UndefinedVirtualMemoryArea,
        error.FaultOutsideVirtualMemoryArea,
        => .mapping_not_found,
        error.AddressSpaceInUse => .address_space_in_use,
        else => .internal_failure,
    };
}

fn toU32(value: u64) error{ArgumentOutOfRange}!u32 {
    return if (value <= @as(u64, @import("std").math.maxInt(u32)))
        @intCast(value)
    else
        error.ArgumentOutOfRange;
}

fn rightsFromMapFlags(permission_flags: u32) abi.capability.Rights {
    return .{
        .read = (permission_flags & abi.syscall.MAP_READ) != 0,
        .write = (permission_flags & abi.syscall.MAP_WRITE) != 0,
        .execute = (permission_flags & abi.syscall.MAP_EXECUTE) != 0,
    };
}

const ProductionServices = struct {
    pub const currentAddressSpaceHandle = process.execution_context.currentAddressSpaceHandle;
    pub const findAddressSpaceCapability = capability.findAddressSpaceCapability;
    pub const createAddressSpaceCapability = capability.createAddressSpaceCapability;
    pub const resolveAddressSpace = capability.resolveAddressSpace;
    pub const destroyAddressSpaceCapability = capability.destroyAddressSpaceCapability;
    pub const createMemoryObjectCapability = capability.createMemoryObjectCapability;
    pub const resolveMemoryObject = capability.resolveMemoryObject;
    pub const mapMemory = process.mapMemory;
    pub const mapMemoryObject = process.mapMemoryObject;
    pub const protectAddressSpace = process.protectAddressSpace;
    pub const queryAddressSpace = process.queryAddressSpace;
    pub const unmapAddressSpace = process.unmapAddressSpace;
};
