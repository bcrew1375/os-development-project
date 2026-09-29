//! Production root-task smoke scenarios, kept separate from bootstrap mechanics.

const abi = @import("abi");
const ipc = @import("ipc");
const memory_management = @import("memory_management");
const notification = @import("notification");
const process_management = @import("process_management");
const std = @import("std");

const child_process = process_management.child_process;
const memory_manager = memory_management.operations;
const PhysicalRangeAllocator = memory_management.PhysicalRangeAllocator;

pub fn runEchoService(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    image: []const u8,
) !void {
    const endpoint_manager = ipc.EndpointManager(Environment);
    const request_endpoint = try endpoint_manager.createEndpoint();
    errdefer endpoint_manager.destroyEndpoint(request_endpoint) catch {};
    const reply_endpoint = try endpoint_manager.createEndpoint();
    errdefer endpoint_manager.destroyEndpoint(reply_endpoint) catch {};
    try runEchoServiceInstance(
        Environment,
        allocator,
        root_address_space,
        image,
        request_endpoint,
        reply_endpoint,
    );
    try runEchoServiceInstance(
        Environment,
        allocator,
        root_address_space,
        image,
        request_endpoint,
        reply_endpoint,
    );
    try endpoint_manager.destroyEndpoint(reply_endpoint);
    try endpoint_manager.destroyEndpoint(request_endpoint);
    Environment.debugWrite(abi.system_smoke.ECHO_SERVICE_RESTARTED);
}

pub fn runNotification(comptime Environment: type) !void {
    const manager = notification.NotificationManager(Environment);
    const object = try manager.createNotification();
    var object_owned = true;
    errdefer if (object_owned) manager.destroyNotification(object) catch {};
    const source = try manager.createInterruptSource(.timer, 1000);
    var source_owned = true;
    errdefer if (source_owned) manager.destroyInterruptSource(source) catch {};
    Environment.debugWrite(abi.system_smoke.NOTIFICATION_OBJECTS_CREATED);

    try manager.bind(source, object);
    var bound = true;
    errdefer if (bound) manager.unbind(source) catch {};
    Environment.debugWrite(abi.system_smoke.TIMER_NOTIFICATION_BOUND);
    const result = try manager.wait(object);
    if (result.pending_count == 0) return error.EmptyNotification;
    Environment.debugWrite(abi.system_smoke.TIMER_NOTIFICATION_RECEIVED);

    try manager.acknowledge(source);
    Environment.debugWrite(abi.system_smoke.TIMER_NOTIFICATION_ACKNOWLEDGED);
    try manager.unbind(source);
    bound = false;
    try manager.destroyInterruptSource(source);
    source_owned = false;
    try manager.destroyNotification(object);
    object_owned = false;
    Environment.debugWrite(abi.system_smoke.NOTIFICATION_OBJECTS_DESTROYED);
}

pub fn runChildren(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    module: abi.boot_info.BootModuleInfo,
) !void {
    const image = bootModuleBytes(Environment, module) orelse return error.InvalidBootModule;

    const endpoint_manager = ipc.EndpointManager(Environment);
    const request_endpoint = try endpoint_manager.createEndpoint();
    var request_endpoint_owned = true;
    errdefer if (request_endpoint_owned) endpoint_manager.destroyEndpoint(request_endpoint) catch {};
    const reply_endpoint = try endpoint_manager.createEndpoint();
    var reply_endpoint_owned = true;
    errdefer if (reply_endpoint_owned) endpoint_manager.destroyEndpoint(reply_endpoint) catch {};
    var ipc_child = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .ipc_ping_pong },
        request_endpoint.capability,
        reply_endpoint.capability,
    );
    errdefer ipc_child.destroy(Environment, allocator, root_address_space) catch {};
    Environment.debugWrite(abi.system_smoke.IPC_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_IPC_CHILD_BLOCKED);
    try endpoint_manager.send(request_endpoint, abi.system_smoke.IPC_REQUEST);
    Environment.debugWrite(abi.system_smoke.IPC_REQUEST_SENT);
    const reply = try endpoint_manager.receive(reply_endpoint);
    if (!std.meta.eql(reply, abi.system_smoke.IPC_REPLY)) return error.InvalidIpcReply;
    Environment.debugWrite(abi.system_smoke.IPC_REPLY_VERIFIED);
    try ipc_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.IPC_CHILD_DESTROYED);
    try endpoint_manager.destroyEndpoint(reply_endpoint);
    reply_endpoint_owned = false;
    try endpoint_manager.destroyEndpoint(request_endpoint);
    request_endpoint_owned = false;
    Environment.debugWrite(abi.system_smoke.IPC_ENDPOINTS_DESTROYED);

    try runCapabilityTransfer(Environment, allocator, root_address_space, image);

    var fault_child = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .invalid_opcode },
        null,
        null,
    );
    Environment.debugWrite(abi.system_smoke.FAULT_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_FAULT_CHILD_YIELD);
    try yieldSuccessfully(Environment);
    try fault_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.FAULT_CHILD_DESTROYED);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_CHILDREN);
    try runManagedProcesses(Environment, allocator, root_address_space, image);
}

pub fn bootModuleBytes(
    comptime Environment: type,
    module: abi.boot_info.BootModuleInfo,
) ?[]const u8 {
    const size = std.math.cast(usize, module.size) orelse return null;
    const virtual_start = std.math.cast(usize, module.virtual_start) orelse return null;
    const address = if (@hasDecl(Environment, "mappedMemoryAddress"))
        Environment.mappedMemoryAddress(virtual_start, size) orelse return null
    else
        virtual_start;
    const pointer: [*]const u8 = @ptrFromInt(address);
    return pointer[0..size];
}

