//! Independent echo service: ABI-only request/reply over endpoint IPC.
//!
//! The service imports only the stable ABI package. It must not import
//! kernel-private modules, the root-task implementation, or shared loader code.

const abi = @import("abi");
const std = @import("std");

pub export fn _start(startup: *const abi.process.ChildStartup) callconv(.c) noreturn {
    if (startup.magic != abi.process.CHILD_STARTUP_MAGIC or
        startup.version != abi.process.CHILD_STARTUP_VERSION)
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    if (startup.mode != .service_echo) {
        exit(abi.syscall.EXIT_FAILURE);
    }
    echo(
        startup.request_endpoint_capability,
        startup.reply_endpoint_capability,
    );
    exit(abi.syscall.EXIT_SUCCESS);
}

fn echo(
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
        !std.meta.eql(result.message, abi.system_smoke.ECHO_SERVICE_REQUEST))
    {
        exit(abi.syscall.EXIT_FAILURE);
    }
    if (abi.syscall.syscall5(
        @intFromEnum(abi.syscall.SyscallNumber.endpoint_send),
        reply_endpoint_capability,
        abi.system_smoke.ECHO_SERVICE_REPLY.words[0],
        abi.system_smoke.ECHO_SERVICE_REPLY.words[1],
        abi.system_smoke.ECHO_SERVICE_REPLY.words[2],
        0,
    ) != abi.syscall.SYSCALL_SUCCESS) {
        exit(abi.syscall.EXIT_FAILURE);
    }
}

fn exit(status: u32) noreturn {
    _ = abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.exit), status, 0, 0);
    while (true) {}
}
