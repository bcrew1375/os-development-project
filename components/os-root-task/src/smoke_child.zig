const abi = @import("abi");
const std = @import("std");

pub export fn _start(startup: *const abi.process.ChildStartup) callconv(.c) noreturn {
    if (startup.magic != abi.process.CHILD_STARTUP_MAGIC or
        startup.version != abi.process.CHILD_STARTUP_VERSION or
        startup.reserved != 0)
    {
        exit(abi.syscall.EXIT_FAILURE);
    }

    switch (startup.mode) {
        .ipc_receive => receiveAndVerify(startup.endpoint_capability),
        .invalid_opcode => {
            if (startup.endpoint_capability != abi.capability.INVALID_CAPABILITY) {
                exit(abi.syscall.EXIT_FAILURE);
            }
            debugWrite(abi.system_smoke.FAULT_CHILD_YIELDING);
        },
    }
    if (abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.yield), 0, 0, 0) !=
        abi.syscall.SYSCALL_SUCCESS)
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    debugWrite(switch (startup.mode) {
        .ipc_receive => abi.system_smoke.IPC_CHILD_RESUMED,
        .invalid_opcode => abi.system_smoke.FAULT_CHILD_RESUMED,
    });

    switch (startup.mode) {
        .ipc_receive => exit(abi.syscall.EXIT_SUCCESS),
        .invalid_opcode => asm volatile ("ud2"),
    }
    unreachable;
}

fn receiveAndVerify(endpoint_capability: abi.capability.CapabilityHandle) void {
    if (endpoint_capability == abi.capability.INVALID_CAPABILITY) {
        exit(abi.syscall.EXIT_FAILURE);
    }
    const result = abi.syscall.syscallReceive(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_receive),
        endpoint_capability,
    );
    if (result.status != abi.syscall.SYSCALL_SUCCESS or
        !std.meta.eql(result.message, abi.system_smoke.IPC_MESSAGE))
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    debugWrite(abi.system_smoke.IPC_MESSAGE_VERIFIED);
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
