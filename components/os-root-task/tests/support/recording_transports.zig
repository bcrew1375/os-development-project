const abi = @import("abi");

pub const EndpointRecordingTransport = struct {
    pub var syscall_number: u32 = 0;
    pub var arguments: [5]usize = .{ 0, 0, 0, 0, 0 };
    pub var scalar_response: u32 = abi.syscall.SYSCALL_SUCCESS;
    pub var receive_response: abi.ipc.ReceiveResult = .{ .status = abi.syscall.SYSCALL_SUCCESS };
    pub var transfer_receive_response: abi.ipc.TransferReceiveResult = .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .capability = abi.capability.INVALID_CAPABILITY,
    };

    pub var recorded_transfer_send_request: ?abi.ipc.TransferSendRequest = null;
    pub var recorded_transfer_receive_request: ?abi.ipc.TransferReceiveRequest = null;

    pub fn reset() void {
        syscall_number = 0;
        arguments = .{ 0, 0, 0, 0, 0 };
        scalar_response = abi.syscall.SYSCALL_SUCCESS;
        receive_response = .{ .status = abi.syscall.SYSCALL_SUCCESS };
        transfer_receive_response = .{
            .status = abi.syscall.SYSCALL_SUCCESS,
            .capability = abi.capability.INVALID_CAPABILITY,
        };
        recorded_transfer_send_request = null;
        recorded_transfer_receive_request = null;
    }

    pub fn syscall3(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
    ) callconv(.c) u32 {
        syscall_number = number;
        arguments = .{ argument0, argument1, argument2, 0, 0 };
        if (number == @intFromEnum(abi.syscall.SyscallNumber.endpoint_send_capability)) {
            const req_ptr: *const abi.ipc.TransferSendRequest = @ptrFromInt(argument1);
            recorded_transfer_send_request = req_ptr.*;
        }
        return scalar_response;
    }

    pub fn syscall5(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
        argument3: usize,
        argument4: usize,
    ) callconv(.c) u32 {
        syscall_number = number;
        arguments = .{ argument0, argument1, argument2, argument3, argument4 };
        return scalar_response;
    }

    pub fn syscallReceive(
        number: u32,
        endpoint: abi.capability.CapabilityHandle,
    ) abi.ipc.ReceiveResult {
        syscall_number = number;
        arguments = .{ endpoint, 0, 0, 0, 0 };
        return receive_response;
    }

    pub fn syscallTransferReceive(
        number: u32,
        endpoint: abi.capability.CapabilityHandle,
        request: *const abi.ipc.TransferReceiveRequest,
    ) abi.ipc.TransferReceiveResult {
        syscall_number = number;
        arguments = .{ endpoint, @intFromPtr(request), 0, 0, 0 };
        recorded_transfer_receive_request = request.*;
        return transfer_receive_response;
    }
};
pub const NotificationRecordingTransport = struct {
    pub var syscall_number: u32 = 0;
    pub var arguments: [3]usize = .{ 0, 0, 0 };
    pub var scalar_response: u32 = abi.syscall.SYSCALL_SUCCESS;
    pub var wait_response: abi.notification.WaitResult = .{
        .status = abi.syscall.SYSCALL_SUCCESS,
        .pending_count = 0,
        .overflowed = false,
    };

    pub fn reset() void {
        syscall_number = 0;
        arguments = .{ 0, 0, 0 };
        scalar_response = abi.syscall.SYSCALL_SUCCESS;
        wait_response = .{
            .status = abi.syscall.SYSCALL_SUCCESS,
            .pending_count = 0,
            .overflowed = false,
        };
    }

    pub fn syscall3(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
    ) callconv(.c) u32 {
        syscall_number = number;
        arguments = .{ argument0, argument1, argument2 };
        return scalar_response;
    }

    pub fn syscallNotificationWait(
        number: u32,
        notification_capability: abi.capability.CapabilityHandle,
    ) abi.notification.WaitResult {
        syscall_number = number;
        arguments = .{ notification_capability, 0, 0 };
        return wait_response;
    }
};
