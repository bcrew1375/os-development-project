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
    create_address_space,
    resolve_address_space,
    map_memory,
    create_memory_object,
    resolve_memory_object,
    map_memory_object,
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
        return failure(.resolve_execution_context, err, abi.syscall.SYSCALL_FAILURE);
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
        .create_address_space => createAddressSpace(Services, caller_process_handle),
        .map_memory => mapMemory(Services, caller_process_handle, request.arguments),
        .create_memory_object => createMemoryObject(
            Services,
            caller_process_handle,
            request.arguments[0],
        ),
        .map_memory_object => mapMemoryObject(Services, caller_process_handle, request.arguments),
        _ => .{ .unsupported = .{ .number = request.number } },
    };
}

fn createAddressSpace(comptime Services: type, caller_process_handle: process.ProcessHandle) Result {
    const handle = Services.createAddressSpaceCapability(caller_process_handle) catch |err| {
        return failure(.create_address_space, err, abi.capability.INVALID_CAPABILITY);
    };
    return .{ .returned = handle };
}

fn mapMemory(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const capability_handle = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err, abi.syscall.SYSCALL_FAILURE);
    };
    const address_space_handle = Services.resolveAddressSpace(
        caller_process_handle,
        capability_handle,
        .{ .manage = true },
    ) catch |err| {
        return failure(.resolve_address_space, err, abi.syscall.SYSCALL_FAILURE);
    };
    Services.mapMemory(address_space_handle, arguments[1], arguments[2]) catch |err| {
        return failure(.map_memory, err, abi.syscall.SYSCALL_FAILURE);
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
        return failure(.create_memory_object, err, abi.capability.INVALID_CAPABILITY);
    };
    return .{ .returned = handle };
}

fn mapMemoryObject(
    comptime Services: type,
    caller_process_handle: process.ProcessHandle,
    arguments: [5]u64,
) Result {
    const address_space_capability = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err, abi.syscall.SYSCALL_FAILURE);
    };
    const memory_object_capability = toU32(arguments[1]) catch |err| {
        return failure(.convert_argument, err, abi.syscall.SYSCALL_FAILURE);
    };
    const permission_flags = toU32(arguments[4]) catch |err| {
        return failure(.convert_argument, err, abi.syscall.SYSCALL_FAILURE);
    };

    const address_space_handle = Services.resolveAddressSpace(
        caller_process_handle,
        address_space_capability,
        .{ .manage = true },
    ) catch |err| {
        return failure(.resolve_address_space, err, abi.syscall.SYSCALL_FAILURE);
    };
    const memory_object_handle = Services.resolveMemoryObject(
        caller_process_handle,
        memory_object_capability,
        rightsFromMapFlags(permission_flags),
    ) catch |err| {
        return failure(.resolve_memory_object, err, abi.syscall.SYSCALL_FAILURE);
    };
    Services.mapMemoryObject(
        address_space_handle,
        memory_object_handle,
        arguments[2],
        0,
        arguments[3],
        permission_flags,
    ) catch |err| {
        return failure(.map_memory_object, err, abi.syscall.SYSCALL_FAILURE);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

fn failure(operation: Operation, err: anyerror, return_value: u32) Result {
    return .{ .failure = .{
        .operation = operation,
        .err = err,
        .return_value = return_value,
    } };
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
    pub const createAddressSpaceCapability = capability.createAddressSpaceCapability;
    pub const resolveAddressSpace = capability.resolveAddressSpace;
    pub const createMemoryObjectCapability = capability.createMemoryObjectCapability;
    pub const resolveMemoryObject = capability.resolveMemoryObject;
    pub const mapMemory = process.mapMemory;
    pub const mapMemoryObject = process.mapMemoryObject;
};
