pub const PAGE_SIZE = 4096;

pub const KERNEL_VIRTUAL_ADDRESS = 0xFFFFFFFF80000000;

pub const ENTRIES_PER_TABLE: usize = 512;
pub const ENTRIES_PER_DIRECTORY: usize = ENTRIES_PER_TABLE;

pub const PAGE_TABLE_REGION_SIZE = PAGE_SIZE * ENTRIES_PER_TABLE;

pub const DIRECT_MAP_VIRTUAL_ADDRESS = 0xC0000000;
pub const DIRECT_MAP_SIZE = 768 * 1024 * 1024;

pub const RESERVED_VIRTUAL_ADDRESS = 0xF8000000;
pub const RESERVED_SIZE = 128 * 1024 * 1024;

pub const PML4_HIGHER_HALF_INDEX = 256;

pub const PageEntry = packed struct {
    present: bool = false,
    writeable: bool = false,
    user_accessible: bool = false,
    write_through: bool = false,
    cache_disabled: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    page_size: bool = false,
    global: bool = false,
    available_low: u3 = 0,
    address: u40 = 0,
    available_high: u11 = 0,
    no_execute: bool = false,
};

pub const PageTableRoot = *[ENTRIES_PER_TABLE]PageEntry;
pub const PageDirectory = PageTableRoot;
pub const PageTable = *[ENTRIES_PER_TABLE]PageEntry;

pub fn alignForward(
    value: usize,
    alignment: usize,
) error{ InvalidBootstrapMapping, BootstrapMappingOverflow }!usize {
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
        return error.InvalidBootstrapMapping;
    }

    return (try checkedAdd(value, alignment - 1)) & ~(alignment - 1);
}

pub fn checkedAdd(left: usize, right: usize) error{BootstrapMappingOverflow}!usize {
    const result = left +% right;
    if (result < left) {
        return error.BootstrapMappingOverflow;
    }

    return result;
}

pub fn checkedMultiply(left: usize, right: usize) error{PageTableAllocationOverflow}!usize {
    const maximum_usize = ~@as(usize, 0);
    if (left != 0 and right > maximum_usize / left) {
        return error.PageTableAllocationOverflow;
    }

    return left * right;
}
