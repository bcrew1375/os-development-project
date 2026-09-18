const abi = @import("abi");
const startup = @import("startup.zig");

const NativeEnvironment = struct {
    pub const syscall3 = abi.syscall.syscall3;
    pub const syscall5 = abi.syscall.syscall5;

    pub fn debugWrite(message: []const u8) void {
        _ = syscall3(
            @intFromEnum(abi.syscall.SyscallNumber.debug_write),
            @intFromPtr(message.ptr),
            message.len,
            0,
        );
    }
};

pub export fn _start(boot_info: *const abi.boot_info.BootInfo) callconv(.c) noreturn {
    exit(startup.run(NativeEnvironment, boot_info));
}

fn exit(status: u32) noreturn {
    _ = abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.exit), status, 0, 0);
    while (true) {}
}
