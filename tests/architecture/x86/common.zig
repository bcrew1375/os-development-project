const arch = @import("arch");
const framework = @import("../framework.zig");

pub fn pageSizeIsFourKiB() !void {
    try framework.expectEqual(@as(usize, 4096), arch.mmu.getPageSize());
}

pub fn pageTableRegionIsAligned() !void {
    const page_size = arch.mmu.getPageSize();
    const region_size = arch.mmu.getPageTableRegionSize();
    try framework.expect(region_size >= page_size);
    try framework.expect(region_size % page_size == 0);
}

pub fn memoryMapContainsAvailableMemory() !void {
    const memory_map = arch.mmu.getMemoryMap();
    try framework.expect(memory_map.length > 0);
    try framework.expect(memory_map.length <= arch.MAX_MEMORY_MAP_ENTRIES);

    for (memory_map.entries[0..memory_map.length]) |entry| {
        if (entry.region_type == .AVAILABLE and entry.size > 0) return;
    }
    return framework.TestError.ExpectationFailed;
}

pub fn maximumAddressCoversAvailableRegions() !void {
    const maximum_address = arch.mmu.getMaxAvailableAddress();
    try framework.expect(maximum_address > 0);

    const memory_map = arch.mmu.getMemoryMap();
    for (memory_map.entries[0..memory_map.length]) |entry| {
        if (entry.region_type != .AVAILABLE) continue;
        try framework.expect(maximum_address >= entry.address +| entry.size);
    }
}

pub fn kernelSymbolHasPhysicalMapping() !void {
    const virtual_address = @intFromPtr(&kernelSymbolHasPhysicalMapping);
    const physical_address = arch.mmu.getPhysicalAddress(virtual_address) orelse
        return framework.TestError.ExpectationFailed;
    try framework.expectEqual(
        virtual_address % arch.mmu.getPageSize(),
        physical_address % arch.mmu.getPageSize(),
    );
}
