const std = @import("std");
const abi = @import("abi");

test "root task uses shared ABI constants" {
    try std.testing.expectEqual(@as(u32, 0), abi.syscall.EXIT_SUCCESS);
    try std.testing.expectEqual(@as(u32, 1), abi.syscall.EXIT_FAILURE);
    try std.testing.expectEqual(@as(u32, 0), abi.capability.INVALID_CAPABILITY);
}
