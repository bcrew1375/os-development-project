const arch = @import("arch");

const common = @import("common.zig");
const limine_requests = @import("../../common/boot/limine/requests.zig");

pub fn createAddressSpaceRoot() arch.MmuError!arch.AddressSpaceRoot {
    const page_table_root_physical_address = allocatePageTableRoot() catch {
        return arch.MmuError.AddressSpaceRootAllocationFailed;
    };
    const page_table_root = getDirectMapPageTableRoot(page_table_root_physical_address);

    cloneKernelMappings(page_table_root);

    return .{
        .value = page_table_root_physical_address,
    };
}

/// Page-table storage is early-allocator owned until delegated reclamation exists.
pub fn destroyAddressSpaceRoot(root: arch.AddressSpaceRoot) void {
    _ = root;
}

pub fn switchAddressSpaceRoot(root: arch.AddressSpaceRoot) void {
    switchPageDirectoryPhysical(root.value);
}

fn allocatePageTableRoot() arch.EarlyAllocError!usize {
    const allocation_size = @sizeOf(common.PageEntry) * common.ENTRIES_PER_TABLE;
    const page_table_root_physical_address = @intFromPtr(try arch.early_allocator.allocate(
        allocation_size,
        common.PAGE_SIZE,
        arch.ReservedMapRegionType.PERSISTENT,
    ));
    const page_table_root = getDirectMapPageTableRoot(page_table_root_physical_address);

    clearPageTable(page_table_root);

    return page_table_root_physical_address;
}

fn getDirectMapPageTableRoot(page_table_root_physical_address: usize) common.PageTableRoot {
    return @ptrFromInt(page_table_root_physical_address + directMapVirtualAddress());
}

fn directMapVirtualAddress() usize {
    return limine_requests.hhdmOffset();
}

fn clearPageTable(page_table: common.PageTable) void {
    for (page_table) |*entry| {
        entry.* = .{};
    }
}

fn cloneKernelMappings(page_table_root: common.PageTableRoot) void {
    const current_page_table_root = getCurrentPageTableRoot();

    for (common.PML4_HIGHER_HALF_INDEX..common.ENTRIES_PER_TABLE) |root_index| {
        page_table_root[root_index] = current_page_table_root[root_index];
    }
}

fn getCurrentPageTableRoot() common.PageTableRoot {
    var cr3: usize = undefined;
    asm volatile ("mov %cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );
    return @ptrFromInt((cr3 & ~@as(usize, 0xFFF)) + directMapVirtualAddress());
}

inline fn switchPageDirectoryPhysical(page_directory_physical_address: usize) void {
    asm volatile ("mov %[pageDirectoryPhysicalAddress], %cr3"
        :
        : [pageDirectoryPhysicalAddress] "r" (page_directory_physical_address),
        : .{ .memory = true });
}
