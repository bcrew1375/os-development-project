const arch = @import("arch");
const address_space = @import("address_space.zig");
const common = @import("common.zig");
const limine_requests = @import("../../common/boot/limine/requests.zig");

pub const createAddressSpaceRoot = address_space.createAddressSpaceRoot;
pub const switchAddressSpaceRoot = address_space.switchAddressSpaceRoot;
pub const getMemoryMap = @import("memory_map.zig").getMemoryMap;
pub const getMaxAvailableAddress = @import("memory_map.zig").getMaxAvailableAddress;

const PageWalk = struct {
    pml4: common.PageTable,
    pdpt: common.PageTable,
    page_directory: common.PageTable,
    page_table: common.PageTable,
    pml4_index: usize,
    pdpt_index: usize,
    page_directory_index: usize,
    page_table_index: usize,
};

inline fn getCurrentAddressSpaceRoot() arch.AddressSpaceRoot {
    var cr3: usize = undefined;
    asm volatile ("mov %cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );
    return .{ .value = cr3 & ~@as(usize, 0xFFF) };
}

pub fn getPhysicalAddress(virtualAddress: usize) ?usize {
    return getPhysicalAddressInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress);
}

pub fn getPhysicalAddressInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) ?usize {
    const pml4 = getPageTableFromPhysical(root.value);
    const pml4_entry = pml4[pml4Index(virtualAddress)];
    if (!pml4_entry.present) return null;

    const pdpt = getNextLevelTable(pml4_entry);
    const pdpt_entry = pdpt[pdptIndex(virtualAddress)];
    if (!pdpt_entry.present or pdpt_entry.page_size) return null;

    const page_directory = getNextLevelTable(pdpt_entry);
    const page_directory_entry = page_directory[pageDirectoryIndex(virtualAddress)];
    if (!page_directory_entry.present or page_directory_entry.page_size) return null;

    const page_table = getNextLevelTable(page_directory_entry);
    const page_table_entry = page_table[pageTableIndex(virtualAddress)];
    if (!page_table_entry.present) return null;

    return pageBasePhysicalAddress(page_table_entry) + pageOffset(virtualAddress);
}

pub fn isTablePresent(virtualAddress: usize) bool {
    return isTablePresentInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress);
}

pub fn isTablePresentInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize) bool {
    return walkToPageTable(root, virtualAddress) != null;
}

pub fn mapPage(virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try mapPageInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress, physicalAddress, flags);
}

pub fn mapPageInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    const walk = walkToPageTable(root, virtualAddress) orelse return arch.MmuError.PageTableNotPresent;

    widenIntermediatePermissions(walk, flags);
    walk.page_table[walk.page_table_index] = makePageEntry(physicalAddress, flags);

    flushTLB(virtualAddress);
}

pub fn mapTable(virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    try mapTableInAddressSpace(getCurrentAddressSpaceRoot(), virtualAddress, physicalAddress, flags);
}

pub fn mapTableInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: arch.PageProtection) arch.MmuError!void {
    const pml4 = getPageTableFromPhysical(root.value);
    const pml4_index = pml4Index(virtualAddress);
    const pdpt_index = pdptIndex(virtualAddress);
    const page_directory_index = pageDirectoryIndex(virtualAddress);

    if (!pml4[pml4_index].present) {
        const pdpt_physical_address = allocatePageTablePhysicalAddress() catch return arch.MmuError.MappingError;
        clearPageTable(pdpt_physical_address);
        pml4[pml4_index] = makeTableEntry(pdpt_physical_address, flags);
    }

    widenEntryPermissions(&pml4[pml4_index], flags);
    const pdpt = getNextLevelTable(pml4[pml4_index]);
    if (!pdpt[pdpt_index].present) {
        const page_directory_physical_address = allocatePageTablePhysicalAddress() catch return arch.MmuError.MappingError;
        clearPageTable(page_directory_physical_address);
        pdpt[pdpt_index] = makeTableEntry(page_directory_physical_address, flags);
    }

    widenEntryPermissions(&pdpt[pdpt_index], flags);
    const page_directory = getNextLevelTable(pdpt[pdpt_index]);
    if (!page_directory[page_directory_index].present) {
        clearPageTable(physicalAddress);
        page_directory[page_directory_index] = makeTableEntry(physicalAddress, flags);
        flushTLB(virtualAddress);
        return;
    }

    widenEntryPermissions(&page_directory[page_directory_index], flags);
    flushTLB(virtualAddress);
}

pub fn unmapPage(virtualAddress: usize) void {
    const walk = walkToPageTable(getCurrentAddressSpaceRoot(), virtualAddress) orelse return;
    walk.page_table[walk.page_table_index].present = false;
    flushTLB(virtualAddress);
}

fn directMapVirtualAddress() usize {
    return limine_requests.hhdmOffset();
}

pub fn getKernelVirtualAddressStart() u64 {
    return common.KERNEL_VIRTUAL_ADDRESS;
}

