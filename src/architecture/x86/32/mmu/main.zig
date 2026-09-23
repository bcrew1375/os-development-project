const arch = @import("arch");
const kernel_common = @import("kernel_common");

const common = @import("common.zig");
const address_space = @import("address_space.zig");

pub const createAddressSpaceRoot = address_space.createAddressSpaceRoot;
pub const destroyAddressSpaceRoot = address_space.destroyAddressSpaceRoot;
pub const switchAddressSpaceRoot = address_space.switchAddressSpaceRoot;
pub const initializePaging = @import("early_boot.zig").initializePaging;
pub const getMemoryMap = @import("memory_map.zig").getMemoryMap;
pub const getMaxAvailableAddress = @import("memory_map.zig").getMaxAvailableAddress;

pub fn getMaximumPhysicalAddress() u64 {
    return std.math.maxInt(u32);
}

const std = @import("std");

inline fn getCurrentPageDirectory() common.PageDirectory {
    return getPageDirectoryFromAddressSpaceRoot(getCurrentAddressSpaceRoot());
}

inline fn getCurrentAddressSpaceRoot() arch.AddressSpaceRoot {
    var cr3: usize = undefined;
    asm volatile ("mov %cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );
    return .{ .value = cr3 };
}

inline fn getPageDirectoryFromAddressSpaceRoot(root: arch.AddressSpaceRoot) common.PageDirectory {
    return @ptrFromInt(root.value + common.DIRECT_MAP_VIRTUAL_ADDRESS);
}

pub fn getPhysicalAddress(virtualAddress: usize) ?usize {
    return getPhysicalAddressInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress);
}

pub fn getPhysicalAddressInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?usize {
    const page_directory_index = getPageDirectoryIndex(virtualAddress);
    const page_table_index = getPageTableIndex(virtualAddress);
    const page_offset = virtualAddress & 0xFFF;

    const page_dir = getPageDirectoryFromAddressSpaceRoot(root);
    if (!page_dir[page_directory_index].present) return null;

    const page_table = getPageTableFromDirectory(page_dir, page_directory_index);
    const page_table_entry = page_table[page_table_index];
    if (!page_table_entry.present) return null;

    const physical_address = (@as(usize, page_table_entry.address) << 12) + page_offset;
    return physical_address;
}

pub fn getPageProtection(virtualAddress: usize) ?arch.PageProtection {
    return getPageProtectionInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress);
}

pub fn getPageProtectionInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?arch.PageProtection {
    const page_directory_index = getPageDirectoryIndex(virtualAddress);
    const page_table_index = getPageTableIndex(virtualAddress);

    const page_directory = getPageDirectoryFromAddressSpaceRoot(root);
    const directory_entry = page_directory[page_directory_index];
    if (!directory_entry.present) return null;

    const page_table = getPageTableFromDirectory(page_directory, page_directory_index);
    const page_entry = page_table[page_table_index];
    if (!page_entry.present) return null;

    return .{
        .write = directory_entry.writeable and page_entry.writeable,
        .user = directory_entry.user_accessible and page_entry.user_accessible,
        .execute = true,
        .global = page_entry.global,
    };
}

pub fn isTablePresent(virtualAddress: usize) bool {
    return isTablePresentInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress);
}

pub fn isTablePresentInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) bool {
    const page_directory_index = getPageDirectoryIndex(virtualAddress);
    const page_dir = getPageDirectoryFromAddressSpaceRoot(root);
    return page_dir[page_directory_index].present;
}

pub fn ensurePageTable(virtualAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try ensurePageTableInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress, flags);
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
        return pageTablePoolError(err);
    };
    errdefer arch.page_table_pool.freeFrame(root, physical_address) catch {};
    try mapTableInAddressSpace(root, virtualAddress, physical_address, flags);
}

pub fn mapPage(virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try mapPageInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress, physicalAddress, flags);
}

pub fn mapPageInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    const page_directory_index = getPageDirectoryIndex(virtualAddress);
    const page_table_index = getPageTableIndex(virtualAddress);

    const page_dir = getPageDirectoryFromAddressSpaceRoot(root);
    if (!page_dir[page_directory_index].present) {
        return arch.MmuError.PageTableNotPresent;
    }

    page_dir[page_directory_index].writeable = page_dir[page_directory_index].writeable or flags.write;
    page_dir[page_directory_index].user_accessible = page_dir[page_directory_index].user_accessible or flags.user;

    const page_table = getPageTableFromDirectory(page_dir, page_directory_index);
    page_table[page_table_index].address = @truncate(physicalAddress >> 12);
    page_table[page_table_index].present = true;
    page_table[page_table_index].writeable = flags.write;
    page_table[page_table_index].user_accessible = flags.user;
    page_table[page_table_index].global = flags.global;

    flushTLB(virtualAddress);
}

