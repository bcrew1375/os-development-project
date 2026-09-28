const abi = @import("abi");
const process_management = @import("process_management");
const std = @import("std");

const EndpointRecordingTransport = @import("support/recording_transports.zig").EndpointRecordingTransport;

test "managed process validates startup service transfer and terminal lifecycle" {
    const ManagedProcess = process_management.managed_process.ManagedProcess;
    var managed = ManagedProcess{
        .child = .{},
        .parent_endpoint = .{ .capability = 71 },
        .lifecycle_endpoint = .{ .capability = 72 },
        .service_endpoint = .{ .capability = 73 },
        .lifecycle_token = 19,
        .expected_action = .exit_success,
    };

    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.receive_response.message =
        try abi.process.parentMessage(.startup, 19, 0);
    try managed.observeStartup(EndpointRecordingTransport);
    try std.testing.expectEqual(
        process_management.managed_process.State.startup_observed,
        managed.state,
    );

    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.receive_response.message =
        try abi.process.parentMessage(.service_request, 19, 0);
    try managed.transferServiceCapability(EndpointRecordingTransport);
    try std.testing.expectEqual(
        process_management.managed_process.State.service_transferred,
        managed.state,
    );
    const transfer = EndpointRecordingTransport.recorded_transfer_send_request.?;
    try std.testing.expectEqual(@as(u32, 73), transfer.source_capability);
    try std.testing.expectEqual(
        abi.capability.rightsBits(.{ .send = true }),
        transfer.rights_bits,
    );
    try std.testing.expectEqual(
        try abi.process.parentMessage(.service_ready, 19, 0),
        transfer.message,
    );
    try std.testing.expectEqual(@as(usize, 0), managed.child.delegated_capability_count);

    EndpointRecordingTransport.reset();
    const transferred_capability = abi.capability.makeCapabilityHandle(
        abi.system_smoke.CAPABILITY_TRANSFER_DESTINATION_SLOT,
        3,
    );
    EndpointRecordingTransport.receive_response.message =
        try abi.process.parentMessage(.service_ready, 19, transferred_capability);
    try managed.observeServiceReady(EndpointRecordingTransport);
    try std.testing.expectEqual(
        process_management.managed_process.State.service_ready,
        managed.state,
    );
    try std.testing.expectEqual(@as(usize, 1), managed.child.delegated_capability_count);
    try std.testing.expectEqual(
        transferred_capability,
        managed.child.delegated_capabilities[0],
    );

    EndpointRecordingTransport.reset();
    EndpointRecordingTransport.receive_response.message =
        try abi.process.lifecycleEvent(.exited, 19, abi.syscall.EXIT_SUCCESS);
    try std.testing.expectEqual(
        abi.process.LifecycleEvent{
            .kind = .exited,
            .lifecycle_token = 19,
            .value = abi.syscall.EXIT_SUCCESS,
        },
        try managed.observeTerminal(EndpointRecordingTransport),
    );
    try std.testing.expectEqual(
        process_management.managed_process.State.terminal_observed,
        managed.state,
    );
    try std.testing.expectError(
        error.InvalidState,
        managed.observeTerminal(EndpointRecordingTransport),
    );
}
