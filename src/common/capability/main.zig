//! Kernel-side capability table for protected object access.

const abi = @import("abi");
const process = @import("../process/main.zig");

/// Errors produced while creating or resolving capabilities.
pub const CapabilityError = error{
    OutOfCapabilities,
    InvalidCapability,
    CapabilityOwnerMismatch,
    InvalidCapabilityType,
    InsufficientCapabilityRights,
} || process.ProcessError;

const MAX_CAPABILITIES = 16;

const CapabilityObject = union(enum) {
    address_space: process.AddressSpaceHandle,
    memory_object: process.MemoryObjectHandle,
};

const CapabilitySlot = struct {
    generation: u32 = 1,
    owner_process_handle: process.ProcessHandle = 0,
    rights: abi.capability.Rights = .{},
    object: ?CapabilityObject = null,
    used: bool = false,
    retired: bool = false,
};

var capabilitySlots: [MAX_CAPABILITIES]CapabilitySlot = [_]CapabilitySlot{.{}} ** MAX_CAPABILITIES;

/// Creates a managed address-space capability owned by `owner_process_handle`.
pub fn createAddressSpaceCapability(owner_process_handle: process.ProcessHandle) CapabilityError!abi.capability.CapabilityHandle {
    const slot_index = findFreeCapabilitySlot() orelse return CapabilityError.OutOfCapabilities;
    const slot = &capabilitySlots[slot_index];
    const address_space_handle = try process.createAddressSpaceForOwner(owner_process_handle);

    return initializeCapabilitySlot(slot_index, slot, owner_process_handle, .{
        .manage = true,
        .read = true,
        .write = true,
    }, .{ .address_space = address_space_handle });
}

/// Installs a capability for a bootstrap-created address-space root.
pub fn registerAddressSpaceRootCapability(
    owner_process_handle: process.ProcessHandle,
    hardware_root: @import("arch").AddressSpaceRoot,
) CapabilityError!abi.capability.CapabilityHandle {
    const slot_index = findFreeCapabilitySlot() orelse return CapabilityError.OutOfCapabilities;
    const address_space_handle = try process.registerAddressSpaceRootForOwner(
        owner_process_handle,
        hardware_root,
    );
    return initializeCapabilitySlot(
        slot_index,
        &capabilitySlots[slot_index],
        owner_process_handle,
        .{ .manage = true, .read = true, .write = true },
        .{ .address_space = address_space_handle },
    );
}

/// Finds the owner's capability naming a specific address-space object.
pub fn findAddressSpaceCapability(
    owner_process_handle: process.ProcessHandle,
    address_space_handle: process.AddressSpaceHandle,
) CapabilityError!abi.capability.CapabilityHandle {
    for (capabilitySlots, 0..) |slot, slot_index| {
        if (!slot.used or slot.owner_process_handle != owner_process_handle) continue;
        const object = slot.object orelse continue;
        switch (object) {
            .address_space => |handle| if (handle == address_space_handle) {
                return abi.capability.makeCapabilityHandle(@intCast(slot_index), slot.generation);
            },
            else => {},
        }
    }
    return CapabilityError.InvalidCapability;
}

/// Destroys an address-space object and invalidates its naming capability.
pub fn destroyAddressSpaceCapability(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const address_space_handle = try resolveAddressSpace(
        owner_process_handle,
        capability_handle,
        .{ .manage = true },
    );
    try process.destroyAddressSpace(address_space_handle);
    try deleteCapability(owner_process_handle, capability_handle);
}

/// Creates a managed memory-object capability owned by `owner_process_handle`.
pub fn createMemoryObjectCapability(owner_process_handle: process.ProcessHandle, size_in_bytes: u64) CapabilityError!abi.capability.CapabilityHandle {
    const slot_index = findFreeCapabilitySlot() orelse return CapabilityError.OutOfCapabilities;
    const slot = &capabilitySlots[slot_index];
    const memory_object_handle = try process.createMemoryObjectForOwner(owner_process_handle, size_in_bytes);

    return initializeCapabilitySlot(slot_index, slot, owner_process_handle, .{
        .manage = true,
        .read = true,
        .write = true,
        .execute = true,
    }, .{ .memory_object = memory_object_handle });
}

/// Resolves an address-space capability after checking ownership and rights.
pub fn resolveAddressSpace(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
    required_rights: abi.capability.Rights,
) CapabilityError!process.AddressSpaceHandle {
    const slot = try resolveCapabilitySlot(owner_process_handle, capability_handle, required_rights);
    return switch (slot.object.?) {
        .address_space => |address_space_handle| address_space_handle,
        else => CapabilityError.InvalidCapabilityType,
    };
}

/// Resolves a memory-object capability after checking ownership and rights.
pub fn resolveMemoryObject(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
    required_rights: abi.capability.Rights,
) CapabilityError!process.MemoryObjectHandle {
    const slot = try resolveCapabilitySlot(owner_process_handle, capability_handle, required_rights);
    return switch (slot.object.?) {
        .memory_object => |memory_object_handle| memory_object_handle,
        else => CapabilityError.InvalidCapabilityType,
    };
}

/// Deletes a capability authority without destroying its referenced kernel object.
pub fn deleteCapability(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    _ = try resolveCapabilitySlot(owner_process_handle, capability_handle, .{});
    const slot_index = abi.capability.capabilitySlotIndex(capability_handle);

    const mutable_slot = &capabilitySlots[slot_index];
    mutable_slot.used = false;
    mutable_slot.owner_process_handle = 0;
    mutable_slot.rights = .{};
    mutable_slot.object = null;
    if (mutable_slot.generation == abi.capability.MAX_CAPABILITY_GENERATION) {
        mutable_slot.retired = true;
    } else {
        mutable_slot.generation += 1;
    }
}

fn initializeCapabilitySlot(
    slot_index: usize,
    slot: *CapabilitySlot,
    owner_process_handle: process.ProcessHandle,
    rights: abi.capability.Rights,
    object: CapabilityObject,
) abi.capability.CapabilityHandle {
    slot.* = .{
        .generation = slot.generation,
        .owner_process_handle = owner_process_handle,
        .rights = rights,
        .object = object,
        .used = true,
        .retired = false,
    };

    return abi.capability.makeCapabilityHandle(@intCast(slot_index), slot.generation);
}

fn resolveCapabilitySlot(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
    required_rights: abi.capability.Rights,
) CapabilityError!*const CapabilitySlot {
    const parts = abi.capability.decodeCapabilityHandle(capability_handle) orelse return CapabilityError.InvalidCapability;
    if (parts.slot_index >= capabilitySlots.len) return CapabilityError.InvalidCapability;
    const slot = &capabilitySlots[parts.slot_index];
    if (!slot.used or slot.generation != parts.generation) return CapabilityError.InvalidCapability;
    if (slot.owner_process_handle != owner_process_handle) return CapabilityError.CapabilityOwnerMismatch;
    if (!slot.rights.contains(required_rights)) return CapabilityError.InsufficientCapabilityRights;
    return slot;
}

fn findFreeCapabilitySlot() ?usize {
    for (capabilitySlots, 0..) |slot, index| {
        if (!slot.used and !slot.retired) return index;
    }
    return null;
}

/// Resets all capability table state for unit tests.
pub fn resetForTest() void {
    for (&capabilitySlots) |*slot| {
        slot.* = .{};
    }
}