pub fn mapTable(virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try mapTableInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress, physicalAddress, flags);
}

pub fn mapTableInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    const page_directory_index = getPageDirectoryIndex(virtualAddress);

    const page_dir = getPageDirectoryFromAddressSpaceRoot(root);
    if (page_dir[page_directory_index].present) {
        page_dir[page_directory_index].writeable = page_dir[page_directory_index].writeable or flags.write;
        page_dir[page_directory_index].user_accessible = page_dir[page_directory_index].user_accessible or flags.user;
        flushTLB(virtualAddress);
        return;
    }

    clearPageTable(physicalAddress);

    page_dir[page_directory_index].address = @truncate(physicalAddress >> 12);
    page_dir[page_directory_index].present = true;
    page_dir[page_directory_index].writeable = true;
    page_dir[page_directory_index].user_accessible = flags.user;

    flushTLB(virtualAddress);
}

pub fn unmapPage(virtualAddress: usize) ?usize {
    return unmapPageInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress);
}

pub fn unmapPageInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?usize {
    const page_directory_index = getPageDirectoryIndex(virtualAddress);
    const page_table_index = getPageTableIndex(virtualAddress);

    const page_dir = getPageDirectoryFromAddressSpaceRoot(root);
    if (!page_dir[page_directory_index].present) return null;

    const page_table = getPageTableFromDirectory(page_dir, page_directory_index);
    if (!page_table[page_table_index].present) return null;

    const physical_address = @as(usize, page_table[page_table_index].address) << 12;
    page_table[page_table_index].present = false;

    flushTLB(virtualAddress);
    return physical_address;
}

pub fn getKernelVirtualAddressStart() u64 {
    return common.DIRECT_MAP_VIRTUAL_ADDRESS;
}

pub fn getDirectMapVirtualAddress() u64 {
    return common.DIRECT_MAP_VIRTUAL_ADDRESS;
}

pub fn getDirectMapMaxSize() u64 {
    return common.DIRECT_MAP_SIZE;
}

pub fn getKernelHeapVirtualAddress() u64 {
    return common.KERNEL_HEAP_VIRTUAL_ADDRESS;
}

pub fn getKernelHeapSize() u64 {
    const available_ram = kernel_common.pmm.getTotalAvailableRAM();
    const heap_size_float = @as(f64, @floatFromInt(available_ram)) * common.KERNEL_HEAP_SIZE_RATIO;
    const heap_size_int = @as(u64, @intFromFloat(heap_size_float));
    const aligned_heap_size = std.mem.alignForward(u64, heap_size_int, common.PAGE_SIZE) & std.mem.alignBackward(u64, heap_size_int, common.PAGE_SIZE);
    return aligned_heap_size;
}

pub fn getPageSize() usize {
    return common.PAGE_SIZE;
}

pub fn getPageTableRegionSize() usize {
    return common.PAGE_TABLE_REGION_SIZE;
}

pub fn getPageTablePoolAvailableFrameCount() usize {
    return arch.page_table_pool.availableFrameCount();
}

pub fn removeIdentityMapping() void {
    const page_dir = getCurrentPageDirectory();

    const needed_page_tables = @as(usize, @truncate((getDirectMapMaxSize() +| common.PAGE_TABLE_REGION_SIZE -| 1) / common.PAGE_TABLE_REGION_SIZE));

    for (0..needed_page_tables) |table_index| {
        page_dir[table_index].present = false;
        flushTLB(table_index * common.PAGE_TABLE_REGION_SIZE);
    }
}

inline fn flushTLB(virtualAddress: usize) void {
    asm volatile ("invlpg (%[address])"
        :
        : [address] "r" (virtualAddress),
        : .{ .memory = true });
}

fn clearPageTable(physicalAddress: usize) void {
    const page_table: common.PageTable = @ptrFromInt(physicalAddress + common.DIRECT_MAP_VIRTUAL_ADDRESS);
    for (page_table) |*entry| {
        entry.* = .{};
    }
}

inline fn getPageTableFromDirectory(page_dir: common.PageDirectory, directoryIndex: usize) common.PageTable {
    const physical_address = @as(usize, page_dir[directoryIndex].address) << 12;
    return @ptrFromInt(physical_address + common.DIRECT_MAP_VIRTUAL_ADDRESS);
}

inline fn getPageDirectoryIndex(virtualAddress: usize) usize {
    return virtualAddress >> 22;
}

inline fn getPageTableIndex(virtualAddress: usize) usize {
    return (virtualAddress >> 12) & 0x3FF;
}

fn pageTablePoolError(err: arch.page_table_pool.Error) arch.MmuError {
    return switch (err) {
        error.AddressSpaceLimitReached => arch.MmuError.AddressSpacePageTableLimitReached,
        error.PoolExhausted => arch.MmuError.PageTablePoolExhausted,
        else => arch.MmuError.MappingError,
    };
}
