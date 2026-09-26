//! Root-task wrappers for capability-authorized endpoint operations.

const abi = @import("abi");

pub const Endpoint = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const Error = error{
    InvalidCapability,
    InsufficientRights,
    OutOfResources,
    Unsupported,
    ObjectInUse,
    Empty,
    Full,
    Canceled,
    InternalFailure,
};

pub fn EndpointManager(comptime Transport: type) type {
    return struct {
        pub fn createEndpoint() Error!Endpoint {
            const result = Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_endpoint),
                0,
                0,
                0,
            );
            try checkError(result);
            if (result == abi.capability.INVALID_CAPABILITY) return Error.InternalFailure;
            return .{ .capability = result };
        }

        pub fn destroyEndpoint(endpoint: Endpoint) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.destroy_endpoint),
                endpoint.capability,
                0,
                0,
            ));
        }

        pub fn send(endpoint: Endpoint, message: abi.ipc.Message) Error!void {
            try voidResult(Transport.syscall5(
                @intFromEnum(abi.syscall.SyscallNumber.endpoint_send),
                endpoint.capability,
                message.words[0],
                message.words[1],
                message.words[2],
                0,
            ));
        }

        pub fn receive(endpoint: Endpoint) Error!abi.ipc.Message {
            const result = Transport.syscallReceive(
                @intFromEnum(abi.syscall.SyscallNumber.endpoint_receive),
                endpoint.capability,
            );
            try checkError(result.status);
            if (result.status != abi.syscall.SYSCALL_SUCCESS) return Error.InternalFailure;
            return result.message;
        }

        fn voidResult(result: u32) Error!void {
            try checkError(result);
            if (result != abi.syscall.SYSCALL_SUCCESS) return Error.InternalFailure;
        }

        fn checkError(result: u32) Error!void {
            const code = abi.syscall.decodeError(result) orelse return;
            return switch (code) {
                .invalid_capability => Error.InvalidCapability,
                .insufficient_rights => Error.InsufficientRights,
                .out_of_resources => Error.OutOfResources,
                .unsupported => Error.Unsupported,
                .object_in_use => Error.ObjectInUse,
                .endpoint_empty => Error.Empty,
                .endpoint_full => Error.Full,
                .endpoint_canceled => Error.Canceled,
                .invalid_range,
                .invalid_permissions,
                .mapping_not_found,
                .address_space_in_use,
                .invalid_state,
                .invalid_user_memory,
                .internal_failure,
                => Error.InternalFailure,
            };
        }
    };
}

const NativeTransport = struct {
    pub const syscall3 = abi.syscall.syscall3;
    pub const syscall5 = abi.syscall.syscall5;
    pub const syscallReceive = abi.syscall.syscallReceive;
};

const native = EndpointManager(NativeTransport);

pub const createEndpoint = native.createEndpoint;
pub const destroyEndpoint = native.destroyEndpoint;
pub const send = native.send;
pub const receive = native.receive;
