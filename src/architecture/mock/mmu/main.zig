const arch = @import("../../architecture.zig");

const std = @import("std");

var memoryMap = arch.MemoryMap{};
var memoryBacking: ?[]u8 = null;

var currentAddressSpaceRoot: arch.AddressSpaceRoot = .{ .value = 0 };

pub const FixtureRegion = struct {
    offset: usize,
    size: usize,
    region_type: arch.MemoryMapRegionType,
};

// Track mapped page tables so getPhysicalAddress can distinguish
// "table not present" from "page not present".
const MAX_MOCK_TABLES = arch.page_table_pool.FRAME_CAPACITY;
const MockTableMapping = struct {
    root_value: usize,
    virtual_address: usize,
    physical_address: usize,
    flags: arch.PageProtection,
};
var tableMappings: [MAX_MOCK_TABLES]MockTableMapping = undefined;
var tableMappingCount: usize = 0;

const MAX_MOCK_PAGE_MAPPINGS = 4096;
pub const MockPageMapping = struct {
    root_value: usize = 0,
    virtual_page: usize,
    physical_page: usize,
    protection: arch.PageProtection,
    present: bool,
};
var pageMappings: [MAX_MOCK_PAGE_MAPPINGS]MockPageMapping = undefined;
var pageMappingCount: usize = 0;

const FailureInjection = struct {
    fail_table_mapping_call: ?usize = null,
    fail_page_mapping_call: ?usize = null,
    fail_physical_lookup_call: ?usize = null,
    fail_address_space_root_creation: bool = false,
    table_mapping_calls: usize = 0,
    page_mapping_calls: usize = 0,
    physical_lookup_calls: usize = 0,
};
var failureInjection: FailureInjection = .{};

pub fn createAddressSpaceRoot() arch.MmuError!arch.AddressSpaceRoot {
    if (failureInjection.fail_address_space_root_creation) {
        return arch.MmuError.AddressSpaceRootAllocationFailed;
    }

    const root_value = arch.page_table_pool.allocateRootFrame() catch |err| {
        return switch (err) {
            error.PoolExhausted => arch.MmuError.PageTablePoolExhausted,
            else => arch.MmuError.AddressSpaceRootAllocationFailed,
        };
    };
    return .{ .value = root_value };
}

pub fn destroyAddressSpaceRoot(root: arch.AddressSpaceRoot) void {
    for (pageMappings[0..pageMappingCount]) |*mapping| {
        if (mapping.root_value == root.value) mapping.present = false;
    }

    var table_index: usize = 0;
    while (table_index < tableMappingCount) {
        if (tableMappings[table_index].root_value != root.value) {
            table_index += 1;
            continue;
        }
        tableMappingCount -= 1;
        tableMappings[table_index] = tableMappings[tableMappingCount];
    }
    arch.page_table_pool.freeAddressSpace(root);
}

pub fn switchAddressSpaceRoot(root: arch.AddressSpaceRoot) void {
    currentAddressSpaceRoot = root;
}

pub fn getPhysicalAddress(virtualAddress: usize) ?usize {
    return getPhysicalAddressInAddressSpace(currentAddressSpaceRoot, virtualAddress);
}

pub fn getPhysicalAddressInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?usize {
    failureInjection.physical_lookup_calls += 1;
    if (failureInjection.fail_physical_lookup_call == failureInjection.physical_lookup_calls) {
        return null;
    }

    const pageSize = getPageSize();
    const virtualPage = virtualAddress & ~(pageSize - 1);
    const pageOffset = virtualAddress & (pageSize - 1);

    for (pageMappings[0..pageMappingCount]) |mapping| {
        if (mapping.present and mapping.root_value == root.value and mapping.virtual_page == virtualPage) {
            return mapping.physical_page + pageOffset;
        }
    }

    return null;
}

pub fn getPageProtection(virtualAddress: usize) ?arch.PageProtection {
    return getPageProtectionInAddressSpace(currentAddressSpaceRoot, virtualAddress);
}

