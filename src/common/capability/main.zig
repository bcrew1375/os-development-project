//! Bounded capability spaces for protected kernel-object access.

const abi = @import("abi");
const arch = @import("arch");
const std = @import("std");
const authority = @import("../memory_management/physical_memory_authority.zig");
const process = @import("../process/main.zig");
pub const space = @import("space.zig");

pub const CapabilityError = error{
    OutOfCapabilities,
    InvalidCapability,
    CapabilityOwnerMismatch,
    InvalidCapabilityType,
    InsufficientCapabilityRights,
    CapabilityHasDescendants,
    InvalidCapabilityRights,
    CapabilitySpaceNotEmpty,
} || process.ProcessError || space.Error || authority.Error;

pub const MAX_CAPABILITIES: usize = abi.capability.MAX_CAPABILITY_SLOT_INDEX + 1;

const CapabilityObject = union(enum) {
    address_space: process.AddressSpaceHandle,
    memory_object: process.MemoryObjectHandle,
    untyped_memory: authority.Handle,
    physical_frame: authority.Handle,
    thread: process.thread.Handle,
    capability_space: space.Handle,
};

const Reference = struct {
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
};

const Slot = struct {
    generation: u32 = 1,
    rights: abi.capability.Rights = .{},
    parent: ?Reference = null,
    object: ?CapabilityObject = null,
    used: bool = false,
    retired: bool = false,
};

const Table = [MAX_CAPABILITIES]Slot;
var tables: [space.MAX_CAPABILITY_SPACES]Table =
    [_]Table{[_]Slot{.{}} ** MAX_CAPABILITIES} ** space.MAX_CAPABILITY_SPACES;

pub fn createAddressSpaceCapability(space_handle: space.Handle) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    const index = freeSlot(table) orelse return error.OutOfCapabilities;
    const object_handle = try process.createAddressSpaceForOwner(space_handle);
    errdefer process.destroyAddressSpace(object_handle) catch {};
    return initialize(index, &table[index], .{ .manage = true, .read = true, .write = true, .execute = true }, null, .{
        .address_space = object_handle,
    });
}

pub fn registerAddressSpaceRootCapability(
    space_handle: space.Handle,
    hardware_root: arch.AddressSpaceRoot,
) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    const index = freeSlot(table) orelse return error.OutOfCapabilities;
    const object_handle = try process.registerAddressSpaceRootForOwner(space_handle, hardware_root);
    return initialize(index, &table[index], .{ .manage = true, .read = true, .write = true, .execute = true }, null, .{
        .address_space = object_handle,
    });
}

pub fn findAddressSpaceCapability(
    space_handle: space.Handle,
    address_space_handle: process.AddressSpaceHandle,
) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    for (table, 0..) |slot, index| {
        if (!slot.used) continue;
        switch (slot.object orelse continue) {
            .address_space => |handle| if (handle == address_space_handle) {
                return abi.capability.makeCapabilityHandle(@intCast(index), slot.generation);
            },
            else => {},
        }
    }
    return error.InvalidCapability;
}

pub fn destroyAddressSpaceCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const object_handle = try resolveAddressSpace(space_handle, capability_handle, .{ .manage = true });
    try process.destroyAddressSpace(object_handle);
    try deleteCapability(space_handle, capability_handle);
}

pub fn createCapabilitySpaceCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    const index = freeSlot(table) orelse return error.OutOfCapabilities;
    const object_handle = try space.create();
    errdefer space.destroy(object_handle) catch {};
    return initialize(index, &table[index], .{ .manage = true }, null, .{
        .capability_space = object_handle,
    });
}

pub fn createThreadCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    const index = freeSlot(table) orelse return error.OutOfCapabilities;
    const object_handle = try process.createThread(space_handle);
    errdefer process.thread.destroy(object_handle) catch {};
    return initialize(index, &table[index], .{
        .manage = true,
        .configure = true,
        .start = true,
        .suspend_thread = true,
        .resume_thread = true,
        .terminate = true,
    }, null, .{ .thread = object_handle });
}

