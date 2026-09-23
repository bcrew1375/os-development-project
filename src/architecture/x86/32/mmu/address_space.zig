const arch = @import("arch");

const common = @import("common.zig");

pub fn createAddressSpaceRoot() arch.MmuError!arch.AddressSpaceRoot {
    const page_directory_physical_address = arch.page_table_pool.allocateRootFrame() catch |err| {
        return switch (err) {
            error.PoolExhausted => arch.MmuError.PageTablePoolExhausted,
            else => arch.MmuError.AddressSpaceRootAllocationFailed,
        };
    };
    const page_directory = getDirectMapPageDirectory(page_directory_physical_address);
    clearPageDirectory(page_directory);
    cloneKernelMappings(page_directory);

    return .{
        .value = page_directory_physical_address,
    };
}

pub fn destroyAddressSpaceRoot(root: arch.AddressSpaceRoot) void {
    arch.page_table_pool.freeAddressSpace(root);
}

pub fn switchAddressSpaceRoot(root: arch.AddressSpaceRoot) void {
    switchPageDirectoryPhysical(root.value);
}

fn getDirectMapPageDirectory(page_directory_physical_address: usize) common.PageDirectory {
    return @ptrFromInt(page_directory_physical_address + common.DIRECT_MAP_VIRTUAL_ADDRESS);
}

fn clearPageDirectory(page_directory: common.PageDirectory) void {
    for (page_directory) |*entry| {
        entry.* = .{};
    }
}

fn cloneKernelMappings(page_directory: common.PageDirectory) void {
    const current_page_directory = getCurrentPageDirectory();

    // Runtime address-space creation still uses bootstrap code and allocator
    // state linked into the identity-mapped multiboot region. Keep that
    // supervisor-only mapping available after switching away from the initial
    // kernel page directory.
    page_directory[0] = current_page_directory[0];

    for (common.HIGHER_HALF_INDEX..common.ENTRIES_PER_DIRECTORY) |directory_index| {
        page_directory[directory_index] = current_page_directory[directory_index];
    }
}

fn getCurrentPageDirectory() common.PageDirectory {
    var cr3: usize = undefined;
    asm volatile ("mov %cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );
    return @ptrFromInt(cr3 + common.DIRECT_MAP_VIRTUAL_ADDRESS);
}

inline fn switchPageDirectoryPhysical(page_directory_physical_address: usize) void {
    asm volatile (
        \\mov %[pageDirectoryPhysicalAddress], %eax
        \\mov %eax, %cr3
        :
        : [pageDirectoryPhysicalAddress] "r" (page_directory_physical_address),
        : .{ .eax = true, .memory = true });
}
