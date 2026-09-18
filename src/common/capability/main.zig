//! Kernel-side capability table for protected object access.

const abi = @import("abi");
const process = @import("../process/main.zig");

/// Errors produced while creating or resolving capabilities.
pub const CapabilityError = error{
    InvalidCapability,
    CapabilityOwnerMismatch,
    InvalidCapabilityType,
    InsufficientCapabilityRights,
} || process.ProcessError;

const MAX_CAPABILITIES = 128;

const CapabilityObject = union(enum) {
    address_space: process.AddressSpaceHandle,
    memory_object: process.MemoryObjectHandle,
};

const CapabilitySlot = struct {
    handle: abi.capability.CapabilityHandle = abi.capability.INVALID_CAPABILITY,
    owner_process_handle: process.ProcessHandle = 0,
    rights: abi.capability.Rights = .{},
    object: ?CapabilityObject = null,
    used: bool = false,
};

var nextCapabilityHandle: abi.capability.CapabilityHandle = 1;
var capabilitySlots: [MAX_CAPABILITIES]CapabilitySlot = [_]CapabilitySlot{.{}} ** MAX_CAPABILITIES;

/// Creates a managed address-space capability owned by `owner_process_handle`.
pub fn createAddressSpaceCapability(owner_process_handle: process.ProcessHandle) CapabilityError!abi.capability.CapabilityHandle {
    // The backing address-space registry exhausts before this larger table can.
    const slot = findFreeCapabilitySlot() orelse unreachable;
    const address_space_handle = try process.createAddressSpaceForOwner(owner_process_handle);

    return initializeCapabilitySlot(slot, owner_process_handle, .{
        .manage = true,
        .read = true,
        .write = true,
    }, .{ .address_space = address_space_handle });
}

/// Creates a managed memory-object capability owned by `owner_process_handle`.
pub fn createMemoryObjectCapability(owner_process_handle: process.ProcessHandle, size_in_bytes: u64) CapabilityError!abi.capability.CapabilityHandle {
    // The backing memory-object registry exhausts before this larger table can.
    const slot = findFreeCapabilitySlot() orelse unreachable;
    const memory_object_handle = try process.createMemoryObjectForOwner(owner_process_handle, size_in_bytes);

    return initializeCapabilitySlot(slot, owner_process_handle, .{
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

fn initializeCapabilitySlot(
    slot: *CapabilitySlot,
    owner_process_handle: process.ProcessHandle,
    rights: abi.capability.Rights,
    object: CapabilityObject,
) abi.capability.CapabilityHandle {
    const handle = nextCapabilityHandle;
    nextCapabilityHandle += 1;

    slot.* = .{
        .handle = handle,
        .owner_process_handle = owner_process_handle,
        .rights = rights,
        .object = object,
        .used = true,
    };

    return handle;
}

fn resolveCapabilitySlot(
    owner_process_handle: process.ProcessHandle,
    capability_handle: abi.capability.CapabilityHandle,
    required_rights: abi.capability.Rights,
) CapabilityError!*const CapabilitySlot {
    const slot = findCapabilitySlot(capability_handle) orelse return CapabilityError.InvalidCapability;
    if (slot.owner_process_handle != owner_process_handle) return CapabilityError.CapabilityOwnerMismatch;
    if (!slot.rights.contains(required_rights)) return CapabilityError.InsufficientCapabilityRights;
    return slot;
}

fn findFreeCapabilitySlot() ?*CapabilitySlot {
    for (&capabilitySlots) |*slot| {
        if (!slot.used) return slot;
    }
    return null;
}

fn findCapabilitySlot(capability_handle: abi.capability.CapabilityHandle) ?*const CapabilitySlot {
    if (capability_handle == abi.capability.INVALID_CAPABILITY) return null;

    for (&capabilitySlots) |*slot| {
        if (slot.used and slot.handle == capability_handle) return slot;
    }
    return null;
}

/// Resets all capability table state for unit tests.
pub fn resetForTest() void {
    nextCapabilityHandle = 1;
    for (&capabilitySlots) |*slot| {
        slot.* = .{};
    }
}
