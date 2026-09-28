//! Endpoint, notification, capability-transfer, and interrupt-source syscall policy.

const abi = @import("abi");
const ipc = @import("../ipc/main.zig");
const error_mapping = @import("error_mapping.zig");
const types = @import("types.zig");

const Result = types.Result;
const failure = error_mapping.failure;
const toU32 = error_mapping.toU32;

pub fn createNotification(comptime Services: type, caller_space: u32) Result {
    if (!@hasDecl(Services, "createNotificationCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = Services.createNotificationCapability(caller_space) catch |err| {
        return failure(.create_notification, err);
    };
    return .{ .returned = handle };
}

pub fn destroyNotification(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "destroyNotificationCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    Services.destroyNotificationCapability(caller_space, handle) catch |err| {
        return failure(.destroy_notification, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn waitNotification(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "waitNotification")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    const outcome = Services.waitNotification(caller_space, handle) catch |err| {
        return failure(.notification_wait, err);
    };
    return switch (outcome) {
        .completed => |pending| .{
            .returned_registers = ipc.notification_operations.pendingResult(pending),
        },
        .blocked => .blocked,
    };
}

pub fn signalNotification(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "signalNotification")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    Services.signalNotification(caller_space, handle) catch |err| {
        return failure(.notification_signal, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn createInterruptSource(
    comptime Services: type,
    caller_space: u32,
    arguments: [5]u64,
) Result {
    if (!@hasDecl(Services, "createInterruptSourceCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const kind_value = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    const parameter = toU32(arguments[1]) catch |err| return failure(.convert_argument, err);
    const kind: abi.notification.InterruptSourceKind = @enumFromInt(kind_value);
    const handle = Services.createInterruptSourceCapability(
        caller_space,
        kind,
        parameter,
    ) catch |err| return failure(.create_interrupt_source, err);
    return .{ .returned = handle };
}

pub fn destroyInterruptSource(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "destroyInterruptSourceCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    Services.destroyInterruptSourceCapability(caller_space, handle) catch |err| {
        return failure(.destroy_interrupt_source, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn bindInterruptSource(
    comptime Services: type,
    caller_space: u32,
    arguments: [5]u64,
) Result {
    if (!@hasDecl(Services, "bindInterruptSource")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const source = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    const notification_handle = toU32(arguments[1]) catch |err| {
        return failure(.convert_argument, err);
    };
    Services.bindInterruptSource(caller_space, source, notification_handle) catch |err| {
        return failure(.bind_interrupt_source, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn unbindInterruptSource(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "unbindInterruptSource")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    Services.unbindInterruptSource(caller_space, handle) catch |err| {
        return failure(.unbind_interrupt_source, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn acknowledgeInterruptSource(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "acknowledgeInterruptSource")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    Services.acknowledgeInterruptSource(caller_space, handle) catch |err| {
        return failure(.acknowledge_interrupt_source, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn createEndpoint(comptime Services: type, caller_space: u32) Result {
    if (!@hasDecl(Services, "createEndpointCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = Services.createEndpointCapability(caller_space) catch |err| {
        return failure(.create_endpoint, err);
    };
    return .{ .returned = handle };
}

pub fn destroyEndpoint(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "destroyEndpointCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    Services.destroyEndpointCapability(caller_space, handle) catch |err| {
        return failure(.destroy_endpoint, err);
    };
    return .{ .returned = abi.syscall.SYSCALL_SUCCESS };
}

pub fn sendEndpoint(comptime Services: type, caller_space: u32, arguments: [5]u64) Result {
    if (!@hasDecl(Services, "sendEndpointMessage")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(arguments[0]) catch |err| return failure(.convert_argument, err);
    const message = abi.ipc.Message{ .words = .{
        toU32(arguments[1]) catch |err| return failure(.convert_argument, err),
        toU32(arguments[2]) catch |err| return failure(.convert_argument, err),
        toU32(arguments[3]) catch |err| return failure(.convert_argument, err),
    } };
    const outcome = Services.sendEndpointMessage(caller_space, handle, message) catch |err| {
        return failure(.endpoint_send, err);
    };
    return switch (outcome) {
        .completed => .{ .returned = abi.syscall.SYSCALL_SUCCESS },
        .blocked => .blocked,
    };
}

pub fn receiveEndpoint(
    comptime Services: type,
    caller_space: u32,
    capability_value: u64,
) Result {
    if (!@hasDecl(Services, "receiveEndpointMessage")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const handle = toU32(capability_value) catch |err| return failure(.convert_argument, err);
    const outcome = Services.receiveEndpointMessage(caller_space, handle) catch |err| {
        return failure(.endpoint_receive, err);
    };
    return switch (outcome) {
        .completed => |message| .{ .returned_registers = .{
            .status = abi.syscall.SYSCALL_SUCCESS,
            .words = .{ message.words[0], message.words[1], message.words[2] },
        } },
        .blocked => .blocked,
    };
}

pub fn sendEndpointCapability(
    comptime Services: type,
    caller_space: u32,
    arguments: [5]u64,
) Result {
    if (!@hasDecl(Services, "sendEndpointCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const endpoint_capability = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err);
    };
    const outcome = Services.sendEndpointCapability(
        caller_space,
        endpoint_capability,
        arguments[1],
    ) catch |err| return failure(.endpoint_send_capability, err);
    return switch (outcome) {
        .completed => .{ .returned = abi.syscall.SYSCALL_SUCCESS },
        .blocked => .blocked,
    };
}

pub fn receiveEndpointCapability(
    comptime Services: type,
    caller_space: u32,
    arguments: [5]u64,
) Result {
    if (!@hasDecl(Services, "receiveEndpointCapability")) {
        return .{ .returned = abi.syscall.errorResult(.unsupported) };
    }
    const endpoint_capability = toU32(arguments[0]) catch |err| {
        return failure(.convert_argument, err);
    };
    const outcome = Services.receiveEndpointCapability(
        caller_space,
        endpoint_capability,
        arguments[1],
    ) catch |err| return failure(.endpoint_receive_capability, err);
    return switch (outcome) {
        .completed => |transfer| .{ .returned_registers = .{
            .status = abi.syscall.SYSCALL_SUCCESS,
            .words = .{
                transfer.message.words[0],
                transfer.message.words[1],
                transfer.message.words[2],
            },
            .capability = transfer.capability,
        } },
        .blocked => .blocked,
    };
}