pub fn getPageProtectionInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?arch.PageProtection {
    const page_size = getPageSize();
    const virtual_page = virtualAddress & ~(page_size - 1);

    for (pageMappings[0..pageMappingCount]) |mapping| {
        if (mapping.present and
            mapping.root_value == root.value and
            mapping.virtual_page == virtual_page)
        {
            return mapping.protection;
        }
    }

    return null;
}

pub fn isTablePresent(virtualAddress: usize) bool {
    return isTablePresentInAddressSpace(currentAddressSpaceRoot, virtualAddress);
}

pub fn isTablePresentInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) bool {
    const pageTableRegionSize = getPageTableRegionSize();
    const tableAlignedAddress = virtualAddress & ~(pageTableRegionSize - 1);
    for (tableMappings[0..tableMappingCount]) |mapping| {
        if (mapping.root_value == root.value and mapping.virtual_address == tableAlignedAddress) {
            return true;
        }
    }
    return false;
}

pub fn ensurePageTable(virtualAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try ensurePageTableInAddressSpace(currentAddressSpaceRoot, virtualAddress, flags);
}

pub fn ensurePageTableInAddressSpace(
    root: arch.AddressSpaceRoot,
    virtualAddress: usize,
    flags: arch.PageProtection,
) arch.MmuError!void {
    if (isTablePresentInAddressSpace(root, virtualAddress)) {
        try mapTableInAddressSpace(root, virtualAddress, 0, flags);
        return;
    }

    const physical_address = arch.page_table_pool.allocateFrame(root) catch |err| {
        return switch (err) {
            error.AddressSpaceLimitReached => arch.MmuError.AddressSpacePageTableLimitReached,
            error.PoolExhausted => arch.MmuError.PageTablePoolExhausted,
            else => arch.MmuError.MappingError,
        };
    };
    errdefer arch.page_table_pool.freeFrame(root, physical_address) catch {};
    try mapTableInAddressSpace(root, virtualAddress, physical_address, flags);
}

pub fn getMemoryMap() *arch.MemoryMap {
    _ = requireMemoryFixture();
    return &memoryMap;
}

pub fn mapPage(virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try mapPageInAddressSpace(currentAddressSpaceRoot, virtualAddress, physicalAddress, flags);
}

pub fn mapPageInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    failureInjection.page_mapping_calls += 1;
    if (failureInjection.fail_page_mapping_call == failureInjection.page_mapping_calls) {
        return arch.MmuError.MappingError;
    }
    if (!isTablePresentInAddressSpace(root, virtualAddress)) {
        return arch.MmuError.PageTableNotPresent;
    }

    const pageSize = getPageSize();
    const virtualPage = virtualAddress & ~(pageSize - 1);
    const physicalPage = physicalAddress & ~(pageSize - 1);

    for (pageMappings[0..pageMappingCount]) |*mapping| {
        if (mapping.root_value == root.value and mapping.virtual_page == virtualPage) {
            mapping.physical_page = physicalPage;
            mapping.protection = flags;
            mapping.present = true;
            return;
        }
    }

    if (pageMappingCount >= MAX_MOCK_PAGE_MAPPINGS) {
        return arch.MmuError.MappingError;
    }

    pageMappings[pageMappingCount] = .{
        .root_value = root.value,
        .virtual_page = virtualPage,
        .physical_page = physicalPage,
        .protection = flags,
        .present = true,
    };
    pageMappingCount += 1;
}

pub fn mapTable(virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try mapTableInAddressSpace(currentAddressSpaceRoot, virtualAddress, physicalAddress, flags);
}