pub fn installCapability(
    source_space: space.Handle,
    target_space_capability: abi.capability.CapabilityHandle,
    source_capability: abi.capability.CapabilityHandle,
    rights: abi.capability.Rights,
) CapabilityError!abi.capability.CapabilityHandle {
    const target_space = try resolveCapabilitySpace(
        source_space,
        target_space_capability,
        .{ .manage = true },
    );
    const source = try resolve(source_space, source_capability, .{});
    if (!source.rights.contains(rights)) return error.InvalidCapabilityRights;
    const target_table = try tableFor(target_space);
    const index = freeSlot(target_table) orelse return error.OutOfCapabilities;
    return initialize(
        index,
        &target_table[index],
        rights,
        ref(source_space, source_capability),
        source.object.?,
    );
}

pub fn deleteCapabilityFromSpace(
    source_space: space.Handle,
    target_space_capability: abi.capability.CapabilityHandle,
    target_capability: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const target_space = try resolveCapabilitySpace(
        source_space,
        target_space_capability,
        .{ .manage = true },
    );
    try deleteCapability(target_space, target_capability);
}

pub fn resolveCapabilitySpace(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!space.Handle {
    return switch ((try resolve(space_handle, capability_handle, required)).object.?) {
        .capability_space => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveThread(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!process.thread.Handle {
    return switch ((try resolve(space_handle, capability_handle, required)).object.?) {
        .thread => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn destroyThreadCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = ref(space_handle, capability_handle);
    const object_handle = try resolveThread(space_handle, capability_handle, .{ .manage = true });
    if (hasChild(reference)) return error.CapabilityHasDescendants;
    try process.thread.destroy(object_handle);
    try clear(reference);
}

pub fn destroyCapabilitySpaceCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = ref(space_handle, capability_handle);
    const object_handle = try resolveCapabilitySpace(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (process.thread.referencesCapabilitySpace(object_handle)) return error.CapabilitySpaceInUse;
    if (try activeCountIn(object_handle) != 0) return error.CapabilitySpaceNotEmpty;
    if (hasChild(reference)) return error.CapabilityHasDescendants;
    try space.destroy(object_handle);
    try clear(reference);
}

pub fn createMemoryObjectCapability(
    space_handle: space.Handle,
    frame_capability: abi.capability.CapabilityHandle,
) CapabilityError!abi.capability.CapabilityHandle {
    const slot = try resolveMutable(space_handle, frame_capability, .{ .manage = true });
    const authority_handle = switch (slot.object.?) {
        .physical_frame => |handle| handle,
        else => return error.InvalidCapabilityType,
    };
    const metadata = try authority.get(authority_handle);
    const object_handle = try process.createMemoryObjectForOwner(space_handle, authority_handle);
    arch.mmu.zeroPhysicalRange(metadata.physical_start, metadata.size()) catch |err| {
        process.destroyMemoryObject(object_handle) catch {};
        return err;
    };
    slot.object = .{ .memory_object = object_handle };
    return frame_capability;
}

pub fn destroyMemoryObjectCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = ref(space_handle, capability_handle);
    const object_handle = try resolveMemoryObject(space_handle, capability_handle, .{ .manage = true });
    if (hasChild(reference)) return error.CapabilityHasDescendants;
    const info = try process.getMemoryObjectInfo(object_handle);
    try process.destroyMemoryObject(object_handle);
    try authority.delete(info.authority_handle);
    try clear(reference);
}

pub fn createUntypedMemoryCapability(
    space_handle: space.Handle,
    physical_start: u64,
    size_in_bytes: u64,
    attributes: u32,
    page_size: u64,
) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    const index = freeSlot(table) orelse return error.OutOfCapabilities;
    const object_handle = try authority.createRoot(physical_start, size_in_bytes, attributes, page_size);
    errdefer authority.destroyBootstrapRoot(object_handle) catch {};
    return initialize(
        index,
        &table[index],
        .{ .manage = true, .read = true, .write = true, .execute = true },
        null,
        .{ .untyped_memory = object_handle },
    );
}

pub fn retypeUntypedMemoryCapability(
    space_handle: space.Handle,
    source_capability: abi.capability.CapabilityHandle,
    offset: u64,
    page_count: u32,
    target_type: abi.capability.ObjectType,
    rights: abi.capability.Rights,
) CapabilityError!abi.capability.CapabilityHandle {
    const source = try resolve(space_handle, source_capability, .{ .manage = true });
    if (!source.rights.contains(rights)) return error.InvalidCapabilityRights;
    const source_authority = switch (source.object.?) {
        .untyped_memory => |handle| handle,
        else => return error.InvalidCapabilityType,
    };
    const kind: authority.Kind = switch (target_type) {
        .untyped_memory => .untyped_memory,
        .physical_frame => .physical_frame,
        else => return error.InvalidCapabilityType,
    };
    const table = try tableFor(space_handle);
    const index = freeSlot(table) orelse return error.OutOfCapabilities;
    if (authority.availableCount() == 0) return error.OutOfAuthorities;
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const size = std.math.mul(u64, page_count, page_size) catch return authority.Error.RangeOverflow;
    const object_handle = try authority.derive(source_authority, offset, size, kind, page_size);
    errdefer authority.delete(object_handle) catch {};
    const object: CapabilityObject = switch (kind) {
        .untyped_memory => .{ .untyped_memory = object_handle },
        .physical_frame => .{ .physical_frame = object_handle },
    };
    return initialize(index, &table[index], rights, ref(space_handle, source_capability), object);
}

pub fn resolveAddressSpace(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!process.AddressSpaceHandle {
    return switch ((try resolve(space_handle, capability_handle, required)).object.?) {
        .address_space => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveMemoryObject(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!process.MemoryObjectHandle {
    return switch ((try resolve(space_handle, capability_handle, required)).object.?) {
        .memory_object => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveUntypedMemory(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!authority.Handle {
    return switch ((try resolve(space_handle, capability_handle, required)).object.?) {
        .untyped_memory => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolvePhysicalFrame(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!authority.Handle {
    return switch ((try resolve(space_handle, capability_handle, required)).object.?) {
        .physical_frame => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn destroyUntypedMemoryCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    try authority.destroyBootstrapRoot(try resolveUntypedMemory(
        space_handle,
        capability_handle,
        .{ .manage = true },
    ));
    try clear(ref(space_handle, capability_handle));
}

pub fn deletePhysicalMemoryCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = ref(space_handle, capability_handle);
    const slot = try resolve(space_handle, capability_handle, .{ .manage = true });
    const object_handle = authorityHandle(slot.object.?) orelse return error.InvalidCapabilityType;
    if (hasChild(reference)) return error.CapabilityHasDescendants;
    try authority.delete(object_handle);
    try clear(reference);
}

pub fn revokePhysicalMemoryCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const ancestor = ref(space_handle, capability_handle);
    const slot = try resolve(space_handle, capability_handle, .{ .manage = true });
    if (authorityHandle(slot.object.?) == null) return error.InvalidCapabilityType;
    while (leafDescendant(ancestor)) |descendant| {
        const descendant_slot = try resolve(descendant.space_handle, descendant.capability_handle, .{});
        const object_handle = switch (descendant_slot.object.?) {
            .memory_object => |memory_object| blk: {
                const info = try process.getMemoryObjectInfo(memory_object);
                try process.revokeMemoryObject(memory_object);
                break :blk info.authority_handle;
            },
            else => authorityHandle(descendant_slot.object.?) orelse return error.InvalidCapabilityType,
        };
        try authority.delete(object_handle);
        try clear(descendant);
    }
}

pub fn deleteCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = ref(space_handle, capability_handle);
    _ = try resolve(space_handle, capability_handle, .{});
    if (hasChild(reference)) return error.CapabilityHasDescendants;
    try clear(reference);
}

pub fn availableCount() usize {
    return availableCountIn(space.ROOT_CAPABILITY_SPACE_HANDLE) catch 0;
}

pub fn availableCountIn(space_handle: space.Handle) CapabilityError!usize {
    const table = try tableFor(space_handle);
    var count: usize = 0;
    for (table) |slot| if (!slot.used and !slot.retired) {
        count += 1;
    };
    return count;
}

pub fn activeCount() usize {
    var count: usize = 0;
    for (&tables) |*table| {
        for (table) |slot| if (slot.used) {
            count += 1;
        };
    }
    return count;
}

pub fn activeCountIn(space_handle: space.Handle) CapabilityError!usize {
    const table = try tableFor(space_handle);
    var count: usize = 0;
    for (table) |slot| if (slot.used) {
        count += 1;
    };
    return count;
}

pub fn resetForTest() void {
    tables = [_]Table{[_]Slot{.{}} ** MAX_CAPABILITIES} ** space.MAX_CAPABILITY_SPACES;
}

fn initialize(index: usize, slot: *Slot, rights: abi.capability.Rights, parent: ?Reference, object: CapabilityObject) abi.capability.CapabilityHandle {
    slot.* = .{ .generation = slot.generation, .rights = rights, .parent = parent, .object = object, .used = true };
    return abi.capability.makeCapabilityHandle(@intCast(index), slot.generation);
}

fn authorityHandle(object: CapabilityObject) ?authority.Handle {
    return switch (object) {
        .untyped_memory => |handle| handle,
        .physical_frame => |handle| handle,
        else => null,
    };
}

fn hasChild(parent: Reference) bool {
    for (&tables) |*table| {
        for (table) |slot| {
            if (slot.used and equalOptional(slot.parent, parent)) return true;
        }
    }
    return false;
}

fn leafDescendant(ancestor: Reference) ?Reference {
    for (&tables, 0..) |*table, table_index| {
        const space_handle = liveSpaceAt(table_index) orelse continue;
        for (table, 0..) |slot, index| {
            if (!slot.used) continue;
            const candidate = ref(space_handle, abi.capability.makeCapabilityHandle(@intCast(index), slot.generation));
            if (equal(candidate, ancestor) or !isDescendant(candidate, ancestor)) continue;
            if (!hasChild(candidate)) return candidate;
        }
    }
    return null;
}

fn isDescendant(descendant: Reference, ancestor: Reference) bool {
    var current = descendant;
    var steps: usize = 0;
    while (steps < MAX_CAPABILITIES * space.MAX_CAPABILITY_SPACES) : (steps += 1) {
        const parent = (resolve(current.space_handle, current.capability_handle, .{}) catch return false).parent orelse return false;
        if (equal(parent, ancestor)) return true;
        current = parent;
    }
    return false;
}

fn clear(reference: Reference) CapabilityError!void {
    const table = try tableFor(reference.space_handle);
    const parts = abi.capability.decodeCapabilityHandle(reference.capability_handle) orelse return error.InvalidCapability;
    if (parts.slot_index >= table.len) return error.InvalidCapability;
    const slot = &table[parts.slot_index];
    if (!slot.used or slot.generation != parts.generation) return error.InvalidCapability;
    slot.used = false;
    slot.rights = .{};
    slot.parent = null;
    slot.object = null;
    if (slot.generation == abi.capability.MAX_CAPABILITY_GENERATION) slot.retired = true else slot.generation += 1;
}

fn resolve(space_handle: space.Handle, capability_handle: abi.capability.CapabilityHandle, required: abi.capability.Rights) CapabilityError!*const Slot {
    const table = try tableFor(space_handle);
    const parts = abi.capability.decodeCapabilityHandle(capability_handle) orelse return error.InvalidCapability;
    if (parts.slot_index >= table.len) return error.InvalidCapability;
    const slot = &table[parts.slot_index];
    if (!slot.used or slot.generation != parts.generation) return error.InvalidCapability;
    if (!slot.rights.contains(required)) return error.InsufficientCapabilityRights;
    return slot;
}

fn resolveMutable(space_handle: space.Handle, capability_handle: abi.capability.CapabilityHandle, required: abi.capability.Rights) CapabilityError!*Slot {
    return @constCast(try resolve(space_handle, capability_handle, required));
}

fn tableFor(space_handle: space.Handle) CapabilityError!*Table {
    return &tables[try space.storageIndex(space_handle)];
}

fn freeSlot(table: *const Table) ?usize {
    for (table, 0..) |slot, index| if (!slot.used and !slot.retired) return index;
    return null;
}

fn ref(space_handle: space.Handle, capability_handle: abi.capability.CapabilityHandle) Reference {
    return .{ .space_handle = space_handle, .capability_handle = capability_handle };
}

fn equal(left: Reference, right: Reference) bool {
    return left.space_handle == right.space_handle and left.capability_handle == right.capability_handle;
}

fn equalOptional(left: ?Reference, right: Reference) bool {
    return if (left) |reference| equal(reference, right) else false;
}

fn liveSpaceAt(index: usize) ?space.Handle {
    return space.handleForStorageIndex(index);
}
