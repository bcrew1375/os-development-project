//! Central syscall-number dispatch.

const abi = @import("abi");
const process = @import("../process/main.zig");
const ipc = @import("ipc_operations.zig");
const memory = @import("memory_operations.zig");
const process_operations = @import("process_operations.zig");
const types = @import("types.zig");

const Request = types.Request;
const Result = types.Result;

/// Dispatches policy through a statically supplied service implementation.
pub fn dispatchWithServices(
    comptime Services: type,
    caller_capability_space: process.thread.CapabilitySpaceHandle,
    request: Request,
) Result {
    const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(request.number);
    const caller = caller_capability_space;
    const arguments = request.arguments;
    return switch (syscall_number) {
        .debug_write => .{ .debug_write = .{
            .address = arguments[0],
            .length = arguments[1],
        } },
        .exit => .{ .exit = .{ .status = arguments[0] } },
        .yield => .yield,
        .current_address_space => memory.currentAddressSpace(Services, caller),
        .create_address_space => memory.createAddressSpace(Services, caller),
        .map_memory => memory.mapMemory(Services, caller, arguments),
        .create_memory_object => memory.createMemoryObject(Services, caller, arguments[0]),
        .map_memory_object => memory.mapMemoryObject(Services, caller, arguments),
        .protect_address_space => memory.protectAddressSpace(Services, caller, arguments),
        .query_address_space => memory.queryAddressSpace(Services, caller, arguments),
        .unmap_address_space => memory.unmapAddressSpace(Services, caller, arguments),
        .destroy_address_space => memory.destroyAddressSpace(Services, caller, arguments[0]),
        .retype_untyped_memory => memory.retypeUntypedMemory(Services, caller, arguments),
        .delete_physical_memory => memory.deletePhysicalMemory(Services, caller, arguments[0]),
        .revoke_physical_memory => memory.revokePhysicalMemory(Services, caller, arguments[0]),
        .destroy_memory_object => memory.destroyMemoryObject(Services, caller, arguments[0]),
        .create_capability_space => process_operations.createCapabilitySpace(Services, caller),
        .create_thread => process_operations.createThread(Services, caller),
        .configure_thread => process_operations.configureThread(Services, caller, arguments),
        .start_thread => process_operations.controlThread(Services, caller, arguments[0], .start_thread),
        .suspend_thread => process_operations.controlThread(Services, caller, arguments[0], .suspend_thread),
        .resume_thread => process_operations.controlThread(Services, caller, arguments[0], .resume_thread),
        .terminate_thread => process_operations.terminateThread(Services, caller, arguments),
        .fault_reply => process_operations.faultReply(Services, caller, arguments),
        .install_capability => process_operations.installCapability(Services, caller, arguments),
        .destroy_thread => process_operations.destroyObjectCapability(Services, caller, arguments[0], .destroy_thread),
        .destroy_capability_space => process_operations.destroyObjectCapability(Services, caller, arguments[0], .destroy_capability_space),
        .delete_capability => process_operations.deleteInstalledCapability(Services, caller, arguments),
        .create_endpoint => ipc.createEndpoint(Services, caller),
        .destroy_endpoint => ipc.destroyEndpoint(Services, caller, arguments[0]),
        .endpoint_send => ipc.sendEndpoint(Services, caller, arguments),
        .endpoint_receive => ipc.receiveEndpoint(Services, caller, arguments[0]),
        .endpoint_send_capability => ipc.sendEndpointCapability(Services, caller, arguments),
        .endpoint_receive_capability => ipc.receiveEndpointCapability(Services, caller, arguments),
        .create_notification => ipc.createNotification(Services, caller),
        .destroy_notification => ipc.destroyNotification(Services, caller, arguments[0]),
        .notification_wait => ipc.waitNotification(Services, caller, arguments[0]),
        .notification_signal => ipc.signalNotification(Services, caller, arguments[0]),
        .create_interrupt_source => ipc.createInterruptSource(Services, caller, arguments),
        .destroy_interrupt_source => ipc.destroyInterruptSource(Services, caller, arguments[0]),
        .bind_interrupt_source => ipc.bindInterruptSource(Services, caller, arguments),
        .unbind_interrupt_source => ipc.unbindInterruptSource(Services, caller, arguments[0]),
        .acknowledge_interrupt_source => ipc.acknowledgeInterruptSource(Services, caller, arguments[0]),
        _ => .{ .returned = abi.syscall.errorResult(.unsupported) },
    };
}
