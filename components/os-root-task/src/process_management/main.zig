//! Root-task wrappers for thread and capability-space kernel operations.

const abi = @import("abi");

pub const child_process = @import("child_process.zig");

pub const Thread = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const CapabilitySpace = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const Error = error{
    InvalidCapability,
    InsufficientRights,
    OutOfResources,
    InvalidRange,
    InvalidPermissions,
    MappingNotFound,
    AddressSpaceInUse,
    Unsupported,
    InvalidState,
    ObjectInUse,
    InvalidUserMemory,
    InternalFailure,
};

pub fn ProcessManager(comptime Transport: type) type {
    return struct {
        pub fn createCapabilitySpace() Error!CapabilitySpace {
            return .{ .capability = try capabilityResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_capability_space),
                0,
                0,
                0,
            )) };
        }

        pub fn createThread() Error!Thread {
            return .{ .capability = try capabilityResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_thread),
                0,
                0,
                0,
            )) };
        }

        pub fn configureThread(
            thread: Thread,
            configuration: *const abi.process.ThreadConfiguration,
        ) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.configure_thread),
                thread.capability,
                @intFromPtr(configuration),
                0,
            ));
        }

        pub fn startThread(thread: Thread) Error!void {
            try unaryThreadOperation(.start_thread, thread);
        }

        pub fn suspendThread(thread: Thread) Error!void {
            try unaryThreadOperation(.suspend_thread, thread);
        }

        pub fn resumeThread(thread: Thread) Error!void {
            try unaryThreadOperation(.resume_thread, thread);
        }

        pub fn terminateThread(thread: Thread, status: u32) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.terminate_thread),
                thread.capability,
                status,
                0,
            ));
        }

        pub fn installCapability(
            target: CapabilitySpace,
            source: abi.capability.CapabilityHandle,
            rights: abi.capability.Rights,
        ) Error!abi.capability.CapabilityHandle {
            return capabilityResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.install_capability),
                target.capability,
                source,
                abi.capability.rightsBits(rights),
            ));
        }

        pub fn destroyThread(thread: Thread) Error!void {
            try objectOperation(.destroy_thread, thread.capability);
        }

        pub fn destroyCapabilitySpace(capability_space: CapabilitySpace) Error!void {
            try objectOperation(.destroy_capability_space, capability_space.capability);
        }

        pub fn deleteCapability(
            target: CapabilitySpace,
            capability: abi.capability.CapabilityHandle,
        ) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.delete_capability),
                target.capability,
                capability,
                0,
            ));
        }

        fn unaryThreadOperation(number: abi.syscall.SyscallNumber, thread: Thread) Error!void {
            try objectOperation(number, thread.capability);
        }

        fn objectOperation(
            number: abi.syscall.SyscallNumber,
            capability: abi.capability.CapabilityHandle,
        ) Error!void {
            try voidResult(Transport.syscall3(@intFromEnum(number), capability, 0, 0));
        }

        fn capabilityResult(result: u32) Error!abi.capability.CapabilityHandle {
            try checkError(result);
            if (result == abi.capability.INVALID_CAPABILITY) return Error.InternalFailure;
            return result;
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
                .invalid_range => Error.InvalidRange,
                .invalid_permissions => Error.InvalidPermissions,
                .mapping_not_found => Error.MappingNotFound,
                .address_space_in_use => Error.AddressSpaceInUse,
                .unsupported => Error.Unsupported,
                .invalid_state => Error.InvalidState,
                .object_in_use => Error.ObjectInUse,
                .invalid_user_memory => Error.InvalidUserMemory,
                .internal_failure => Error.InternalFailure,
            };
        }
    };
}

const NativeTransport = struct {
    pub const syscall3 = abi.syscall.syscall3;
};

const native = ProcessManager(NativeTransport);

pub const createCapabilitySpace = native.createCapabilitySpace;
pub const createThread = native.createThread;
pub const configureThread = native.configureThread;
pub const startThread = native.startThread;
pub const suspendThread = native.suspendThread;
pub const resumeThread = native.resumeThread;
pub const terminateThread = native.terminateThread;
pub const installCapability = native.installCapability;
pub const destroyThread = native.destroyThread;
pub const destroyCapabilitySpace = native.destroyCapabilitySpace;
pub const deleteCapability = native.deleteCapability;
