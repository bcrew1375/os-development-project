const abi = @import("abi");
const builtin = @import("builtin");
const std = @import("std");

pub fn writeInitialStack(
    bytes: []u8,
    startup: abi.process.ChildStartup,
    comptime stack_start: usize,
    comptime stack_top: usize,
) usize {
    const startup_offset = bytes.len - @sizeOf(abi.process.ChildStartup);
    @memcpy(bytes[startup_offset..][0..@sizeOf(abi.process.ChildStartup)], std.mem.asBytes(&startup));
    var stack_pointer = stack_start + startup_offset;
    switch (builtin.cpu.arch) {
        .x86 => {
            stack_pointer = std.mem.alignBackward(
                usize,
                stack_pointer - 2 * @sizeOf(u32),
                16,
            ) - @sizeOf(u32);
            const argument: u32 = @intCast(startupAddress(stack_top));
            @memcpy(
                bytes[stack_pointer + @sizeOf(u32) - stack_start ..][0..4],
                std.mem.asBytes(&argument),
            );
            const fake_return: u32 = 0;
            @memcpy(bytes[stack_pointer - stack_start ..][0..4], std.mem.asBytes(&fake_return));
        },
        .x86_64 => {
            stack_pointer = std.mem.alignBackward(usize, stack_pointer, 16);
            stack_pointer -= @sizeOf(u64);
            const fake_return: u64 = 0;
            @memcpy(bytes[stack_pointer - stack_start ..][0..8], std.mem.asBytes(&fake_return));
        },
        else => @compileError("unsupported child startup ABI"),
    }
    return stack_pointer;
}

pub fn startupAddress(comptime stack_top: usize) usize {
    return stack_top - @sizeOf(abi.process.ChildStartup);
}
