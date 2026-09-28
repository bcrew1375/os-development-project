const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

pub fn request(number: abi.syscall.SyscallNumber, arguments: [5]u64) kernel.syscall.Request {
    return .{
        .number = @intFromEnum(number),
        .arguments = arguments,
    };
}

pub fn expectReturned(expected: u32, result: kernel.syscall.Result) !void {
    switch (result) {
        .returned => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedSyscallResult,
    }
}

pub fn expectFailure(
    expected_operation: kernel.syscall.Operation,
    expected_error: anyerror,
    expected_return_value: u32,
    result: kernel.syscall.Result,
) !void {
    switch (result) {
        .failure => |actual| {
            try std.testing.expectEqual(expected_operation, actual.operation);
            try std.testing.expectEqual(expected_error, actual.err);
            try std.testing.expectEqual(expected_return_value, actual.return_value);
        },
        else => return error.UnexpectedSyscallResult,
    }
}
