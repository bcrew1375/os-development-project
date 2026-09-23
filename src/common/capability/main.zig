//! Kernel-side capability table for protected object access.

const abi = @import("abi");
const arch = @import("arch");
const physical_memory_authority = @import("../memory_management/physical_memory_authority.zig");
const process = @import("../process/main.zig");
const std = @import("std");

/// Errors produced while creating or resolving capabilities.
pub const CapabilityError = error{
    OutOfCapabilities,
    InvalidCapability,
    CapabilityOwnerMismatch,
    InvalidCapabilityType,
    InsufficientCapabilityRights,
    CapabilityHasDescendants,
    InvalidCapabilityRights,
} || process.ProcessError || physical_memory_authority.Error;

pub const MAX_CAPABILITIES: usize = abi.capability.MAX_CAPABILITY_SLOT_INDEX + 1;

const CapabilityObject = union(enum) {
    address_space: process.AddressSpaceHandle,
    memory_object: process.MemoryObjectHandle,
    untyped_memory: physical_memory_authority.Handle,
    physical_frame: physical_memory_authority.Handle,
};

const CapabilitySlot = struct {
    generation: u32 = 1,
    owner_process_handle: process.ProcessHandle = 0,
    rights: abi.capability.Rights = .{},
    parent: abi.capability.CapabilityHandle = abi.capability.INVALID_CAPABILITY,
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

    return initializeCapabilitySlot(
        slot_index,
        slot,
        owner_process_handle,
        .{ .manage = true, .read = true, .write = true },
        abi.capability.INVALID_CAPABILITY,
        .{ .address_space = address_space_handle },
    );
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
        abi.capability.INVALID_CAPABILITY,
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

    return initializeCapabilitySlot(
        slot_index,
        slot,
        owner_process_handle,
        .{ .manage = true, .read = true, .write = true, .execute = true },
        abi.capability.INVALID_CAPABILITY,
        .{ .memory_object = memory_object_handle },
    );
}

/// Creates a physical-memory authority object and installs its owning capability.
pub fn createUntypedMemoryCapability(
    owner_process_handle: process.ProcessHandle,
    physical_start: u64,
    size_in_bytes: u64,
    attributes: u32,
    page_size: u64,
) CapabilityError!abi.capability.CapabilityHandle {
    const slot_index = findFreeCapabilitySlot() orelse return CapabilityError.OutOfCapabilities;
    const authority_handle = try physical_memory_authority.createRoot(
        physical_start,
        size_in_bytes,
        attributes,
        page_size,
    );
    errdefer physical_memory_authority.destroyBootstrapRoot(authority_handle) catch {};

    return initializeCapabilitySlot(
        slot_index,
        &capabilitySlots[slot_index],
        owner_process_handle,
        .{ .manage = true, .read = true, .write = true, .execute = true },
        abi.capability.INVALID_CAPABILITY,
        .{ .untyped_memory = authority_handle },
    );
}

