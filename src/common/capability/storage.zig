//! Bounded capability-slot storage and generation-checked resolution.

const abi = @import("abi");
const std = @import("std");
const endpoint = @import("../ipc/endpoint.zig");
const interrupt_source = @import("../ipc/interrupt_source.zig");
const notification = @import("../ipc/notification.zig");
const authority = @import("../memory_management/physical_memory_authority.zig");
const process = @import("../process/main.zig");
const errors = @import("errors.zig");
const space = @import("space.zig");

pub const CapabilityError = errors.CapabilityError;
pub const MAX_CAPABILITIES: usize = abi.capability.MAX_CAPABILITY_SLOT_INDEX + 1;

pub const CapabilityObject = union(enum) {
    address_space: process.AddressSpaceHandle,
    memory_object: process.MemoryObjectHandle,
    untyped_memory: authority.Handle,
    physical_frame: authority.Handle,
    thread: process.thread.Handle,
    capability_space: space.Handle,
    endpoint: endpoint.Handle,
    notification: notification.Handle,
    interrupt_source: interrupt_source.Handle,
};

pub const Reference = struct {
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
};

pub const Snapshot = struct {
    reference: Reference,
    rights: abi.capability.Rights,
    parent: ?Reference,
    object: CapabilityObject,
};

pub const PreparedSlot = struct {
    space_handle: space.Handle,
    slot_index: usize,
    generation: u32,
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
var tables: [space.MAX_CAPABILITY_SPACES]Table = initialTables();

pub fn prepareAvailable(space_handle: space.Handle) CapabilityError!PreparedSlot {
    const table = try tableFor(space_handle);
    const slot_index = freeSlot(table) orelse return error.OutOfCapabilities;
    return preparedFor(space_handle, slot_index, &table[slot_index]);
}

pub fn prepareExact(
    space_handle: space.Handle,
    destination_slot: u32,
) CapabilityError!PreparedSlot {
    if (destination_slot >= MAX_CAPABILITIES) return error.InvalidCapabilitySlot;
    const table = try tableFor(space_handle);
    const slot = &table[destination_slot];
    if (slot.used) return error.CapabilitySlotOccupied;
    if (slot.retired) return error.InvalidCapabilitySlot;
    return preparedFor(space_handle, destination_slot, slot);
}

pub fn commit(
    prepared: PreparedSlot,
    rights: abi.capability.Rights,
    parent: ?Reference,
    object: CapabilityObject,
) abi.capability.CapabilityHandle {
    const slot = preparedSlot(prepared);
    std.debug.assert(!slot.used);
    std.debug.assert(!slot.retired);
    std.debug.assert(slot.generation == prepared.generation);
    slot.* = .{
        .generation = prepared.generation,
        .rights = rights,
        .parent = parent,
        .object = object,
        .used = true,
    };
    return handleFor(prepared);
}

pub fn rollback(
    prepared: PreparedSlot,
    installed: abi.capability.CapabilityHandle,
    expected_parent: Reference,
) void {
    std.debug.assert(installed == handleFor(prepared));
    const slot = preparedSlot(prepared);
    std.debug.assert(slot.used);
    std.debug.assert(slot.generation == prepared.generation);
    std.debug.assert(equalOptional(slot.parent, expected_parent));
    slot.* = .{ .generation = prepared.generation };
}

pub fn resolve(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!Snapshot {
    const reference = ref(space_handle, capability_handle);
    const slot = try resolveSlot(reference);
    if (!slot.rights.contains(required)) return error.InsufficientCapabilityRights;
    return snapshot(reference, slot);
}

pub fn replaceObject(
    reference: Reference,
    required: abi.capability.Rights,
    object: CapabilityObject,
) CapabilityError!void {
    const slot = @constCast(try resolveSlot(reference));
    if (!slot.rights.contains(required)) return error.InsufficientCapabilityRights;
    slot.object = object;
}

pub fn clear(reference: Reference) CapabilityError!void {
    const slot = @constCast(try resolveSlot(reference));
    slot.used = false;
    slot.rights = .{};
    slot.parent = null;
    slot.object = null;
    if (slot.generation == abi.capability.MAX_CAPABILITY_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

pub fn findAddressSpace(
    space_handle: space.Handle,
    address_space_handle: process.AddressSpaceHandle,
) CapabilityError!abi.capability.CapabilityHandle {
    const table = try tableFor(space_handle);
    for (table, 0..) |slot, slot_index| {
        if (!slot.used) continue;
        switch (slot.object orelse continue) {
            .address_space => |handle| if (handle == address_space_handle) {
                return abi.capability.makeCapabilityHandle(
                    @intCast(slot_index),
                    slot.generation,
                );
            },
            else => {},
        }
    }
    return error.InvalidCapability;
}

pub fn activeReferenceAt(table_index: usize, slot_index: usize) ?Reference {
    if (table_index >= tables.len or slot_index >= MAX_CAPABILITIES) return null;
    const space_handle = space.handleForStorageIndex(table_index) orelse return null;
    const slot = tables[table_index][slot_index];
    if (!slot.used) return null;
    return ref(
        space_handle,
        abi.capability.makeCapabilityHandle(@intCast(slot_index), slot.generation),
    );
}

pub fn activeObjectAt(table_index: usize, slot_index: usize) ?CapabilityObject {
    if (table_index >= tables.len or slot_index >= MAX_CAPABILITIES) return null;
    const slot = tables[table_index][slot_index];
    if (!slot.used) return null;
    return slot.object;
}

pub fn availableCount() usize {
    return availableCountIn(space.ROOT_CAPABILITY_SPACE_HANDLE) catch 0;
}

pub fn availableCountIn(space_handle: space.Handle) CapabilityError!usize {
    const table = try tableFor(space_handle);
    var count: usize = 0;
    for (table) |slot| {
        if (!slot.used and !slot.retired) count += 1;
    }
    return count;
}

pub fn activeCount() usize {
    var count: usize = 0;
    for (tables) |table| {
        for (table) |slot| {
            if (slot.used) count += 1;
        }
    }
    return count;
}

pub fn activeCountIn(space_handle: space.Handle) CapabilityError!usize {
    const table = try tableFor(space_handle);
    var count: usize = 0;
    for (table) |slot| {
        if (slot.used) count += 1;
    }
    return count;
}

pub fn resetForTest() void {
    for (&tables) |*table| {
        for (table) |*slot| {
            slot.* = .{};
        }
    }
}

pub fn ref(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) Reference {
    return .{
        .space_handle = space_handle,
        .capability_handle = capability_handle,
    };
}

pub fn equal(left: Reference, right: Reference) bool {
    return left.space_handle == right.space_handle and
        left.capability_handle == right.capability_handle;
}

fn snapshot(reference: Reference, slot: *const Slot) Snapshot {
    return .{
        .reference = reference,
        .rights = slot.rights,
        .parent = slot.parent,
        .object = slot.object.?,
    };
}

fn resolveSlot(reference: Reference) CapabilityError!*const Slot {
    const table = try tableFor(reference.space_handle);
    const parts = abi.capability.decodeCapabilityHandle(reference.capability_handle) orelse {
        return error.InvalidCapability;
    };
    if (parts.slot_index >= table.len) return error.InvalidCapability;
    const slot = &table[parts.slot_index];
    if (!slot.used or slot.generation != parts.generation) {
        return error.InvalidCapability;
    }
    return slot;
}

fn preparedFor(
    space_handle: space.Handle,
    slot_index: usize,
    slot: *const Slot,
) PreparedSlot {
    return .{
        .space_handle = space_handle,
        .slot_index = slot_index,
        .generation = slot.generation,
    };
}

fn preparedSlot(prepared: PreparedSlot) *Slot {
    const table = tableFor(prepared.space_handle) catch unreachable;
    return &table[prepared.slot_index];
}

fn handleFor(prepared: PreparedSlot) abi.capability.CapabilityHandle {
    return abi.capability.makeCapabilityHandle(
        @intCast(prepared.slot_index),
        prepared.generation,
    );
}

fn tableFor(space_handle: space.Handle) CapabilityError!*Table {
    return &tables[try space.storageIndex(space_handle)];
}

fn freeSlot(table: *const Table) ?usize {
    for (table, 0..) |slot, slot_index| {
        if (!slot.used and !slot.retired) return slot_index;
    }
    return null;
}

fn equalOptional(left: ?Reference, right: Reference) bool {
    return if (left) |reference| equal(reference, right) else false;
}

fn initialTables() [space.MAX_CAPABILITY_SPACES]Table {
    return [_]Table{[_]Slot{.{}} ** MAX_CAPABILITIES} ** space.MAX_CAPABILITY_SPACES;
}
