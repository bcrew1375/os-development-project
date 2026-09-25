//! Architecture-independent syscall decoding and kernel policy dispatch.

const abi = @import("abi");
const capability = @import("../capability/main.zig");
const process = @import("../process/main.zig");
const user_memory = @import("../user_memory.zig");

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
    retype_untyped_memory,
    delete_physical_memory,
    revoke_physical_memory,
    destroy_memory_object,
    create_capability_space,
    create_thread,
    configure_thread,
    start_thread,
    suspend_thread,
    resume_thread,
    terminate_thread,
    install_capability,
    destroy_thread,
    destroy_capability_space,
    delete_capability,
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
    yield,
    debug_write: struct {
        address: u64,
        length: u64,
    },
    exit: struct {
        status: u64,
    },
    failure: Failure,
};

/// Dispatches a production syscall using the installed execution context.
pub fn dispatchFromCurrentContext(request: Request) Result {
    const caller_capability_space = process.execution_context.currentCapabilitySpaceHandle() catch |err| {
        return failure(.resolve_execution_context, err);
    };
    return dispatchWithServices(ProductionServices, caller_capability_space, request);
}

/// Dispatches policy through a statically supplied service implementation.
pub fn dispatchWithServices(
    comptime Services: type,
    caller_capability_space: process.thread.CapabilitySpaceHandle,
    request: Request,
) Result {
    const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(request.number);
    return switch (syscall_number) {
        .debug_write => .{ .debug_write = .{
            .address = request.arguments[0],
            .length = request.arguments[1],
        } },
        .exit => .{ .exit = .{ .status = request.arguments[0] } },
        .yield => .yield,
        .current_address_space => currentAddressSpace(Services, caller_capability_space),
        .create_address_space => createAddressSpace(Services, caller_capability_space),
        .map_memory => mapMemory(Services, caller_capability_space, request.arguments),
        .create_memory_object => createMemoryObject(
            Services,
            caller_capability_space,
            request.arguments[0],
        ),
        .map_memory_object => mapMemoryObject(Services, caller_capability_space, request.arguments),
        .protect_address_space => protectAddressSpace(Services, caller_capability_space, request.arguments),
        .query_address_space => queryAddressSpace(Services, caller_capability_space, request.arguments),
        .unmap_address_space => unmapAddressSpace(Services, caller_capability_space, request.arguments),
        .destroy_address_space => destroyAddressSpace(
            Services,
            caller_capability_space,
            request.arguments[0],
        ),
        .retype_untyped_memory => retypeUntypedMemory(
            Services,
            caller_capability_space,
            request.arguments,
        ),
        .delete_physical_memory => deletePhysicalMemory(
            Services,
            caller_capability_space,
            request.arguments[0],
        ),
        .revoke_physical_memory => revokePhysicalMemory(
            Services,
            caller_capability_space,
            request.arguments[0],
        ),
        .destroy_memory_object => destroyMemoryObject(
            Services,
            caller_capability_space,
            request.arguments[0],
        ),
        .create_capability_space => createCapabilitySpace(Services, caller_capability_space),
        .create_thread => createThread(Services, caller_capability_space),
        .configure_thread => configureThread(Services, caller_capability_space, request.arguments),
        .start_thread => controlThread(Services, caller_capability_space, request.arguments[0], .start_thread),
        .suspend_thread => controlThread(Services, caller_capability_space, request.arguments[0], .suspend_thread),
        .resume_thread => controlThread(Services, caller_capability_space, request.arguments[0], .resume_thread),
        .terminate_thread => terminateThread(Services, caller_capability_space, request.arguments),
        .install_capability => installCapability(Services, caller_capability_space, request.arguments),
        .destroy_thread => destroyObjectCapability(Services, caller_capability_space, request.arguments[0], .destroy_thread),
        .destroy_capability_space => destroyObjectCapability(Services, caller_capability_space, request.arguments[0], .destroy_capability_space),
        .delete_capability => deleteInstalledCapability(
            Services,
            caller_capability_space,
            request.arguments,
        ),
        _ => .{ .returned = abi.syscall.errorResult(.unsupported) },
    };
}

