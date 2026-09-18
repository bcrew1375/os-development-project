const arch = @import("arch");

const std = @import("std");

pub inline fn initialize() arch.EarlyAllocError!void {
    const memoryMap = arch.mmu.getMemoryMap();
    try validateMemoryMap(memoryMap);

    for (memoryMap.entries[0..memoryMap.length]) |*entry| {
        if (entry.region_type != arch.MemoryMapRegionType.AVAILABLE) {
            try arch.early_allocator.reserve(
                @intCast(entry.address),
                @intCast(entry.size),
                arch.ReservedMapRegionType.PERSISTENT,
            );
        }
    }
}

pub inline fn allocate(neededSize: usize, alignment: usize, regionType: arch.ReservedMapRegionType) arch.EarlyAllocError!*allowzero anyopaque {
    if (neededSize == 0) {
        return arch.EarlyAllocError.InvalidSize;
    }

    if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
        return arch.EarlyAllocError.InvalidAlignment;
    }

    const memoryMap = arch.mmu.getMemoryMap();
    try validateMemoryMap(memoryMap);
    const reservedMap = arch.early_allocator.getReservedMap();

    for (memoryMap.entries[0..memoryMap.length]) |*region| {
        if (region.region_type != arch.MemoryMapRegionType.AVAILABLE) {
            continue;
        }

        const region_start: usize = @intCast(region.address);
        const region_end: usize = @intCast(region.address + region.size - 1);

        // Initial candidate address must be within the region and aligned
        var candidate_start = alignForward(region_start, alignment) orelse continue;

        find_gap: while (true) {
            const needed_last_offset = neededSize - 1;
            if (candidate_start > std.math.maxInt(usize) - needed_last_offset) {
                break :find_gap;
            }
            const candidate_end = candidate_start + needed_last_offset;

            // Check if the current candidate still fits inside the available memory region
            if (candidate_end > region_end or candidate_start > region_end) {
                break :find_gap;
            }

            for (reservedMap.entries[0..reservedMap.length]) |*reserved| {
                const reserved_start = reserved.address;
                if (reserved.size == 0) return arch.EarlyAllocError.InvalidSize;
                const reserved_last_offset = reserved.size - 1;
                if (reserved_start > std.math.maxInt(usize) - reserved_last_offset) {
                    return arch.EarlyAllocError.InvalidSize;
                }
                const reserved_end = reserved_start + reserved_last_offset;

                if (candidate_start <= reserved_end and candidate_end >= reserved_start) {
                    // Conflict found: bump start address past the reserved region and re-align
                    if (reserved_end == std.math.maxInt(usize)) break :find_gap;
                    candidate_start = alignForward(
                        reserved_end + 1,
                        alignment,
                    ) orelse break :find_gap;
                    continue :find_gap;
                }
            }

            // If we reached here, no overlaps were found for this candidate
            try arch.early_allocator.reserve(candidate_start, neededSize, regionType);
            return @ptrFromInt(candidate_start);
        }
    }

    return arch.EarlyAllocError.OutOfSpace;
}

pub inline fn reserve(address: usize, size: usize, region_type: arch.ReservedMapRegionType) arch.EarlyAllocError!void {
    if (size == 0) return arch.EarlyAllocError.InvalidSize;
    if (address > std.math.maxInt(usize) - (size - 1)) {
        return arch.EarlyAllocError.InvalidSize;
    }
    const reservedMap = arch.early_allocator.getReservedMap();

    if (reservedMap.length >= arch.MAX_EARLY_RESERVATIONS) {
        return arch.EarlyAllocError.OutOfReservations;
    }

    reservedMap.entries[reservedMap.length].address = address;
    reservedMap.entries[reservedMap.length].size = size;
    reservedMap.entries[reservedMap.length].region_type = region_type;

    reservedMap.length += 1;
}

inline fn validateMemoryMap(memory_map: *const arch.MemoryMap) arch.EarlyAllocError!void {
    if (memory_map.length > memory_map.entries.len) {
        return arch.EarlyAllocError.InvalidMemoryMap;
    }

    var previous_last_address: u64 = 0;
    for (memory_map.entries[0..memory_map.length], 0..) |entry, index| {
        if (entry.size == 0) return arch.EarlyAllocError.InvalidMemoryMap;
        const last_offset = entry.size - 1;
        if (entry.address > std.math.maxInt(u64) - last_offset) {
            return arch.EarlyAllocError.InvalidMemoryMap;
        }
        const last_address = entry.address + last_offset;
        if (entry.address > std.math.maxInt(usize) or
            entry.size > std.math.maxInt(usize) or
            last_address > std.math.maxInt(usize))
        {
            return arch.EarlyAllocError.InvalidMemoryMap;
        }
        if (index != 0 and entry.address <= previous_last_address) {
            return arch.EarlyAllocError.InvalidMemoryMap;
        }
        previous_last_address = last_address;
    }
}

inline fn alignForward(value: usize, alignment: usize) ?usize {
    const alignment_mask = alignment - 1;
    if (value > std.math.maxInt(usize) - alignment_mask) return null;
    return (value + alignment_mask) & ~alignment_mask;
}