pub fn getDirectMapVirtualAddress() u64 {
    return directMapVirtualAddress();
}

pub fn getDirectMapMaxSize() u64 {
    return common.DIRECT_MAP_SIZE;
}

pub fn getKernelHeapVirtualAddress() u64 {
    return common.KERNEL_HEAP_VIRTUAL_ADDRESS;
}

pub fn getKernelHeapSize() u64 {
    return common.KERNEL_HEAP_SIZE;
}

pub fn getPageSize() usize {
    return common.PAGE_SIZE;
}

pub fn getPageTableRegionSize() usize {
    return common.PAGE_TABLE_REGION_SIZE;
}

pub fn removeIdentityMapping() void {}

fn walkToPageTable(root: arch.AddressSpaceRoot, virtualAddress: usize) ?PageWalk {
    const pml4 = getPageTableFromPhysical(root.value);
    const pml4_index = pml4Index(virtualAddress);
    const pdpt_index = pdptIndex(virtualAddress);
    const page_directory_index = pageDirectoryIndex(virtualAddress);

    if (!pml4[pml4_index].present) return null;
    const pdpt = getNextLevelTable(pml4[pml4_index]);

    if (!pdpt[pdpt_index].present or pdpt[pdpt_index].page_size) return null;
    const page_directory = getNextLevelTable(pdpt[pdpt_index]);

    if (!page_directory[page_directory_index].present or page_directory[page_directory_index].page_size) return null;
    const page_table = getNextLevelTable(page_directory[page_directory_index]);

    return .{
        .pml4 = pml4,
        .pdpt = pdpt,
        .page_directory = page_directory,
        .page_table = page_table,
        .pml4_index = pml4_index,
        .pdpt_index = pdpt_index,
        .page_directory_index = page_directory_index,
        .page_table_index = pageTableIndex(virtualAddress),
    };
}

fn widenIntermediatePermissions(walk: PageWalk, flags: arch.PageProtection) void {
    widenEntryPermissions(&walk.pml4[walk.pml4_index], flags);
    widenEntryPermissions(&walk.pdpt[walk.pdpt_index], flags);
    widenEntryPermissions(&walk.page_directory[walk.page_directory_index], flags);
}

fn widenEntryPermissions(entry: *common.PageEntry, flags: arch.PageProtection) void {
    entry.writeable = entry.writeable or flags.write;
    entry.user_accessible = entry.user_accessible or flags.user;
    entry.no_execute = entry.no_execute and !flags.execute;
}

fn makeTableEntry(physicalAddress: usize, flags: arch.PageProtection) common.PageEntry {
    return makeEntry(physicalAddress, .{
        .write = true,
        .user = flags.user,
        .execute = flags.execute,
        .global = flags.global,
    });
}

fn makePageEntry(physicalAddress: usize, flags: arch.PageProtection) common.PageEntry {
    return makeEntry(physicalAddress, flags);
}

fn makeEntry(physicalAddress: usize, flags: arch.PageProtection) common.PageEntry {
    return .{
        .address = @truncate(physicalAddress >> 12),
        .present = true,
        .writeable = flags.write,
        .user_accessible = flags.user,
        .global = flags.global,
        .no_execute = !flags.execute,
    };
}

fn clearPageTable(physicalAddress: usize) void {
    const page_table = getPageTableFromPhysical(physicalAddress);
    for (page_table) |*entry| {
        entry.* = .{};
    }
}

fn allocatePageTablePhysicalAddress() !usize {
    return @intFromPtr(try arch.early_allocator.allocate(
        common.PAGE_SIZE,
        common.PAGE_SIZE,
        arch.ReservedMapRegionType.PERSISTENT,
    ));
}

inline fn getPageTableFromPhysical(physicalAddress: usize) common.PageTable {
    return @ptrFromInt((physicalAddress & ~@as(usize, 0xFFF)) + directMapVirtualAddress());
}

inline fn getNextLevelTable(entry: common.PageEntry) common.PageTable {
    return getPageTableFromPhysical(pageBasePhysicalAddress(entry));
}

inline fn pageBasePhysicalAddress(entry: common.PageEntry) usize {
    return @as(usize, entry.address) << 12;
}

inline fn flushTLB(virtualAddress: usize) void {
    asm volatile ("invlpg (%[address])"
        :
        : [address] "r" (virtualAddress),
        : .{ .memory = true });
}

inline fn pml4Index(virtualAddress: usize) usize {
    return (virtualAddress >> 39) & 0x1FF;
}

inline fn pdptIndex(virtualAddress: usize) usize {
    return (virtualAddress >> 30) & 0x1FF;
}

inline fn pageDirectoryIndex(virtualAddress: usize) usize {
    return (virtualAddress >> 21) & 0x1FF;
}

inline fn pageTableIndex(virtualAddress: usize) usize {
    return (virtualAddress >> 12) & 0x1FF;
}

inline fn pageOffset(virtualAddress: usize) usize {
    return virtualAddress & 0xFFF;
}
