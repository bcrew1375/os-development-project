const abi = @import("abi");

pub export fn _start(startup: *const abi.process.ChildStartup) callconv(.c) noreturn {
    if (startup.magic != abi.process.CHILD_STARTUP_MAGIC or
        startup.version != abi.process.CHILD_STARTUP_VERSION or
        startup.reserved != 0)
    {
        exit(abi.syscall.EXIT_FAILURE);
    }

    debugWrite(switch (startup.mode) {
        .clean_exit => "SYSTEM-SMOKE milestone=clean_child_yielding\n",
        .invalid_opcode => "SYSTEM-SMOKE milestone=fault_child_yielding\n",
    });
    if (abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.yield), 0, 0, 0) !=
        abi.syscall.SYSCALL_SUCCESS)
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    debugWrite(switch (startup.mode) {
        .clean_exit => "SYSTEM-SMOKE milestone=clean_child_resumed\n",
        .invalid_opcode => "SYSTEM-SMOKE milestone=fault_child_resumed\n",
    });

    switch (startup.mode) {
        .clean_exit => exit(abi.syscall.EXIT_SUCCESS),
        .invalid_opcode => asm volatile ("ud2"),
    }
    unreachable;
}

fn debugWrite(message: []const u8) void {
    _ = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.debug_write),
        @intFromPtr(message.ptr),
        message.len,
        0,
    );
}

fn exit(status: u32) noreturn {
    _ = abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.exit), status, 0, 0);
    while (true) {}
}
