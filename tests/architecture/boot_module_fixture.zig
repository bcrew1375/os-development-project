pub const retained_module_count: usize = 16;
pub const supplied_module_count: usize = retained_module_count + 1;

pub fn payloadSize(index: usize) usize {
    return index + 1;
}

pub fn payloadByte(index: usize) u8 {
    return @intCast(index + 1);
}

pub fn fileName(buffer: []u8, index: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "boot-module-{d:0>2}.bin", .{index}) catch unreachable;
}

const std = @import("std");
