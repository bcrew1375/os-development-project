//! Capability derivation, installation, traversal, and generic deletion policy.

const abi = @import("abi");
const ipc_operations = @import("../ipc/operations.zig");
const notification_operations = @import("../ipc/notification_operations.zig");
const errors = @import("errors.zig");
const space = @import("space.zig");
const storage = @import("storage.zig");

pub const CapabilityError = errors.CapabilityError;

pub const PreparedInstall = struct {
    slot: storage.PreparedSlot,
    rights: abi.capability.Rights,
    parent: storage.Reference,
    object: storage.CapabilityObject,
};

pub fn installCapability(
    source_space: space.Handle,
    target_space_capability: abi.capability.CapabilityHandle,
    source_capability: abi.capability.CapabilityHandle,
    rights: abi.capability.Rights,
) CapabilityError!abi.capability.CapabilityHandle {
    const target_space = switch ((try storage.resolve(
        source_space,
        target_space_capability,
        .{ .manage = true },
    )).object) {
        .capability_space => |handle| handle,
        else => return error.InvalidCapabilityType,
    };
    const source = try storage.resolve(source_space, source_capability, .{});
    if (!source.rights.contains(rights)) return error.InvalidCapabilityRights;
    const prepared = try storage.prepareAvailable(target_space);
    return storage.commit(prepared, rights, source.reference, source.object);
}

pub fn prepareExactInstall(
    source_space: space.Handle,
    source_capability: abi.capability.CapabilityHandle,
    target_space: space.Handle,
    destination_slot: u32,
    rights: abi.capability.Rights,
) CapabilityError!PreparedInstall {
    const source = try storage.resolve(
        source_space,
        source_capability,
        .{ .grant = true },
    );
    if (!source.rights.contains(rights)) return error.InvalidCapabilityRights;
    return .{
        .slot = try storage.prepareExact(target_space, destination_slot),
        .rights = rights,
        .parent = source.reference,
        .object = source.object,
    };
}

pub fn validateTransferSource(
    source_space: space.Handle,
    source_capability: abi.capability.CapabilityHandle,
    rights: abi.capability.Rights,
) CapabilityError!void {
    const source = try storage.resolve(
        source_space,
        source_capability,
        .{ .grant = true },
    );
    if (!source.rights.contains(rights)) return error.InvalidCapabilityRights;
}

pub fn validateExactDestination(
    target_space: space.Handle,
    destination_slot: u32,
) CapabilityError!void {
    _ = try storage.prepareExact(target_space, destination_slot);
}

pub fn commitExactInstall(prepared: PreparedInstall) abi.capability.CapabilityHandle {
    return storage.commit(
        prepared.slot,
        prepared.rights,
        prepared.parent,
        prepared.object,
    );
}

pub fn rollbackExactInstall(
    prepared: PreparedInstall,
    installed: abi.capability.CapabilityHandle,
) void {
    storage.rollback(prepared.slot, installed, prepared.parent);
}

pub fn deleteCapabilityFromSpace(
    source_space: space.Handle,
    target_space_capability: abi.capability.CapabilityHandle,
    target_capability: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const target_space = switch ((try storage.resolve(
        source_space,
        target_space_capability,
        .{ .manage = true },
    )).object) {
        .capability_space => |handle| handle,
        else => return error.InvalidCapabilityType,
    };
    try deleteCapability(target_space, target_capability);
}

pub fn deleteCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    _ = try storage.resolve(space_handle, capability_handle, .{});
    if (hasChild(reference)) return error.CapabilityHasDescendants;
    try ipc_operations.cancelAuthorization(.{
        .capability_space_handle = space_handle,
        .capability_handle = capability_handle,
    });
    try notification_operations.cancelAuthorization(.{
        .capability_space_handle = space_handle,
        .capability_handle = capability_handle,
    });
    try storage.clear(reference);
}

pub fn hasChild(parent: storage.Reference) bool {
    for (0..space.MAX_CAPABILITY_SPACES) |table_index| {
        for (0..storage.MAX_CAPABILITIES) |slot_index| {
            const candidate = storage.activeReferenceAt(table_index, slot_index) orelse continue;
            const candidate_slot = storage.resolve(
                candidate.space_handle,
                candidate.capability_handle,
                .{},
            ) catch continue;
            if (candidate_slot.parent) |candidate_parent| {
                if (storage.equal(candidate_parent, parent)) return true;
            }
        }
    }
    return false;
}

pub fn leafDescendant(ancestor: storage.Reference) ?storage.Reference {
    for (0..space.MAX_CAPABILITY_SPACES) |table_index| {
        for (0..storage.MAX_CAPABILITIES) |slot_index| {
            const candidate = storage.activeReferenceAt(table_index, slot_index) orelse continue;
            if (storage.equal(candidate, ancestor) or !isDescendant(candidate, ancestor)) continue;
            if (!hasChild(candidate)) return candidate;
        }
    }
    return null;
}

fn isDescendant(
    descendant: storage.Reference,
    ancestor: storage.Reference,
) bool {
    var current = descendant;
    var steps: usize = 0;
    while (steps < storage.MAX_CAPABILITIES * space.MAX_CAPABILITY_SPACES) : (steps += 1) {
        const current_slot = storage.resolve(
            current.space_handle,
            current.capability_handle,
            .{},
        ) catch return false;
        const parent = current_slot.parent orelse return false;
        if (storage.equal(parent, ancestor)) return true;
        current = parent;
    }
    return false;
}
