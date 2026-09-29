//! Capabilities for endpoints, notifications, and interrupt sources.

const abi = @import("abi");
const arch = @import("arch");
const endpoint = @import("../ipc/endpoint.zig");
const interrupt_source = @import("../ipc/interrupt_source.zig");
const ipc_operations = @import("../ipc/operations.zig");
const notification = @import("../ipc/notification.zig");
const notification_operations = @import("../ipc/notification_operations.zig");
const derivation = @import("derivation.zig");
const errors = @import("errors.zig");
const space = @import("space.zig");
const storage = @import("storage.zig");

pub const CapabilityError = errors.CapabilityError;

pub fn createEndpointCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try endpoint.create();
    errdefer endpoint.destroy(object_handle) catch {};
    return storage.commit(
        prepared,
        .{ .manage = true, .send = true, .receive = true, .grant = true },
        null,
        .{ .endpoint = object_handle },
    );
}

pub fn createNotificationCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try notification.create();
    errdefer notification.destroy(object_handle) catch {};
    return storage.commit(
        prepared,
        .{
            .manage = true,
            .wait = true,
            .signal = true,
            .bind = true,
            .grant = true,
        },
        null,
        .{ .notification = object_handle },
    );
}

pub fn createInterruptSourceCapability(
    space_handle: space.Handle,
    kind: abi.notification.InterruptSourceKind,
    parameter: u32,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try interrupt_source.create(kind, parameter);
    errdefer interrupt_source.destroy(object_handle) catch {};
    return storage.commit(
        prepared,
        .{
            .manage = true,
            .bind = true,
            .acknowledge = true,
            .grant = true,
        },
        null,
        .{ .interrupt_source = object_handle },
    );
}

pub fn resolveEndpoint(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!endpoint.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .endpoint => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveNotification(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!notification.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .notification => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveInterruptSource(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!interrupt_source.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .interrupt_source => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn sendEndpointMessage(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    message: abi.ipc.Message,
) CapabilityError!void {
    try endpoint.send(try resolveEndpoint(
        space_handle,
        capability_handle,
        .{ .send = true },
    ), message);
}

pub fn receiveEndpointMessage(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!abi.ipc.Message {
    return endpoint.receive(try resolveEndpoint(
        space_handle,
        capability_handle,
        .{ .receive = true },
    ));
}

pub fn destroyEndpointCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const object_handle = try resolveEndpoint(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    try ipc_operations.destroy(object_handle);
    try storage.clear(reference);
}

pub fn destroyNotificationCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const object_handle = try resolveNotification(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    try notification_operations.destroyNotification(object_handle);
    try storage.clear(reference);
}

pub fn destroyInterruptSourceCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const object_handle = try resolveInterruptSource(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    const state = try interrupt_source.get(object_handle);
    arch.interrupts.maskInterruptSource(state.kind);
    try interrupt_source.destroy(object_handle);
    try storage.clear(reference);
}

pub fn resetForTest() void {
    endpoint.resetForTest();
    notification.resetForTest();
    interrupt_source.resetForTest();
}
