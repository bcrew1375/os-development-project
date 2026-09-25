//! Bounded generation-checked capability-space object registry.

const std = @import("std");

pub const MAX_CAPABILITY_SPACES: usize = 16;
pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;
pub const ROOT_CAPABILITY_SPACE_HANDLE: Handle = 1;
const MAX_GENERATION: u32 = (std.math.maxInt(u32) - 1) / MAX_CAPABILITY_SPACES + 1;

pub const Error = error{
    OutOfCapabilitySpaces,
    InvalidCapabilitySpaceHandle,
    CapabilitySpaceInUse,
};

const Slot = struct {
    generation: u32 = 1,
    used: bool = false,
    retired: bool = false,
};

var slots = initialSlots();

pub fn create() Error!Handle {
    const slot_index = findFreeSlot() orelse return error.OutOfCapabilitySpaces;
    const slot = &slots[slot_index];
    slot.used = true;
    return makeHandle(slot_index, slot.generation);
}

pub fn validate(handle: Handle) Error!void {
    _ = try resolveSlot(handle);
}

pub fn storageIndex(handle: Handle) Error!usize {
    _ = try resolveSlot(handle);
    return decodeHandle(handle).?.slot_index;
}

pub fn handleForStorageIndex(index: usize) ?Handle {
    if (index >= slots.len) return null;
    const slot = &slots[index];
    if (!slot.used) return null;
    return makeHandle(index, slot.generation);
}

pub fn destroy(handle: Handle) Error!void {
    if (handle == ROOT_CAPABILITY_SPACE_HANDLE) return error.CapabilitySpaceInUse;
    const slot = try resolveMutableSlot(handle);
    slot.used = false;
    if (slot.generation == MAX_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

pub fn availableCount() usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (!slot.used and !slot.retired) count += 1;
    }
    return count;
}

pub fn activeCount() usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.used) count += 1;
    }
    return count;
}

pub fn resetForTest() void {
    slots = initialSlots();
}

fn resolveSlot(handle: Handle) Error!*const Slot {
    const decoded = decodeHandle(handle) orelse return error.InvalidCapabilitySpaceHandle;
    const slot = &slots[decoded.slot_index];
    if (!slot.used or slot.generation != decoded.generation) {
        return error.InvalidCapabilitySpaceHandle;
    }
    return slot;
}

fn resolveMutableSlot(handle: Handle) Error!*Slot {
    return @constCast(try resolveSlot(handle));
}

fn findFreeSlot() ?usize {
    for (slots, 0..) |slot, index| {
        if (!slot.used and !slot.retired) return index;
    }
    return null;
}

fn makeHandle(slot_index: usize, generation: u32) Handle {
    std.debug.assert(slot_index < MAX_CAPABILITY_SPACES);
    std.debug.assert(generation > 0 and generation <= MAX_GENERATION);
    return @intCast((generation - 1) * MAX_CAPABILITY_SPACES + slot_index + 1);
}

const HandleParts = struct {
    slot_index: usize,
    generation: u32,
};

fn decodeHandle(handle: Handle) ?HandleParts {
    if (handle == INVALID_HANDLE) return null;
    const encoded = handle - 1;
    return .{
        .slot_index = @intCast(encoded % MAX_CAPABILITY_SPACES),
        .generation = @intCast(encoded / MAX_CAPABILITY_SPACES + 1),
    };
}

fn initialSlots() [MAX_CAPABILITY_SPACES]Slot {
    var initial = [_]Slot{.{}} ** MAX_CAPABILITY_SPACES;
    initial[0].used = true;
    return initial;
}

comptime {
    std.debug.assert(ROOT_CAPABILITY_SPACE_HANDLE == makeHandle(0, 1));
}
