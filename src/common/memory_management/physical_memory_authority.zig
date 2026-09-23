//! Bounded kernel objects representing derived authority over physical memory.

const abi = @import("abi");
const std = @import("std");

/// Capacity includes bootstrap root authorities and all derived authorities.
pub const MAX_AUTHORITIES: usize = 128;
const HANDLE_SLOT_BITS: u32 = 7;
const MAX_SLOT_INDEX: u32 = (@as(u32, 1) << HANDLE_SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - HANDLE_SLOT_BITS)) - 1;

/// Opaque generation-checked authority handle.
pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;

pub const Kind = enum {
    untyped_memory,
    physical_frame,
};

pub const Authority = struct {
    physical_start: u64,
    physical_end: u64,
    attributes: u32,
    kind: Kind,
    parent: Handle,
    bootstrap_root: bool,

    pub fn size(self: Authority) u64 {
        return self.physical_end - self.physical_start;
    }
};

pub const Error = error{
    OutOfAuthorities,
    InvalidAuthority,
    InvalidAuthorityKind,
    BootstrapRootDeletion,
    AuthorityHasDescendants,
    EmptyRange,
    RangeOverflow,
    RangeOutOfBounds,
    UnalignedRange,
    InvalidAttributes,
    OverlappingAuthority,
};

const Slot = struct {
    generation: u32 = 1,
    authority: Authority = emptyAuthority(),
    used: bool = false,
    retired: bool = false,
};

var slots: [MAX_AUTHORITIES]Slot = [_]Slot{.{}} ** MAX_AUTHORITIES;

/// Creates a non-overlapping, page-aligned bootstrap untyped authority.
pub fn createRoot(
    physical_start: u64,
    size_in_bytes: u64,
    attributes: u32,
    page_size: u64,
) Error!Handle {
    const physical_end = try validateRange(physical_start, size_in_bytes, attributes, page_size);
    for (slots) |slot| {
        if (slot.used and rangesOverlap(physical_start, physical_end, slot.authority)) {
            return Error.OverlappingAuthority;
        }
    }

    return createInFreeSlot(.{
        .physical_start = physical_start,
        .physical_end = physical_end,
        .attributes = attributes,
        .kind = .untyped_memory,
        .parent = INVALID_HANDLE,
        .bootstrap_root = true,
    });
}

/// Derives an aligned, contained, non-overlapping child authority.
pub fn derive(
    parent_handle: Handle,
    offset: u64,
    size_in_bytes: u64,
    kind: Kind,
    page_size: u64,
) Error!Handle {
    const parent = (try resolveSlot(parent_handle)).authority;
    if (parent.kind != .untyped_memory) return Error.InvalidAuthorityKind;
    if (availableCount() == 0) return Error.OutOfAuthorities;
    if (page_size == 0 or offset % page_size != 0) return Error.UnalignedRange;

    const physical_start = std.math.add(u64, parent.physical_start, offset) catch {
        return Error.RangeOverflow;
    };
    const physical_end = try validateRange(
        physical_start,
        size_in_bytes,
        parent.attributes,
        page_size,
    );
    if (physical_start < parent.physical_start or physical_end > parent.physical_end) {
        return Error.RangeOutOfBounds;
    }

    for (slots, 0..) |slot, slot_index| {
        if (!slot.used or !rangesOverlap(physical_start, physical_end, slot.authority)) continue;
        if (isAncestorSlotOfHandle(slot_index, parent_handle)) continue;
        return Error.OverlappingAuthority;
    }

    return createInFreeSlot(.{
        .physical_start = physical_start,
        .physical_end = physical_end,
        .attributes = parent.attributes,
        .kind = kind,
        .parent = parent_handle,
        .bootstrap_root = false,
    });
}

/// Returns immutable authority metadata after validating the handle generation.
pub fn get(handle: Handle) Error!Authority {
    return (try resolveSlot(handle)).authority;
}

/// Deletes one descendant-free derived authority.
pub fn delete(handle: Handle) Error!void {
    const slot = try resolveSlot(handle);
    if (slot.authority.bootstrap_root) return Error.BootstrapRootDeletion;
    if (hasDirectChild(handle)) return Error.AuthorityHasDescendants;
    destroyResolved(handle);
}

/// Deletes every descendant, deepest-first, while preserving `handle`.
pub fn revokeDescendants(handle: Handle) Error!void {
    _ = try resolveSlot(handle);
    while (findLeafDescendant(handle)) |descendant| {
        destroyResolved(descendant);
    }
}