pub fn mapTableInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    failureInjection.table_mapping_calls += 1;
    if (failureInjection.fail_table_mapping_call == failureInjection.table_mapping_calls) {
        return arch.MmuError.MappingError;
    }
    // Align to the page table region boundary so lookups via
    // isTablePresent (which applies the same alignment) succeed.
    const pageTableRegionSize = getPageTableRegionSize();
    const tableAlignedAddress = virtualAddress & ~(pageTableRegionSize - 1);

    // Check if this table is already mapped.
    for (tableMappings[0..tableMappingCount]) |*mapping| {
        if (mapping.root_value == root.value and mapping.virtual_address == tableAlignedAddress) {
            mapping.flags.write = mapping.flags.write or flags.write;
            mapping.flags.user = mapping.flags.user or flags.user;
            mapping.flags.execute = mapping.flags.execute and flags.execute;
            return;
        }
    }

    if (tableMappingCount >= MAX_MOCK_TABLES) {
        @panic("Mock MMU: too many page tables");
    }

    tableMappings[tableMappingCount] = .{
        .root_value = root.value,
        .virtual_address = tableAlignedAddress,
        .physical_address = physicalAddress,
        .flags = flags,
    };
    tableMappingCount += 1;
}

pub fn getTableProtection(virtualAddress: usize) ?arch.PageProtection {
    const pageTableRegionSize = getPageTableRegionSize();
    const tableAlignedAddress = virtualAddress & ~(pageTableRegionSize - 1);
    for (tableMappings[0..tableMappingCount]) |mapping| {
        if (mapping.root_value == currentAddressSpaceRoot.value and mapping.virtual_address == tableAlignedAddress) {
            return mapping.flags;
        }
    }
    return null;
}

pub fn unmapPage(virtualAddress: usize) ?usize {
    return unmapPageInAddressSpace(currentAddressSpaceRoot, virtualAddress);
}

pub fn unmapPageInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?usize {
    const pageSize = getPageSize();
    const virtualPage = virtualAddress & ~(pageSize - 1);
    for (pageMappings[0..pageMappingCount]) |*mapping| {
        if (mapping.present and
            mapping.root_value == root.value and
            mapping.virtual_page == virtualPage)
        {
            mapping.present = false;
            return mapping.physical_page;
        }
    }
    return null;
}

pub fn resetForTest() void {
    currentAddressSpaceRoot = .{ .value = 0 };
    tableMappingCount = 0;
    pageMappingCount = 0;
    failureInjection = .{};
}

pub fn initializeDefaultMemoryFixtureForTest() !void {
    const backing_size = 64 * 1024 * 1024;
    try initializeMemoryFixtureForTest(backing_size, &.{.{
        .offset = 0,
        .size = backing_size,
        .region_type = .AVAILABLE,
    }});
}

pub fn initializeMemoryFixtureForTest(
    backing_size: usize,
    regions: []const FixtureRegion,
) !void {
    if (backing_size == 0 or regions.len == 0) return error.InvalidMemoryFixture;
    if (regions.len > memoryMap.entries.len) return error.TooManyMemoryMapEntries;

    deinitializeMemoryFixtureForTest();
    const backing = try std.heap.page_allocator.alloc(u8, backing_size);
    errdefer std.heap.page_allocator.free(backing);
    @memset(backing, 0);

    memoryMap = arch.MemoryMap{};
    for (regions, 0..) |region, index| {
        if (region.size == 0 or region.offset > backing_size) {
            return error.InvalidMemoryFixture;
        }
        if (region.size > backing_size - region.offset) {
            return error.InvalidMemoryFixture;
        }

        memoryMap.entries[index] = .{
            .address = region.offset,
            .size = region.size,
            .region_type = region.region_type,
        };
        if (region.region_type == .AVAILABLE) memoryMap.available_regions += 1;
    }
    memoryMap.length = regions.len;
    memoryBacking = backing;
    resetForTest();
}

pub fn deinitializeMemoryFixtureForTest() void {
    if (memoryBacking) |backing| std.heap.page_allocator.free(backing);
    memoryBacking = null;
    memoryMap = arch.MemoryMap{};
    resetForTest();
}

pub fn getHostVirtualAddressForTest(physical_address: usize) usize {
    const backing = requireMemoryFixture();
    if (physical_address >= backing.len) {
        @panic("mock MMU physical address exceeds memory fixture");
    }
    return @intFromPtr(backing.ptr) + physical_address;
}

pub fn writePhysicalMemoryForTest(physical_address: usize, source: []const u8) !void {
    const destination = try physicalMemorySliceForTest(physical_address, source.len);
    @memcpy(destination, source);
}