/// Retypes part of an untyped authority and atomically publishes its capability.
pub fn retypeUntypedMemoryCapability(
    owner_process_handle: process.ProcessHandle,
    source_capability: abi.capability.CapabilityHandle,
    offset: u64,
    page_count: u32,
    target_type: abi.capability.ObjectType,
    rights: abi.capability.Rights,
) CapabilityError!abi.capability.CapabilityHandle {
    const source_slot = try resolveCapabilitySlot(
        owner_process_handle,
        source_capability,
        .{ .manage = true },
    );
    if (!source_slot.rights.contains(rights)) return CapabilityError.InvalidCapabilityRights;
    const source_authority = switch (source_slot.object.?) {
        .untyped_memory => |handle| handle,
        else => return CapabilityError.InvalidCapabilityType,
    };
    const target_kind: physical_memory_authority.Kind = switch (target_type) {
        .untyped_memory => .untyped_memory,
        .physical_frame => .physical_frame,
        else => return CapabilityError.InvalidCapabilityType,
    };

    const slot_index = findFreeCapabilitySlot() orelse return CapabilityError.OutOfCapabilities;
    if (physical_memory_authority.availableCount() == 0) {
        return CapabilityError.OutOfAuthorities;
    }
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const size_in_bytes = std.math.mul(u64, page_count, page_size) catch {
        return physical_memory_authority.Error.RangeOverflow;
    };
    const authority_handle = try physical_memory_authority.derive(
        source_authority,
        offset,
        size_in_bytes,
        target_kind,
        page_size,
    );
    errdefer physical_memory_authority.delete(authority_handle) catch {};

    const object: CapabilityObject = switch (target_kind) {
        .untyped_memory => .{ .untyped_memory = authority_handle },
        .physical_frame => .{ .physical_frame = authority_handle },
    };
    return initializeCapabilitySlot(
        slot_index,
        &capabilitySlots[slot_index],
        owner_process_handle,
        rights,
        source_capability,
        object,
    );
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

/// Resolves a physical-memory authority capability after ownership and rights checks.
pub fn resolveUntypedMemory(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
    required_rights: abi.capability.Rights,
) CapabilityError!physical_memory_authority.Handle {
    const slot = try resolveCapabilitySlot(owner_process_handle, capability_handle, required_rights);
    return switch (slot.object.?) {
        .untyped_memory => |authority_handle| authority_handle,
        else => CapabilityError.InvalidCapabilityType,
    };
}

/// Resolves typed physical-frame authority after ownership and rights checks.
pub fn resolvePhysicalFrame(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
    required_rights: abi.capability.Rights,
) CapabilityError!physical_memory_authority.Handle {
    const slot = try resolveCapabilitySlot(owner_process_handle, capability_handle, required_rights);
    return switch (slot.object.?) {
        .physical_frame => |authority_handle| authority_handle,
        else => CapabilityError.InvalidCapabilityType,
    };
}

/// Tears down a bootstrap root capability during failed root-task construction.
pub fn destroyUntypedMemoryCapability(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const authority_handle = try resolveUntypedMemory(
        owner_process_handle,
        capability_handle,
        .{ .manage = true },
    );
    try physical_memory_authority.destroyBootstrapRoot(authority_handle);
    clearCapabilitySlot(abi.capability.capabilitySlotIndex(capability_handle));
}

/// Deletes one descendant-free derived physical-memory capability and authority.
pub fn deletePhysicalMemoryCapability(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const slot = try resolveCapabilitySlot(
        owner_process_handle,
        capability_handle,
        .{ .manage = true },
    );
    const authority_handle = physicalAuthorityHandle(slot.object.?) orelse {
        return CapabilityError.InvalidCapabilityType;
    };
    if (hasDirectCapabilityChild(capability_handle)) {
        return CapabilityError.CapabilityHasDescendants;
    }
    try physical_memory_authority.delete(authority_handle);
    clearCapabilitySlot(abi.capability.capabilitySlotIndex(capability_handle));
}

/// Revokes every physical-memory descendant while preserving the selected capability.
pub fn revokePhysicalMemoryCapability(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const slot = try resolveCapabilitySlot(
        owner_process_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (physicalAuthorityHandle(slot.object.?) == null) {
        return CapabilityError.InvalidCapabilityType;
    }

    while (findLeafCapabilityDescendant(capability_handle)) |descendant| {
        const descendant_slot = try resolveCapabilitySlot(owner_process_handle, descendant, .{});
        const authority_handle = physicalAuthorityHandle(descendant_slot.object.?) orelse {
            return CapabilityError.InvalidCapabilityType;
        };
        try physical_memory_authority.delete(authority_handle);
        clearCapabilitySlot(abi.capability.capabilitySlotIndex(descendant));
    }
}

/// Deletes a capability authority without destroying its referenced kernel object.
pub fn deleteCapability(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    _ = try resolveCapabilitySlot(owner_process_handle, capability_handle, .{});
    const slot_index = abi.capability.capabilitySlotIndex(capability_handle);

    if (hasDirectCapabilityChild(capability_handle)) return CapabilityError.CapabilityHasDescendants;
    clearCapabilitySlot(slot_index);
}

fn initializeCapabilitySlot(
    slot_index: usize,
    slot: *CapabilitySlot,
    owner_process_handle: process.ProcessHandle,
    rights: abi.capability.Rights,
    parent: abi.capability.CapabilityHandle,
    object: CapabilityObject,
) abi.capability.CapabilityHandle {
    slot.* = .{
        .generation = slot.generation,
        .owner_process_handle = owner_process_handle,
        .rights = rights,
        .parent = parent,
        .object = object,
        .used = true,
        .retired = false,
    };

    return abi.capability.makeCapabilityHandle(@intCast(slot_index), slot.generation);
}

fn physicalAuthorityHandle(object: CapabilityObject) ?physical_memory_authority.Handle {
    return switch (object) {
        .untyped_memory => |handle| handle,
        .physical_frame => |handle| handle,
        else => null,
    };
}

fn hasDirectCapabilityChild(capability_handle: abi.capability.CapabilityHandle) bool {
    for (capabilitySlots) |slot| {
        if (slot.used and slot.parent == capability_handle) return true;
    }
    return false;
}

fn findLeafCapabilityDescendant(
    ancestor: abi.capability.CapabilityHandle,
) ?abi.capability.CapabilityHandle {
    for (capabilitySlots, 0..) |slot, slot_index| {
        if (!slot.used) continue;
        const handle = abi.capability.makeCapabilityHandle(@intCast(slot_index), slot.generation);
        if (handle == ancestor or !isCapabilityDescendantOf(handle, ancestor)) continue;
        if (!hasDirectCapabilityChild(handle)) return handle;
    }
    return null;
}

fn isCapabilityDescendantOf(
    capability_handle: abi.capability.CapabilityHandle,
    ancestor: abi.capability.CapabilityHandle,
) bool {
    var current = capability_handle;
    var steps: usize = 0;
    while (steps < MAX_CAPABILITIES) : (steps += 1) {
        const parts = abi.capability.decodeCapabilityHandle(current) orelse return false;
        if (parts.slot_index >= capabilitySlots.len) return false;
        const slot = &capabilitySlots[parts.slot_index];
        if (!slot.used or slot.generation != parts.generation) return false;
        if (slot.parent == ancestor) return true;
        if (slot.parent == abi.capability.INVALID_CAPABILITY) return false;
        current = slot.parent;
    }
    return false;
}

fn clearCapabilitySlot(slot_index: usize) void {
    const slot = &capabilitySlots[slot_index];
    slot.used = false;
    slot.owner_process_handle = 0;
    slot.rights = .{};
    slot.parent = abi.capability.INVALID_CAPABILITY;
    slot.object = null;
    if (slot.generation == abi.capability.MAX_CAPABILITY_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
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

pub fn availableCount() usize {
    var count: usize = 0;
    for (capabilitySlots) |slot| {
        if (!slot.used and !slot.retired) count += 1;
    }
    return count;
}

pub fn activeCount() usize {
    var count: usize = 0;
    for (capabilitySlots) |slot| {
        if (slot.used) count += 1;
    }
    return count;
}

/// Resets all capability table state for unit tests.
pub fn resetForTest() void {
    for (&capabilitySlots) |*slot| {
        slot.* = .{};
    }
}
