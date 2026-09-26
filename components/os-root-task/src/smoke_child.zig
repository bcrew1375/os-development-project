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
        .ipc_ping_pong => pingPong(
            startup.request_endpoint_capability,
            startup.reply_endpoint_capability,
        ),
        .invalid_opcode => {
            if (startup.request_endpoint_capability != abi.capability.INVALID_CAPABILITY or
                startup.reply_endpoint_capability != abi.capability.INVALID_CAPABILITY)
            {
                exit(abi.syscall.EXIT_FAILURE);
            }
            debugWrite(abi.system_smoke.FAULT_CHILD_YIELDING);
        },
    }
    switch (startup.mode) {
        .ipc_ping_pong => exit(abi.syscall.EXIT_SUCCESS),
        .invalid_opcode => {
            if (abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.yield), 0, 0, 0) !=
                abi.syscall.SYSCALL_SUCCESS)
            {
                exit(abi.syscall.EXIT_FAILURE);
            }
            debugWrite(abi.system_smoke.FAULT_CHILD_RESUMED);
            asm volatile ("ud2");
        },
    }
    unreachable;
}

fn pingPong(
    request_endpoint_capability: abi.capability.CapabilityHandle,
    reply_endpoint_capability: abi.capability.CapabilityHandle,
) void {
    if (request_endpoint_capability == abi.capability.INVALID_CAPABILITY or
        reply_endpoint_capability == abi.capability.INVALID_CAPABILITY)
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    const result = abi.syscall.syscallReceive(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_receive),
        request_endpoint_capability,
    );
    if (result.status != abi.syscall.SYSCALL_SUCCESS or
        !std.meta.eql(result.message, abi.system_smoke.IPC_REQUEST))
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    debugWrite(abi.system_smoke.IPC_REQUEST_VERIFIED);
    if (abi.syscall.syscall5(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_send),
        reply_endpoint_capability,
        abi.system_smoke.IPC_REPLY.words[0],
        abi.system_smoke.IPC_REPLY.words[1],
        abi.system_smoke.IPC_REPLY.words[2],
        0,
    ) != abi.syscall.SYSCALL_SUCCESS) {
        exit(abi.syscall.EXIT_FAILURE);
    }
    debugWrite(abi.system_smoke.IPC_REPLY_SENT);
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
