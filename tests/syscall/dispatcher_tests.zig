const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const assertions = @import("../support/syscall/assertions.zig");
const service_fakes = @import("../support/syscall/service_fakes.zig");

const RecordingServices = service_fakes.RecordingServices;
const expectReturned = assertions.expectReturned;
const request = assertions.request;

test "Syscall: side-effect requests preserve native-width arguments" {
    const debug_result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        request(.debug_write, .{ 0x1234_5678_9abc_def0, 0x1020_3040_5060_7080, 0, 0, 0 }),
    );
    switch (debug_result) {
        .debug_write => |write| {
            try std.testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), write.address);
            try std.testing.expectEqual(@as(u64, 0x1020_3040_5060_7080), write.length);
        },
        else => return error.UnexpectedSyscallResult,
    }

    const exit_result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        request(.exit, .{ 0xfedc_ba98_7654_3210, 0, 0, 0, 0 }),
    );
    switch (exit_result) {
        .exit => |exit| try std.testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), exit.status),
        else => return error.UnexpectedSyscallResult,
    }
}

test "Syscall: yield decodes as a scheduler side effect" {
    const result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        request(.yield, .{ 0, 0, 0, 0, 0 }),
    );
    switch (result) {
        .yield => {},
        else => return error.UnexpectedSyscallResult,
    }
}

test "Syscall: unknown numbers return the structured unsupported error" {
    const result = kernel.syscall.dispatchWithServices(
        RecordingServices,
        42,
        .{ .number = 0xffff_fffe },
    );
    try expectReturned(abi.syscall.errorResult(.unsupported), result);
}