fn runEchoServiceInstance(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    image: []const u8,
    request_endpoint: ipc.Endpoint,
    reply_endpoint: ipc.Endpoint,
) !void {
    const endpoint_manager = ipc.EndpointManager(Environment);
    var service = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .service_echo },
        request_endpoint.capability,
        reply_endpoint.capability,
    );
    errdefer service.destroy(Environment, allocator, root_address_space) catch {};
    Environment.debugWrite(abi.system_smoke.ECHO_SERVICE_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    try endpoint_manager.send(request_endpoint, abi.system_smoke.ECHO_SERVICE_REQUEST);
    Environment.debugWrite(abi.system_smoke.ECHO_SERVICE_REQUEST_SENT);
    const reply = try endpoint_manager.receive(reply_endpoint);
    if (!std.meta.eql(reply, abi.system_smoke.ECHO_SERVICE_REPLY)) return error.InvalidChildMessage;
    Environment.debugWrite(abi.system_smoke.ECHO_SERVICE_REPLY_VERIFIED);
    try service.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.ECHO_SERVICE_CHILD_DESTROYED);
}

fn runManagedProcesses(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    image: []const u8,
) !void {
    const ManagedProcess = process_management.managed_process.ManagedProcess;

    var exit_child = try ManagedProcess.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        1,
        .exit_success,
    );
    errdefer cleanupManagedProcess(Environment, &exit_child, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_CHILD_STARTED);
    try exit_child.observeStartup(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_STARTUP_OBSERVED);
    try exit_child.transferServiceCapability(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_SERVICE_TRANSFERRED);
    try exit_child.observeServiceReady(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_SERVICE_READY);
    _ = try exit_child.observeTerminal(Environment);
    Environment.debugWrite(abi.system_smoke.CHILD_EXIT_SUCCESS);
    try exit_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_CHILD_DESTROYED);

    var fault_child = try ManagedProcess.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        2,
        .fault_invalid_opcode,
    );
    errdefer cleanupManagedProcess(Environment, &fault_child, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_CHILD_STARTED);
    try fault_child.observeStartup(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_STARTUP_OBSERVED);
    try fault_child.transferServiceCapability(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_SERVICE_TRANSFERRED);
    try fault_child.observeServiceReady(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_SERVICE_READY);
    _ = try fault_child.observeTerminal(Environment);
    Environment.debugWrite(abi.system_smoke.CHILD_FAULT_INVALID_OPCODE);
    try fault_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_CHILD_DESTROYED);
}

fn cleanupManagedProcess(
    comptime Environment: type,
    managed: *process_management.managed_process.ManagedProcess,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
) void {
    if (managed.state == .terminal_observed) {
        managed.destroy(Environment, allocator, root_address_space) catch {};
    }
}

fn runCapabilityTransfer(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    image: []const u8,
) !void {
    const endpoint_manager = ipc.EndpointManager(Environment);
    const process_manager = process_management.ProcessManager(Environment);

    const transfer_endpoint = try endpoint_manager.createEndpoint();
    var transfer_endpoint_owned = true;
    errdefer if (transfer_endpoint_owned) endpoint_manager.destroyEndpoint(transfer_endpoint) catch {};
    const acknowledgment_endpoint = try endpoint_manager.createEndpoint();
    var acknowledgment_endpoint_owned = true;
    errdefer if (acknowledgment_endpoint_owned) endpoint_manager.destroyEndpoint(acknowledgment_endpoint) catch {};
    var child = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .capability_transfer },
        transfer_endpoint.capability,
        null,
    );
    var child_owned = true;
    errdefer if (child_owned) child.destroy(Environment, allocator, root_address_space) catch {};
    const child_space = child.capability_space orelse return error.MissingChildCapabilitySpace;
    const transferred_capability = abi.capability.makeCapabilityHandle(
        abi.system_smoke.CAPABILITY_TRANSFER_DESTINATION_SLOT,
        1,
    );
    var transferred_capability_owned = false;
    errdefer if (transferred_capability_owned) {
        process_manager.deleteCapability(child_space, transferred_capability) catch {};
    };

    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_TRANSFER_CHILD_BLOCKED);
    try endpoint_manager.sendCapability(
        transfer_endpoint,
        acknowledgment_endpoint.capability,
        .{ .send = true },
        abi.system_smoke.CAPABILITY_TRANSFER_MESSAGE,
    );
    transferred_capability_owned = true;
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_SENT);
    const acknowledgment = try endpoint_manager.receive(acknowledgment_endpoint);
    if (acknowledgment.words[0] != abi.system_smoke.CAPABILITY_TRANSFER_ACK.words[0] or
        acknowledgment.words[1] != transferred_capability or
        acknowledgment.words[2] != abi.system_smoke.CAPABILITY_TRANSFER_ACK.words[2])
    {
        return error.InvalidCapabilityTransferAcknowledgment;
    }
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_ACK_VERIFIED);

    try process_manager.deleteCapability(child_space, transferred_capability);
    transferred_capability_owned = false;
    try child.destroy(Environment, allocator, root_address_space);
    child_owned = false;
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_CHILD_DESTROYED);
    try endpoint_manager.destroyEndpoint(acknowledgment_endpoint);
    acknowledgment_endpoint_owned = false;
    try endpoint_manager.destroyEndpoint(transfer_endpoint);
    transfer_endpoint_owned = false;
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_ENDPOINTS_DESTROYED);
}

fn yieldSuccessfully(comptime Environment: type) !void {
    if (Environment.yield() != abi.syscall.SYSCALL_SUCCESS) return error.YieldFailed;
}
