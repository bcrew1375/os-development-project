const abi = @import("abi");
const notification = @import("notification");
const std = @import("std");

const NotificationRecordingTransport = @import("support/recording_transports.zig").NotificationRecordingTransport;
const notification_manager = notification.NotificationManager(NotificationRecordingTransport);

test "notification manager emits lifecycle wait binding and acknowledgment syscalls" {
    NotificationRecordingTransport.reset();
    NotificationRecordingTransport.scalar_response = 81;
    const object = try notification_manager.createNotification();
    try std.testing.expectEqual(@as(u32, 81), object.capability);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.create_notification),
        NotificationRecordingTransport.syscall_number,
    );

    NotificationRecordingTransport.scalar_response = 82;
    const source = try notification_manager.createInterruptSource(.timer, 1000);
    try std.testing.expectEqual(@as(u32, 82), source.capability);
    try std.testing.expectEqual(
        [_]usize{ @intFromEnum(abi.notification.InterruptSourceKind.timer), 1000, 0 },
        NotificationRecordingTransport.arguments,
    );

    NotificationRecordingTransport.scalar_response = abi.syscall.SYSCALL_SUCCESS;
    try notification_manager.bind(source, object);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.bind_interrupt_source),
        NotificationRecordingTransport.syscall_number,
    );
    try std.testing.expectEqual(
        [_]usize{ source.capability, object.capability, 0 },
        NotificationRecordingTransport.arguments,
    );

    NotificationRecordingTransport.wait_response = .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .pending_count = 3,
        .overflowed = true,
    };
    const pending = try notification_manager.wait(object);
    try std.testing.expectEqual(@as(u32, 3), pending.pending_count);
    try std.testing.expect(pending.overflowed);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.notification_wait),
        NotificationRecordingTransport.syscall_number,
    );

    try notification_manager.acknowledge(source);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.acknowledge_interrupt_source),
        NotificationRecordingTransport.syscall_number,
    );
    try notification_manager.unbind(source);
    try notification_manager.destroyInterruptSource(source);
    try notification_manager.destroyNotification(object);
}

test "notification manager decodes cancellation and object-state errors" {
    const object = notification.Notification{ .capability = 91 };
    NotificationRecordingTransport.reset();
    NotificationRecordingTransport.wait_response.status =
        abi.syscall.errorResult(.notification_canceled);
    try std.testing.expectError(error.Canceled, notification_manager.wait(object));

    NotificationRecordingTransport.reset();
    NotificationRecordingTransport.scalar_response = abi.syscall.errorResult(.object_in_use);
    try std.testing.expectError(error.ObjectInUse, notification_manager.destroyNotification(object));
}
