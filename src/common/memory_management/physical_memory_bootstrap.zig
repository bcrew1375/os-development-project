//! Adapts architecture boot maps and reservations into normalized RAM ranges.

const arch = @import("arch");
const physical_ranges = @import("physical_ranges.zig");
const std = @import("std");

pub const MAX_ALLOCATABLE_RANGES: usize = 64;
pub const MAX_RETAINED_RANGES: usize = 512;
const MAX_EXCLUSIONS = arch.MAX_EARLY_RESERVATIONS + arch.MAX_BOOT_MODULES +
    arch.MAX_MEMORY_MAP_ENTRIES;

pub const Error = error{
    TooManyBootModules,
    InvalidBootModuleRange,
    ExclusionCapacityExceeded,
} || physical_ranges.Error;

pub const Result = struct {
    allocatable_count: usize,
    retained_count: usize,
};

const Workspace = struct {
    memory_map: [arch.MAX_MEMORY_MAP_ENTRIES]physical_ranges.MemoryMapInput = undefined,
    exclusions: [MAX_EXCLUSIONS]physical_ranges.Exclusion = undefined,
    allocatable: [MAX_ALLOCATABLE_RANGES]physical_ranges.Range = undefined,
    retained: [MAX_RETAINED_RANGES]physical_ranges.RetainedRange = undefined,
    normalization_scratch: physical_ranges.Scratch = .{},
};

// Boot normalization runs before concurrency is enabled. Static workspace avoids
// placing the complete firmware map and exclusion set on the bootstrap stack.
var workspace: Workspace = .{};

pub fn normalizeArchitectureMemory() Error!struct {
    allocatable: []const physical_ranges.Range,
    retained: []const physical_ranges.RetainedRange,
} {
    const memory_map = arch.mmu.getMemoryMap();
    const memory_count = try adaptMemoryMap(
        memory_map.entries[0..memory_map.length],
        workspace.memory_map[0..],
    );
    const exclusion_count = try adaptExclusions(
        memory_map.entries[0..memory_map.length],
        arch.early_allocator.getReservedMap(),
        workspace.exclusions[0..],
        arch.mmu.getMaximumPhysicalAddress(),
    );
    const normalized = try physical_ranges.normalize(
        workspace.memory_map[0..memory_count],
        workspace.exclusions[0..exclusion_count],
        @intCast(arch.mmu.getPageSize()),
        workspace.allocatable[0..],
        workspace.retained[0..],
        &workspace.normalization_scratch,
    );
    return .{
        .allocatable = workspace.allocatable[0..normalized.allocatable_count],
        .retained = workspace.retained[0..normalized.retained_count],
    };
}

pub fn adaptMemoryMap(
    memory_map: []const arch.MemoryMapEntry,
    output: []physical_ranges.MemoryMapInput,
) Error!usize {
    if (memory_map.len > output.len) return physical_ranges.Error.OutputTooSmall;
    for (memory_map, 0..) |entry, index| {
        output[index] = .{
            .start = entry.address,
            .size = entry.size,
            .kind = switch (entry.region_type) {
                .AVAILABLE => .available,
                .RESERVED => .reserved,
                .RECLAIMABLE => .reclaimable,
                .BAD => .bad,
            },
        };
    }
    return memory_map.len;
}

pub fn adaptExclusions(
    memory_map: []const arch.MemoryMapEntry,
    reserved_map: *const arch.ReservedMap,
    output: []physical_ranges.Exclusion,
    maximum_physical_address: u64,
) Error!usize {
    var count: usize = 0;
    for (reserved_map.entries[0..reserved_map.length]) |reservation| {
        try appendExclusion(output, &count, .{
            .start = reservation.address,
            .size = reservation.size,
            .reason = reservationReason(reservation.region_type),
        });
    }

    const module_count = @min(arch.boot.getBootModuleCount(), arch.MAX_BOOT_MODULES);
    for (0..module_count) |module_index| {
        const module = arch.boot.getBootModule(module_index) orelse {
            return Error.InvalidBootModuleRange;
        };
        if (module.physical_start >= module.physical_end) {
            return Error.InvalidBootModuleRange;
        }
        try appendExclusion(output, &count, .{
            .start = module.physical_start,
            .size = module.physical_end - module.physical_start,
            .reason = .boot_module,
        });
    }

    if (maximum_physical_address != std.math.maxInt(u64)) {
        const addressable_end = maximum_physical_address + 1;
        for (memory_map) |entry| {
            const entry_end = std.math.add(u64, entry.address, entry.size) catch {
                return physical_ranges.Error.RangeOverflow;
            };
            if (entry_end <= addressable_end) continue;
            const excluded_start = @max(entry.address, addressable_end);
            try appendExclusion(output, &count, .{
                .start = excluded_start,
                .size = entry_end - excluded_start,
                .reason = .physical_address_limit,
            });
        }
    }
    return count;
}

fn appendExclusion(
    output: []physical_ranges.Exclusion,
    count: *usize,
    exclusion: physical_ranges.Exclusion,
) Error!void {
    if (count.* >= output.len) return Error.ExclusionCapacityExceeded;
    output[count.*] = exclusion;
    count.* += 1;
}

fn reservationReason(region_type: arch.ReservedMapRegionType) physical_ranges.RetainedReason {
    return switch (region_type) {
        .KERNEL_READ_ONLY, .KERNEL_WRITABLE => .kernel_image,
        .DEVICE_MEMORY => .framebuffer_or_mmio,
        .BOOTLOADER_DATA => .retained_bootloader_data,
        .PAGE_TABLE_POOL => .kernel_page_table_pool,
        .TEMPORARY, .PERSISTENT => .active_page_tables,
    };
}
