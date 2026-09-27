//! Root-task wrappers for counted notifications and logical interrupt sources.

const abi = @import("abi");

pub const Notification = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const InterruptSource = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const Error = error{
    InvalidCapability,
    InsufficientRights,
    OutOfResources,
    Unsupported,
    InvalidState,
    ObjectInUse,
    Canceled,
    InternalFailure,
};

pub fn NotificationManager(comptime Transport: type) type {
    return struct {
        pub fn createNotification() Error!Notification {
            return .{ .capability = try capabilityResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_notification),
                0,
                0,
                0,
            )) };
        }

        pub fn destroyNotification(notification: Notification) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.destroy_notification),
                notification.capability,
                0,
                0,
            ));
        }

        pub fn wait(notification: Notification) Error!abi.notification.WaitResult {
            const result = Transport.syscallNotificationWait(
                @intFromEnum(abi.syscall.SyscallNumber.notification_wait),
                notification.capability,
            );
            try checkError(result.status);
            if (result.status != abi.syscall.SYSCALL_SUCCESS) return Error.InternalFailure;
            return result;
        }

        pub fn signal(notification: Notification) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.notification_signal),
                notification.capability,
                0,
                0,
            ));
        }

        pub fn createInterruptSource(
            kind: abi.notification.InterruptSourceKind,
            parameter: u32,
        ) Error!InterruptSource {
            return .{ .capability = try capabilityResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_interrupt_source),
                @intFromEnum(kind),
                parameter,
                0,
            )) };
        }

        pub fn destroyInterruptSource(source: InterruptSource) Error!void {
            try sourceOperation(.destroy_interrupt_source, source);
        }

        pub fn bind(source: InterruptSource, notification: Notification) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.bind_interrupt_source),
                source.capability,
                notification.capability,
                0,
            ));
        }

        pub fn unbind(source: InterruptSource) Error!void {
            try sourceOperation(.unbind_interrupt_source, source);
        }

        pub fn acknowledge(source: InterruptSource) Error!void {
            try sourceOperation(.acknowledge_interrupt_source, source);
        }

        fn sourceOperation(
            number: abi.syscall.SyscallNumber,
            source: InterruptSource,
        ) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(number),
                source.capability,
                0,
                0,
            ));
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
                .unsupported => Error.Unsupported,
                .invalid_state => Error.InvalidState,
                .object_in_use => Error.ObjectInUse,
                .notification_canceled => Error.Canceled,
                .invalid_range,
                .invalid_permissions,
                .mapping_not_found,
                .address_space_in_use,
                .internal_failure,
                .invalid_user_memory,
                .endpoint_empty,
                .endpoint_full,
                .endpoint_canceled,
                .capability_slot_occupied,
                .invalid_capability_slot,
                => Error.InternalFailure,
            };
        }
    };
}

const NativeTransport = struct {
    pub const syscall3 = abi.syscall.syscall3;
    pub const syscallNotificationWait = abi.syscall.syscallNotificationWait;
};

const native = NotificationManager(NativeTransport);

pub const createNotification = native.createNotification;
pub const destroyNotification = native.destroyNotification;
pub const wait = native.wait;
pub const signal = native.signal;
pub const createInterruptSource = native.createInterruptSource;
pub const destroyInterruptSource = native.destroyInterruptSource;
pub const bind = native.bind;
pub const unbind = native.unbind;
pub const acknowledge = native.acknowledge;
