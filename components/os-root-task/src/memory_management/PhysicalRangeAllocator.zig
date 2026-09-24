//! Bounded root-task allocator for boot-delegated physical ranges.

const abi = @import("abi");
const bootstrap = @import("bootstrap.zig");
const std = @import("std");

const Self = @This();

pub const MAX_FREE_EXTENTS = abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS;
pub const MAX_ALLOCATIONS = abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS;

pub const Error = bootstrap.Error || error{
    DelegatedByteCountOverflow,
    EmptyAllocation,
    InvalidAlignment,
    AllocationOverflow,
    Exhausted,
    MetadataExhausted,
    InvalidHandle,
    ForeignHandle,
    StaleHandle,
    DuplicateFree,
    FreeRangeOverlap,
};

pub const AllocationHandle = struct {
    allocator_address: usize,
    slot: u16,
    generation: u32,
    guard: u64,
};

pub const Range = struct {
    parent_capability: abi.capability.CapabilityHandle,
    physical_start: u64,
    offset: u64,
    size: u64,
};

pub const Statistics = struct {
    delegated_bytes: u64,
    free_bytes: u64,
    allocated_bytes: u64,
    free_extent_count: usize,
    allocation_count: usize,
};

const Extent = struct {
    parent_capability: abi.capability.CapabilityHandle,
    parent_start: u64,
    physical_start: u64,
    size: u64,
};

const AllocationSlot = struct {
    active: bool = false,
    generation: u32 = 0,
    range: Range = undefined,
};

free_extents: [MAX_FREE_EXTENTS]Extent = undefined,
allocations: [MAX_ALLOCATIONS]AllocationSlot = [_]AllocationSlot{.{}} ** MAX_ALLOCATIONS,
free_extent_count: usize = 0,
allocation_count: usize = 0,
delegated_bytes: u64 = 0,
free_bytes: u64 = 0,

pub fn initialize(
    self: *Self,
    descriptors: []const abi.boot_info.PhysicalMemoryInfo,
) Error!void {
    try bootstrap.validate(descriptors);
    if (descriptors.len > MAX_FREE_EXTENTS) return Error.MetadataExhausted;

    var delegated_bytes: u64 = 0;
    for (descriptors) |descriptor| {
        delegated_bytes = std.math.add(
            u64,
            delegated_bytes,
            descriptor.size,
        ) catch return Error.DelegatedByteCountOverflow;
    }

    self.* = .{};
    for (descriptors, 0..) |descriptor, index| {
        self.free_extents[index] = .{
            .parent_capability = descriptor.capability,
            .parent_start = descriptor.physical_start,
            .physical_start = descriptor.physical_start,
            .size = descriptor.size,
        };
    }
    self.free_extent_count = descriptors.len;
    self.delegated_bytes = delegated_bytes;
    self.free_bytes = delegated_bytes;
}

pub fn allocate(self: *Self, size: u64, alignment: u64) Error!AllocationHandle {
    if (size == 0) return Error.EmptyAllocation;
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
        return Error.InvalidAlignment;
    }

    const slot_index = self.availableAllocationSlot() orelse return Error.MetadataExhausted;
    for (self.free_extents[0..self.free_extent_count], 0..) |extent, extent_index| {
        const allocation_start = alignForward(extent.physical_start, alignment) catch
            return Error.AllocationOverflow;
        const allocation_end = std.math.add(
            u64,
            allocation_start,
            size,
        ) catch return Error.AllocationOverflow;
        const extent_end = std.math.add(u64, extent.physical_start, extent.size) catch
            return Error.AllocationOverflow;
        if (allocation_end > extent_end) continue;

        const has_prefix = allocation_start != extent.physical_start;
        const has_suffix = allocation_end != extent_end;
        if (has_prefix and has_suffix and self.free_extent_count == MAX_FREE_EXTENTS) {
            return Error.MetadataExhausted;
        }

        self.commitAllocation(extent_index, allocation_start, allocation_end);
        var slot = &self.allocations[slot_index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.active = true;
        slot.range = .{
            .parent_capability = extent.parent_capability,
            .physical_start = allocation_start,
            .offset = allocation_start - extent.parent_start,
            .size = size,
        };
        self.allocation_count += 1;
        self.free_bytes -= size;
        return self.makeHandle(slot_index, slot.generation);
    }
    return Error.Exhausted;
}

pub fn resolve(self: *const Self, handle: AllocationHandle) Error!Range {
    const slot = try self.validateHandle(handle);
    if (!slot.active) return Error.DuplicateFree;
    return slot.range;
}

pub fn free(self: *Self, handle: AllocationHandle) Error!void {
    const slot = try self.validateHandle(handle);
    if (!slot.active) return Error.DuplicateFree;
    try self.insertFreedRange(slot.range);
    self.free_bytes += slot.range.size;
    self.allocation_count -= 1;
    slot.active = false;
}

pub fn statistics(self: *const Self) Statistics {
    return .{
        .delegated_bytes = self.delegated_bytes,
        .free_bytes = self.free_bytes,
        .allocated_bytes = self.delegated_bytes - self.free_bytes,
        .free_extent_count = self.free_extent_count,
        .allocation_count = self.allocation_count,
    };
}

