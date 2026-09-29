//! Byte-level reads and writes into a prepared user address space.
//!
//! The mapping calls in `vmm` act on whichever address space the caller
//! activated, so this module resolves virtual addresses through the explicit
//! address-space root it is given and writes via the direct map.

const arch = @import("arch");
const kernel_common = @import("kernel_common");

const errors = @import("errors.zig");

const vmm = kernel_common.memory_management.virtual_memory;

pub const readWriteUserPagePermissions = vmm.MemoryPermissions{
    .readable = true,
    .writeable = true,
    .executable = false,
    .user_accessible = true,
};

pub const readOnlyUserPagePermissions = vmm.MemoryPermissions{
    .readable = true,
    .writeable = false,
    .executable = false,
    .user_accessible = true,
};

pub fn copyIntoUserSpace(
    page_table_root: arch.AddressSpaceRoot,
    virtual_address: u64,
    source: []const u8,
) !void {
    var address = virtual_address;
    var remaining = source;
    while (remaining.len > 0) {
        const destination = try userSpacePageSlice(page_table_root, address, remaining.len);
        @memcpy(destination, remaining[0..destination.len]);
        address += destination.len;
        remaining = remaining[destination.len..];
    }
}

pub fn zeroUserSpace(
    page_table_root: arch.AddressSpaceRoot,
    virtual_address: u64,
    byte_count: u64,
) !void {
    var address = virtual_address;
    var remaining_len: usize = @intCast(byte_count);
    while (remaining_len > 0) {
        const destination = try userSpacePageSlice(page_table_root, address, remaining_len);
        @memset(destination, 0);
        address += destination.len;
        remaining_len -= destination.len;
    }
}

/// The direct-mapped bytes of `virtual_address`'s physical page, truncated
/// to `max_len` and to the end of that page (a direct-map pointer is only
/// valid within a single physical page).
fn userSpacePageSlice(
    page_table_root: arch.AddressSpaceRoot,
    virtual_address: u64,
    max_len: usize,
) ![]u8 {
    const page_size = arch.mmu.getPageSize();
    const address: usize = @intCast(virtual_address);
    const page_offset = address & (page_size - 1);
    const page_remaining = page_size - page_offset;

    const page = try directMapPagePointer(page_table_root, address);
    return page[0..@min(page_remaining, max_len)];
}

fn directMapPagePointer(page_table_root: arch.AddressSpaceRoot, virtual_address: usize) ![*]u8 {
    const physical_address = arch.mmu.getPhysicalAddressInAddressSpace(page_table_root, virtual_address) orelse {
        return errors.RootProcessLaunchError.RootAddressSpaceMappingMissing;
    };
    const direct_map_base: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    return @ptrFromInt(direct_map_base + physical_address);
}
