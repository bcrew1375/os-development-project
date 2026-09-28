const abi = @import("abi");
const process_management = @import("process_management");
const std = @import("std");

const RecordingEnvironment = @import("support/recording_environment.zig").RecordingEnvironment;
const process_manager = process_management.ProcessManager(RecordingEnvironment);

test "process manager emits creation configuration lifecycle and delegation syscalls" {
    RecordingEnvironment.reset(&.{
        41,
        42,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        43,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });
    const capability_space = try process_manager.createCapabilitySpace();
    const thread = try process_manager.createThread();
    const configuration = abi.process.ThreadConfiguration{
        .capability_space = capability_space.capability,
        .address_space = 17,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
        .argument = 0x1234,
    };
    try process_manager.configureThread(thread, &configuration);
    try process_manager.startThread(thread);
    try process_manager.suspendThread(thread);
    try process_manager.resumeThread(thread);
    try process_manager.terminateThread(thread, 23);
    const installed = try process_manager.installCapability(
        capability_space,
        thread.capability,
        .{ .terminate = true },
    );
    try std.testing.expectEqual(@as(u32, 43), installed);
    try process_manager.deleteCapability(capability_space, installed);
    try process_manager.destroyThread(thread);
    try process_manager.destroyCapabilitySpace(capability_space);

    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.configure_thread),
        RecordingEnvironment.syscalls[2].three.number,
    );
    try std.testing.expectEqual(thread.capability, RecordingEnvironment.syscalls[2].three.arguments[0]);
    try std.testing.expectEqual(@intFromPtr(&configuration), RecordingEnvironment.syscalls[2].three.arguments[1]);
    try std.testing.expectEqual(
        [_]usize{ capability_space.capability, thread.capability, abi.capability.rightsBits(.{ .terminate = true }) },
        RecordingEnvironment.syscalls[7].three.arguments,
    );
}

test "process manager decodes process-management errors" {
    const expected = [_]struct { code: abi.syscall.ErrorCode, err: process_management.Error }{
        .{ .code = .invalid_state, .err = error.InvalidState },
        .{ .code = .object_in_use, .err = error.ObjectInUse },
        .{ .code = .invalid_user_memory, .err = error.InvalidUserMemory },
    };
    for (expected) |case| {
        RecordingEnvironment.reset(&.{abi.syscall.errorResult(case.code)});
        try std.testing.expectError(case.err, process_manager.createThread());
    }
}