/// Tears down a bootstrap root during failed boot-info construction only.
pub fn destroyBootstrapRoot(handle: Handle) Error!void {
    const slot = try resolveSlot(handle);
    if (!slot.authority.bootstrap_root) return Error.InvalidAuthority;
    if (hasDirectChild(handle)) return Error.AuthorityHasDescendants;
    destroyResolved(handle);
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

/// Resets all authority state for unit tests.
pub fn resetForTest() void {
    slots = [_]Slot{.{}} ** MAX_AUTHORITIES;
}

fn validateRange(physical_start: u64, size_in_bytes: u64, attributes: u32, page_size: u64) Error!u64 {
    if (size_in_bytes == 0) return Error.EmptyRange;
    if (page_size == 0 or !std.math.isPowerOfTwo(page_size)) return Error.UnalignedRange;
    if (physical_start % page_size != 0 or size_in_bytes % page_size != 0) {
        return Error.UnalignedRange;
    }
    if (attributes != abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM) {
        return Error.InvalidAttributes;
    }
    return std.math.add(u64, physical_start, size_in_bytes) catch Error.RangeOverflow;
}

fn createInFreeSlot(authority: Authority) Error!Handle {
    const slot_index = findFreeSlot() orelse return Error.OutOfAuthorities;
    const slot = &slots[slot_index];
    slot.* = .{
        .generation = slot.generation,
        .authority = authority,
        .used = true,
        .retired = false,
    };
    return makeHandle(slot_index, slot.generation);
}

fn resolveSlot(handle: Handle) Error!*const Slot {
    const slot_index = handleSlotIndex(handle) orelse return Error.InvalidAuthority;
    const generation = handle >> HANDLE_SLOT_BITS;
    const slot = &slots[slot_index];
    if (!slot.used or slot.generation != generation) return Error.InvalidAuthority;
    return slot;
}

fn hasDirectChild(handle: Handle) bool {
    for (slots) |slot| {
        if (slot.used and slot.authority.parent == handle) return true;
    }
    return false;
}

fn findLeafDescendant(ancestor: Handle) ?Handle {
    for (slots, 0..) |slot, slot_index| {
        if (!slot.used) continue;
        const handle = makeHandle(slot_index, slot.generation);
        if (handle == ancestor or !isDescendantOf(handle, ancestor)) continue;
        if (!hasDirectChild(handle)) return handle;
    }
    return null;
}

fn isDescendantOf(handle: Handle, ancestor: Handle) bool {
    var current = handle;
    var steps: usize = 0;
    while (steps < MAX_AUTHORITIES) : (steps += 1) {
        const slot = resolveSlot(current) catch return false;
        const parent = slot.authority.parent;
        if (parent == ancestor) return true;
        if (parent == INVALID_HANDLE) return false;
        current = parent;
    }
    return false;
}

fn isAncestorSlotOfHandle(candidate_slot_index: usize, handle: Handle) bool {
    var current = handle;
    var steps: usize = 0;
    while (steps < MAX_AUTHORITIES) : (steps += 1) {
        const slot_index = handleSlotIndex(current) orelse return false;
        const slot = resolveSlot(current) catch return false;
        if (slot_index == candidate_slot_index) return true;
        if (slot.authority.parent == INVALID_HANDLE) return false;
        current = slot.authority.parent;
    }
    return false;
}

fn destroyResolved(handle: Handle) void {
    const slot_index = handleSlotIndex(handle).?;
    const slot = &slots[slot_index];
    std.debug.assert(slot.used);
    slot.used = false;
    slot.authority = emptyAuthority();
    if (slot.generation == MAX_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

fn rangesOverlap(physical_start: u64, physical_end: u64, authority: Authority) bool {
    return physical_start < authority.physical_end and physical_end > authority.physical_start;
}

fn findFreeSlot() ?usize {
    for (slots, 0..) |slot, index| {
        if (!slot.used and !slot.retired) return index;
    }
    return null;
}

fn makeHandle(slot_index: usize, generation: u32) Handle {
    std.debug.assert(slot_index <= MAX_SLOT_INDEX);
    std.debug.assert(generation > 0 and generation <= MAX_GENERATION);
    return (generation << HANDLE_SLOT_BITS) | @as(u32, @intCast(slot_index));
}

fn handleSlotIndex(handle: Handle) ?usize {
    if (handle == INVALID_HANDLE) return null;
    const generation = handle >> HANDLE_SLOT_BITS;
    if (generation == 0) return null;
    const slot_index: usize = @intCast(handle & MAX_SLOT_INDEX);
    if (slot_index >= slots.len) return null;
    return slot_index;
}

fn emptyAuthority() Authority {
    return .{
        .physical_start = 0,
        .physical_end = 0,
        .attributes = 0,
        .kind = .untyped_memory,
        .parent = INVALID_HANDLE,
        .bootstrap_root = false,
    };
}

comptime {
    std.debug.assert(MAX_AUTHORITIES == MAX_SLOT_INDEX + 1);
}
