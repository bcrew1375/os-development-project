//! Capabilities for threads and capability-space objects.

const abi = @import("abi");
const process = @import("../process/main.zig");
const derivation = @import("derivation.zig");
const errors = @import("errors.zig");
const space = @import("space.zig");
const storage = @import("storage.zig");

pub const CapabilityError = errors.CapabilityError;

pub fn createCapabilitySpaceCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try space.create();
    errdefer space.destroy(object_handle) catch {};
    return storage.commit(
        prepared,
        .{ .manage = true, .grant = true },
        null,
        .{ .capability_space = object_handle },
    );
}

pub fn createThreadCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try process.createThread(space_handle);
    errdefer process.thread.destroy(object_handle) catch {};
    return storage.commit(
        prepared,
        .{
            .manage = true,
            .configure = true,
            .start = true,
            .suspend_thread = true,
            .resume_thread = true,
            .terminate = true,
            .grant = true,
        },
        null,
        .{ .thread = object_handle },
    );
}

pub fn resolveCapabilitySpace(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!space.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .capability_space => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveThread(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!process.thread.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .thread => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn destroyThreadCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const object_handle = try resolveThread(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    try process.thread.destroy(object_handle);
    try storage.clear(reference);
}

pub fn destroyCapabilitySpaceCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const object_handle = try resolveCapabilitySpace(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (process.thread.referencesCapabilitySpace(object_handle)) {
        return error.CapabilitySpaceInUse;
    }
    if (try storage.activeCountIn(object_handle) != 0) {
        return error.CapabilitySpaceNotEmpty;
    }
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    try space.destroy(object_handle);
    try storage.clear(reference);
}
