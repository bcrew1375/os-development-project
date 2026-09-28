const abi = @import("abi");
const ipc = @import("ipc");
const std = @import("std");

const EndpointRecordingTransport = @import("support/recording_transports.zig").EndpointRecordingTransport;
const endpoint_manager = ipc.EndpointManager(EndpointRecordingTransport);

test "endpoint manager emits fixed-register endpoint syscalls" {
    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.scalar_response = 73;
    const endpoint = try endpoint_manager.createEndpoint();
    try std.testing.expectEqual(@as(u32, 73), endpoint.capability);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.create_endpoint),
        EndpointRecordingTransport.syscall_number,
    );

    EndpointRecordingTransport.scalar_response = abi.syscall.SYSCALL_SUCCESS;
    try endpoint_manager.send(endpoint, .{ .words = .{ 11, 22, 33 } });
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_send),
        EndpointRecordingTransport.syscall_number,
    );
    try std.testing.expectEqual(
        [_]usize{ 73, 11, 22, 33, 0 },
        EndpointRecordingTransport.arguments,
    );

    EndpointRecordingTransport.receive_response = .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .message = .{ .words = .{ 44, 55, 66 } },
    };
    try std.testing.expectEqual(
        abi.ipc.Message{ .words = .{ 44, 55, 66 } },
        try endpoint_manager.receive(endpoint),
    );
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_receive),
        EndpointRecordingTransport.syscall_number,
    );

    try endpoint_manager.destroyEndpoint(endpoint);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_endpoint),
        EndpointRecordingTransport.syscall_number,
    );
}

test "endpoint manager emits capability-transfer send and receive syscalls" {
    EndpointRecordingTransport.reset();
    const endpoint = ipc.Endpoint{ .capability = 73 };
    const message = abi.ipc.Message{ .words = .{ 10, 20, 30 } };
    const rights = abi.capability.Rights{ .send = true };

    try endpoint_manager.sendCapability(endpoint, 99, rights, message);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_send_capability),
        EndpointRecordingTransport.syscall_number,
    );
    try std.testing.expectEqual(@as(usize, 73), EndpointRecordingTransport.arguments[0]);
    const send_req = EndpointRecordingTransport.recorded_transfer_send_request.?;
    try std.testing.expectEqual(@as(u32, 99), send_req.source_capability);
    try std.testing.expectEqual(abi.capability.rightsBits(rights), send_req.rights_bits);
    try std.testing.expectEqual(message, send_req.message);

    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.transfer_receive_response = .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .message = message,
        .capability = 101,
    };
    const received = try endpoint_manager.receiveCapability(endpoint, 15);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_receive_capability),
        EndpointRecordingTransport.syscall_number,
    );
    try std.testing.expectEqual(@as(usize, 73), EndpointRecordingTransport.arguments[0]);
    const recv_req = EndpointRecordingTransport.recorded_transfer_receive_request.?;
    try std.testing.expectEqual(@as(u32, 15), recv_req.destination_slot);
    try std.testing.expectEqual(message, received.message);
    try std.testing.expectEqual(@as(u32, 101), received.capability);

    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.transfer_receive_response.status =
        abi.syscall.errorResult(.capability_slot_occupied);
    try std.testing.expectError(
        error.SlotOccupied,
        endpoint_manager.receiveCapability(endpoint, 15),
    );

    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.transfer_receive_response.status =
        abi.syscall.errorResult(.invalid_capability_slot);
    try std.testing.expectError(
        error.InvalidSlot,
        endpoint_manager.receiveCapability(endpoint, 15),
    );
}

test "endpoint manager distinguishes empty full and authorization failures" {
    const cases = [_]struct { code: abi.syscall.ErrorCode, err: ipc.Error }{
        .{ .code = .endpoint_empty, .err = error.Empty },
        .{ .code = .endpoint_full, .err = error.Full },
        .{ .code = .endpoint_canceled, .err = error.Canceled },
        .{ .code = .insufficient_rights, .err = error.InsufficientRights },
        .{ .code = .invalid_capability, .err = error.InvalidCapability },
        .{ .code = .invalid_user_memory, .err = error.InvalidUserMemory },
    };
    for (cases) |case| {
        EndpointRecordingTransport.reset();
        EndpointRecordingTransport.receive_response.status = abi.syscall.errorResult(case.code);
        try std.testing.expectError(
            case.err,
            endpoint_manager.receive(.{ .capability = 73 }),
        );
    }
}