fn availableAllocationSlot(self: *const Self) ?usize {
    for (self.allocations, 0..) |slot, index| {
        if (!slot.active) return index;
    }
    return null;
}

fn commitAllocation(
    self: *Self,
    extent_index: usize,
    allocation_start: u64,
    allocation_end: u64,
) void {
    const extent = self.free_extents[extent_index];
    const extent_end = extent.physical_start + extent.size;
    const has_prefix = allocation_start != extent.physical_start;
    const has_suffix = allocation_end != extent_end;

    if (has_prefix and has_suffix) {
        self.free_extents[extent_index].size = allocation_start - extent.physical_start;
        self.insertExtent(extent_index + 1, .{
            .parent_capability = extent.parent_capability,
            .parent_start = extent.parent_start,
            .physical_start = allocation_end,
            .size = extent_end - allocation_end,
        });
    } else if (has_prefix) {
        self.free_extents[extent_index].size = allocation_start - extent.physical_start;
    } else if (has_suffix) {
        self.free_extents[extent_index].physical_start = allocation_end;
        self.free_extents[extent_index].size = extent_end - allocation_end;
    } else {
        self.removeExtent(extent_index);
    }
}

fn insertFreedRange(self: *Self, range: Range) Error!void {
    const range_end = std.math.add(u64, range.physical_start, range.size) catch
        return Error.AllocationOverflow;
    var index: usize = 0;
    while (index < self.free_extent_count and
        self.free_extents[index].physical_start < range.physical_start) : (index += 1)
    {}

    const previous = if (index == 0) null else &self.free_extents[index - 1];
    const next = if (index == self.free_extent_count) null else &self.free_extents[index];
    if (previous) |extent| {
        if (extent.physical_start + extent.size > range.physical_start) {
            return Error.FreeRangeOverlap;
        }
    }
    if (next) |extent| {
        if (range_end > extent.physical_start) return Error.FreeRangeOverlap;
    }

    const merge_previous = if (previous) |extent|
        extent.parent_capability == range.parent_capability and
            extent.physical_start + extent.size == range.physical_start
    else
        false;
    const merge_next = if (next) |extent|
        extent.parent_capability == range.parent_capability and
            range_end == extent.physical_start
    else
        false;

    if (merge_previous and merge_next) {
        self.free_extents[index - 1].size += range.size + self.free_extents[index].size;
        self.removeExtent(index);
    } else if (merge_previous) {
        self.free_extents[index - 1].size += range.size;
    } else if (merge_next) {
        self.free_extents[index].physical_start = range.physical_start;
        self.free_extents[index].size += range.size;
    } else {
        if (self.free_extent_count == MAX_FREE_EXTENTS) return Error.MetadataExhausted;
        self.insertExtent(index, .{
            .parent_capability = range.parent_capability,
            .parent_start = range.physical_start - range.offset,
            .physical_start = range.physical_start,
            .size = range.size,
        });
    }
}

fn insertExtent(self: *Self, index: usize, extent: Extent) void {
    var move_index = self.free_extent_count;
    while (move_index > index) : (move_index -= 1) {
        self.free_extents[move_index] = self.free_extents[move_index - 1];
    }
    self.free_extents[index] = extent;
    self.free_extent_count += 1;
}

fn removeExtent(self: *Self, index: usize) void {
    var move_index = index;
    while (move_index + 1 < self.free_extent_count) : (move_index += 1) {
        self.free_extents[move_index] = self.free_extents[move_index + 1];
    }
    self.free_extent_count -= 1;
}

fn validateHandle(self: *const Self, handle: AllocationHandle) Error!*AllocationSlot {
    if (handle.allocator_address != @intFromPtr(self)) return Error.ForeignHandle;
    if (handle.slot >= MAX_ALLOCATIONS) return Error.InvalidHandle;
    if (handle.guard != handleGuard(handle.allocator_address, handle.slot, handle.generation)) {
        return Error.InvalidHandle;
    }
    const slot = &@constCast(self).allocations[handle.slot];
    if (slot.generation != handle.generation) return Error.StaleHandle;
    return slot;
}

fn makeHandle(self: *const Self, slot: usize, generation: u32) AllocationHandle {
    const allocator_address = @intFromPtr(self);
    const narrowed_slot: u16 = @intCast(slot);
    return .{
        .allocator_address = allocator_address,
        .slot = narrowed_slot,
        .generation = generation,
        .guard = handleGuard(allocator_address, narrowed_slot, generation),
    };
}

fn handleGuard(allocator_address: usize, slot: u16, generation: u32) u64 {
    var value: u64 = @intCast(allocator_address);
    value ^= @as(u64, slot) << 17;
    value ^= @as(u64, generation) << 32;
    value ^= 0xA110_CA7E_D5E5_0001;
    value *%= 0x9E37_79B1_85EB_CA87;
    return value ^ (value >> 29);
}

fn alignForward(value: u64, alignment: u64) error{Overflow}!u64 {
    const mask = alignment - 1;
    const with_mask = std.math.add(u64, value, mask) catch return error.Overflow;
    return with_mask & ~mask;
}