fn createCapabilitySpace(comptime Services: type, caller_space: u32) Result {
    if (!@hasDecl(Services, "createCapabilitySpaceCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = Services.createCapabilitySpaceCapability(caller_space) catch |err| {
        return failure(.create_capability_space, err);
    };
    return .{ .returned = handle };
}

fn createThread(comptime Services: type, caller_space: u32) Result {
    if (!@hasDecl(Services, "createThreadCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = Services.createThreadCapability(caller_space) catch |err| {
        return failure(.create_thread, err);
    };
    return .{ .returned = handle };
}

fn configureThread(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "configureThreadFromUser")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const thread_capability = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    Services.configureThreadFromUser(caller_space, thread_capability, arguments[1]) catch |err| {
        return failure(.configure_thread, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

fn controlThread(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
    operation: Operation,
) Result {
    const thread_capability = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    switch (operation) {
        .start_thread => {
            if (!@hasDecl(Services, "startThreadCapability")) {
                return .{ .returned = abi.syscall.errorResult(.unsupported) };
            }
            Services.startThreadCapability(caller_space, thread_capability) catch |err| {
                return failure(operation, err);
            };
        },
        .suspend_thread => {
            if (!@hasDecl(Services, "suspendThreadCapability")) {
                return .{ .returned = abi.syscall.errorResult(.unsupported) };
            }
            Services.suspendThreadCapability(caller_space, thread_capability) catch |err| {
                return failure(operation, err);
            };
        },
        .resume_thread => {
            if (!@hasDecl(Services, "resumeThreadCapability")) {
                return .{ .returned = abi.syscall.errorResult(.unsupported) };
            }
            Services.resumeThreadCapability(caller_space, thread_capability) catch |err| {
                return failure(operation, err);
            };
        },
        else => unreachable,
    }
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

fn terminateThread(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "terminateThreadCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const thread_capability = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    Services.terminateThreadCapability(caller_space, thread_capability, arguments[1]) catch |err| {
        return failure(.terminate_thread, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

fn installCapability(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "installCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const target_space = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    const source = toU32(arguments[1]) catch |err| return failure(.convert_argument, err);
    const rights_bits = toU32(arguments[2]) catch |err| return failure(.convert_argument, err);
    const rights = abi.capability.rightsFromBits(rights_bits) orelse {
        return failure(.install_capability, error.InvalidCapabilityRights);
    };
    const installed = Services.installCapability(caller_space, target_space, source, rights) catch |err| {
        return failure(.install_capability, err);
    };
    return .{ .returned = installed };
}

fn destroyObjectCapability(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
    operation: Operation,
) Result {
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    switch (operation) {
        .destroy_thread => {
            if (!@hasDecl(Services, "destroyThreadCapability")) {
                return .{ .returned = abi.syscall.errorResult(.unsupported) };
            }
            Services.destroyThreadCapability(caller_space, handle) catch |err| {
                return failure(operation, err);
            };
        },
        .destroy_capability_space => {
            if (!@hasDecl(Services, "destroyCapabilitySpaceCapability")) {
                return .{ .returned = abi.syscall.errorResult(.unsupported) };
            }
            Services.destroyCapabilitySpaceCapability(caller_space, handle) catch |err| {
                return failure(operation, err);
            };
        },
        else => unreachable,
    }
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

fn deleteInstalledCapability(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "deleteCapabilityFromSpace")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const target_space = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    const target_capability = toU32(arguments[1]) catch |err| return failure(.convert_argument, err);
    Services.deleteCapabilityFromSpace(caller_space, target_space, target_capability) catch |err| {
        return failure(.delete_capability, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
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

fn destroyMemoryObject(
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

fn retypeUntypedMemory(
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

fn deletePhysicalMemory(
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

fn revokePhysicalMemory(
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
        error.InvalidCapabilitySpaceHandle,
        error.InvalidThreadHandle,
        error.InvalidAddressSpaceHandle,
        error.InvalidMemoryObjectHandle,
        error.ThreadOwnerMismatch,
        => .invalid_capability,
        error.InsufficientCapabilityRights => .insufficient_rights,
        error.InvalidCapabilityRights => .insufficient_rights,
        error.OutOfCapabilities,
        error.OutOfAuthorities,
        error.OutOfAddressSpaces,
        error.OutOfMemoryObjects,
        error.OutOfThreads,
        error.OutOfCapabilitySpaces,
        error.OutOfThreadContexts,
        error.OutOfVirtualMemoryAreas,
        error.AddressSpaceRootAllocationFailed,
        error.PhysicalMemoryAllocationFailed,
        => .out_of_resources,
        error.ArgumentOutOfRange,
        error.EmptyRange,
        error.RangeOverflow,
        error.RangeOutOfBounds,
        error.UnalignedRange,
        error.OverlappingAuthority,
        error.AuthorityHasDescendants,
        error.CapabilityHasDescendants,
        error.BootstrapRootDeletion,
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
        error.AddressSpaceInUse,
        error.MemoryObjectInUse,
        => .address_space_in_use,
        error.InvalidStateTransition,
        error.ThreadNotConfigured,
        error.ThreadAlreadyConfigured,
        error.SchedulerUninitialized,
        error.SchedulerAlreadyInitialized,
        error.NoCurrentThread,
        error.CurrentThreadMismatch,
        error.ThreadAlreadyQueued,
        error.ReadyQueueFull,
        => .invalid_state,
        error.ThreadInUse,
        error.CapabilitySpaceInUse,
        error.CapabilitySpaceNotEmpty,
        => .object_in_use,
        error.UserPageNotMapped,
        error.UserAccessDenied,
        error.WriteAccessDenied,
        error.CopyTooLarge,
        error.AddressOutOfRange,
        error.AddressRangeOverflow,
        error.PhysicalAddressOverflow,
        => .invalid_user_memory,
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

fn productionConfigureThreadFromUser(
    caller_space: u32,
    thread_capability: abi.capability.CapabilityHandle,
    configuration_address: u64,
) !void {
    var bytes: [@sizeOf(abi.process.ThreadConfiguration)]u8 = undefined;
    try user_memory.copyFromUser(&bytes, configuration_address, bytes.len);
    const configuration = @import("std").mem.bytesToValue(abi.process.ThreadConfiguration, &bytes);
    const thread_handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .configure = true },
    );
    const capability_space_handle = try capability.resolveCapabilitySpace(
        caller_space,
        configuration.capability_space,
        .{},
    );
    const address_space_handle = try capability.resolveAddressSpace(
        caller_space,
        configuration.address_space,
        .{ .execute = true },
    );
    try process.configureThread(thread_handle, .{
        .capability_space_handle = capability_space_handle,
        .address_space_handle = address_space_handle,
        .entry_point = configuration.entry_point,
        .stack_pointer = configuration.stack_pointer,
        .argument = configuration.argument,
    });
}

fn productionStartThreadCapability(caller_space: u32, thread_capability: u32) !void {
    const handle = try capability.resolveThread(caller_space, thread_capability, .{ .start = true });
    try process.scheduler.makeReady(handle);
}

fn productionSuspendThreadCapability(caller_space: u32, thread_capability: u32) !void {
    const handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .suspend_thread = true },
    );
    try process.scheduler.suspendThread(handle);
}

fn productionResumeThreadCapability(caller_space: u32, thread_capability: u32) !void {
    const handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .resume_thread = true },
    );
    try process.scheduler.resumeThread(handle);
}

fn productionTerminateThreadCapability(caller_space: u32, thread_capability: u32, status: u64) !void {
    const handle = try capability.resolveThread(
        caller_space,
        thread_capability,
        .{ .terminate = true },
    );
    try process.scheduler.terminate(handle, status);
}

const ProductionServices = struct {
    pub const currentAddressSpaceHandle = process.execution_context.currentAddressSpaceHandle;
    pub const findAddressSpaceCapability = capability.findAddressSpaceCapability;
    pub const createAddressSpaceCapability = capability.createAddressSpaceCapability;
    pub const resolveAddressSpace = capability.resolveAddressSpace;
    pub const destroyAddressSpaceCapability = capability.destroyAddressSpaceCapability;
    pub const retypeUntypedMemoryCapability = capability.retypeUntypedMemoryCapability;
    pub const deletePhysicalMemoryCapability = capability.deletePhysicalMemoryCapability;
    pub const revokePhysicalMemoryCapability = capability.revokePhysicalMemoryCapability;
    pub const createMemoryObjectCapability = capability.createMemoryObjectCapability;
    pub const destroyMemoryObjectCapability = capability.destroyMemoryObjectCapability;
    pub const resolveMemoryObject = capability.resolveMemoryObject;
    pub const mapMemory = process.mapMemory;
    pub const mapMemoryObject = process.mapMemoryObject;
    pub const protectAddressSpace = process.protectAddressSpace;
    pub const queryAddressSpace = process.queryAddressSpace;
    pub const unmapAddressSpace = process.unmapAddressSpace;
    pub const createCapabilitySpaceCapability = capability.createCapabilitySpaceCapability;
    pub const createThreadCapability = capability.createThreadCapability;
    pub const configureThreadFromUser = productionConfigureThreadFromUser;
    pub const startThreadCapability = productionStartThreadCapability;
    pub const suspendThreadCapability = productionSuspendThreadCapability;
    pub const resumeThreadCapability = productionResumeThreadCapability;
    pub const terminateThreadCapability = productionTerminateThreadCapability;
    pub const installCapability = capability.installCapability;
    pub const destroyThreadCapability = capability.destroyThreadCapability;
    pub const destroyCapabilitySpaceCapability = capability.destroyCapabilitySpaceCapability;
    pub const deleteCapabilityFromSpace = capability.deleteCapabilityFromSpace;
};