pub fn readPhysicalMemoryForTest(physical_address: usize, destination: []u8) !void {
    const source = try physicalMemorySliceForTest(physical_address, destination.len);
    @memcpy(destination, source);
}

pub fn readVirtualMemoryInAddressSpaceForTest(
    root: arch.AddressSpaceRoot,
    virtual_address: usize,
    destination: []u8,
) !void {
    var copied: usize = 0;
    while (copied < destination.len) {
        const current_virtual_address = std.math.add(usize, virtual_address, copied) catch {
            return error.InvalidVirtualRange;
        };
        const physical_address = getPhysicalAddressInAddressSpace(root, current_virtual_address) orelse {
            return error.VirtualAddressNotMapped;
        };
        const page_remaining = getPageSize() - (current_virtual_address & (getPageSize() - 1));
        const copy_size = @min(page_remaining, destination.len - copied);
        const source = try physicalMemorySliceForTest(physical_address, copy_size);
        @memcpy(destination[copied..][0..copy_size], source);
        copied += copy_size;
    }
}

pub fn isMemoryFixtureInitializedForTest() bool {
    return memoryBacking != null;
}

pub fn getMappedPageForTest(virtualAddress: usize) ?MockPageMapping {
    return getMappedPageInAddressSpaceForTest(currentAddressSpaceRoot, virtualAddress);
}

pub fn getCurrentAddressSpaceRootForTest() arch.AddressSpaceRoot {
    return currentAddressSpaceRoot;
}

pub fn getMappedPageInAddressSpaceForTest(
    root: arch.AddressSpaceRoot,
    virtualAddress: usize,
) ?MockPageMapping {
    const pageSize = getPageSize();
    const virtualPage = virtualAddress & ~(pageSize - 1);
    for (pageMappings[0..pageMappingCount]) |mapping| {
        if (mapping.root_value == root.value and mapping.virtual_page == virtualPage) {
            return mapping;
        }
    }
    return null;
}

pub fn failTableMappingCallForTest(call: ?usize) void {
    failureInjection.fail_table_mapping_call = call;
    failureInjection.table_mapping_calls = 0;
}

pub fn failPageMappingCallForTest(call: ?usize) void {
    failureInjection.fail_page_mapping_call = call;
    failureInjection.page_mapping_calls = 0;
}

pub fn failAddressSpaceRootCreationForTest(should_fail: bool) void {
    failureInjection.fail_address_space_root_creation = should_fail;
}

pub fn failPhysicalLookupCallForTest(call: ?usize) void {
    failureInjection.fail_physical_lookup_call = call;
    failureInjection.physical_lookup_calls = 0;
}

pub fn getMaxAvailableAddress() u64 {
    return requireMemoryFixture().len;
}

pub fn getMaximumPhysicalAddress() u64 {
    return std.math.maxInt(u64);
}

pub fn getDirectMapVirtualAddress() u64 {
    return @intFromPtr(requireMemoryFixture().ptr);
}

pub fn getDirectMapMaxSize() u64 {
    return requireMemoryFixture().len;
}

pub fn getKernelVirtualAddressStart() u64 {
    return 0xC0000000;
}

pub fn getKernelHeapVirtualAddress() u64 {
    return 0;
}

pub fn getKernelHeapSize() u64 {
    return 0;
}

pub fn getPageSize() usize {
    return 4096;
}

pub fn getPageTableRegionSize() usize {
    return 4096 * 1024;
}

pub fn getPageTablePoolAvailableFrameCount() usize {
    return arch.page_table_pool.availableFrameCount();
}

fn requireMemoryFixture() []u8 {
    return memoryBacking orelse @panic("mock MMU memory fixture is not initialized");
}

fn physicalMemorySliceForTest(physical_address: usize, length: usize) ![]u8 {
    const backing = requireMemoryFixture();
    if (physical_address > backing.len or length > backing.len - physical_address) {
        return error.InvalidPhysicalRange;
    }
    return backing[physical_address..][0..length];
}
