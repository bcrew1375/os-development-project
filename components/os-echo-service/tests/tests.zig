const abi = @import("abi");
const std = @import("std");

test "echo request and reply fit the fixed IPC message shape" {
    try std.testing.expectEqual(@as(usize, 3), abi.ipc.MESSAGE_REGISTER_COUNT);
    try std.testing.expect(abi.system_smoke.ECHO_SERVICE_REQUEST.words[0] != 0);
    try std.testing.expect(!std.meta.eql(
        abi.system_smoke.ECHO_SERVICE_REQUEST,
        abi.system_smoke.ECHO_SERVICE_REPLY,
    ));
    try std.testing.expectEqual(
        abi.system_smoke.ECHO_SERVICE_REQUEST.words[1],
        abi.system_smoke.ECHO_SERVICE_REPLY.words[1],
    );
    try std.testing.expectEqual(
        abi.system_smoke.ECHO_SERVICE_REQUEST.words[2],
        abi.system_smoke.ECHO_SERVICE_REPLY.words[2],
    );
}

test "echo lifecycle tokens are valid and distinct" {
    try std.testing.expect(abi.system_smoke.ECHO_SERVICE_LIFECYCLE_TOKEN !=
        abi.process.INVALID_LIFECYCLE_TOKEN);
    try std.testing.expect(abi.system_smoke.ECHO_SERVICE_RESTART_LIFECYCLE_TOKEN !=
        abi.process.INVALID_LIFECYCLE_TOKEN);
    try std.testing.expect(abi.system_smoke.ECHO_SERVICE_LIFECYCLE_TOKEN !=
        abi.system_smoke.ECHO_SERVICE_RESTART_LIFECYCLE_TOKEN);
}

test "echo mode is a distinct startup mode" {
    try std.testing.expect(@intFromEnum(abi.process.ChildStartupMode.service_echo) !=
        @intFromEnum(abi.process.ChildStartupMode.ipc_ping_pong));
    try std.testing.expect(@intFromEnum(abi.process.ChildStartupMode.service_echo) !=
        @intFromEnum(abi.process.ChildStartupMode.managed_lifecycle));
}
