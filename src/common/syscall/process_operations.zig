//! Capability-space and thread lifecycle syscall policy.

const abi = @import("abi");
const error_mapping = @import("error_mapping.zig");
const types = @import("types.zig");

const Operation = types.Operation;
const Result = types.Result;
const failure = error_mapping.failure;
const toU32 = error_mapping.toU32;

pub fn createCapabilitySpace(comptime Services: type, caller_space: u32) Result {
    if (!@hasDecl(Services, "createCapabilitySpaceCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = Services.createCapabilitySpaceCapability(caller_space) catch |err| {
        return failure(.create_capability_space, err);
    };
    return .{ .returned = handle };
}

pub fn createThread(comptime Services: type, caller_space: u32) Result {
    if (!@hasDecl(Services, "createThreadCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = Services.createThreadCapability(caller_space) catch |err| {
        return failure(.create_thread, err);
    };
    return .{ .returned = handle };
}

pub fn configureThread(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "configureThreadFromUser")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const thread_capability = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    Services.configureThreadFromUser(caller_space, thread_capability, arguments[1]) catch |err| {
        return failure(.configure_thread, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn controlThread(
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

pub fn terminateThread(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "terminateThreadCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const thread_capability = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    Services.terminateThreadCapability(caller_space, thread_capability, arguments[1]) catch |err| {
        return failure(.terminate_thread, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn faultReply(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "faultReplyFromUser")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const endpoint_capability = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.faultReplyFromUser(caller_space, endpoint_capability, arguments[1]) catch |err| {
        return failure(.fault_reply, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn installCapability(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
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

pub fn destroyObjectCapability(
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

pub fn deleteInstalledCapability(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
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
