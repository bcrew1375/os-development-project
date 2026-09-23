//! Early-boot bootstrap paging.
//!
//! Runs before the kernel's real allocator/paging exist, so every
//! function and static below is pinned to the `.multiboot.*` linker
//! sections. That's why `linksection(...)` appears on nearly every
//! declaration - it is a hard physical constraint of this boot stage
//! (nothing else has been mapped yet), not repeated style noise, and
//! it should stay even though it's visually heavy.
//!
//! SUGGESTED FILE SPLIT
//! =====================
//! This file currently mixes two unrelated concerns: bootstrap page
//! table setup, and multiboot memory-map parsing. They happen to run
//! around the same point in boot, but neither calls into the other,
//! and "how does paging bootstrap work" and "how do we learn what
//! memory exists" are two different questions a reader shouldn't have
//! to interleave. Recommended split:
//!
//!   1. bootstrap_paging.zig (this file, trimmed to just this)
//!        - Section, LinkerRange, bootstrap_ranges, region constants
//!        - initializePaging() and everything initializePaging calls
//!
//!   2. memory_map.zig                                    <- MOVE
//!        - MultibootMemoryMapEntry, MultibootMemoryMapRegionTypes
//!        - memoryMap, maxAvailableAddress (module-level state)
//!        - readMultibootMemoryMap, getMemoryMap, getMaxAvailableAddress
//!        Self-contained: only needs `arch` and `multiboot`, never
//!        touches anything paging-related in this file.
//!
//!   3. common.zig (existing file)                        <- MOVE
//!        - checkedAdd, checkedMultiply, alignForward
//!        These are generic overflow-checked arithmetic with no
//!        dependency on paging or multiboot state. Leaving them here
//!        means any other early-boot code that needs checked math
//!        either duplicates them or takes an unnecessary dependency
//!        on this file. They belong wherever `common`'s other
//!        boot-safe primitives already live.
//!
//!   4. getDirectMapVirtualAddress / getDirectMapMaxSize   <- MOVE or DELETE
//!        Both just forward to `common.DIRECT_MAP_VIRTUAL_ADDRESS` /
//!        `common.DIRECT_MAP_SIZE` and touch no state owned by this
//!        file. Either move them next to those constants in
//!        common.zig, or delete them and have callers read the
//!        constants directly - as written they're indirection with
//!        no behavior attached.

const build_options = @import("build_options");
const boot_text_section = if (build_options.x86_32_multiboot) ".multiboot.text" else ".text";
const boot_data_section = if (build_options.x86_32_multiboot) ".multiboot.data" else ".data";
const arch = @import("arch");
const multiboot = @import("../boot/multiboot/main.zig");

const common = @import("common.zig");

/// Full error space for the bootstrap-paging entry point. Individual
/// helpers below declare their own narrower error sets - only the
/// entry point needs to expose the whole union to its caller.
const EarlyPagingError = arch.EarlyAllocError || error{
    BootstrapMappingOverflow,
    InvalidBootstrapMapping,
    KernelImageTooLarge,
    PageTableAllocationOverflow,
};

const PageEntryFlags = struct {
    writeable: bool = false,
    user_accessible: bool = false,
    global: bool = false,
    cache_disabled: bool = false,
};

extern const _kernel_end: usize;

// ============================================================
// Bootstrap page table setup
// ============================================================
//
// initializePaging is the single control-flow entry point for this
// subsystem: every branch/error decision that matters lives here or
// in the functions it directly calls. Everything below it is either
// a pure computation (no branching a caller needs to know about) or
// a validation pass with its own fully-contained checks - nothing
// here calls back "up" into a sibling that also branches.

pub fn initializePaging() linksection(boot_text_section) EarlyPagingError!void {
    try validateKernelFitsDirectMap(@intFromPtr(&_kernel_end));
    const direct_map_page_table_count = try calculateDirectMapPageTableCount();
    const reserved_page_table_count = common.RESERVED_SIZE / common.PAGE_TABLE_REGION_SIZE;
    const needed_page_tables = try common.checkedAdd(direct_map_page_table_count, reserved_page_table_count);

    const kernel_page_directory_entries = try allocatePageDirectory();
    const direct_map_entries = try allocatePageTables(needed_page_tables);
    const reserved_map = arch.early_allocator.getReservedMap();

    initializeBootstrapMappings(kernel_page_directory_entries, direct_map_entries[0..direct_map_page_table_count], reserved_map);
    initializeReservedMappings(kernel_page_directory_entries, direct_map_entries[direct_map_page_table_count..], reserved_map);
    activatePaging(kernel_page_directory_entries);
}

fn validateKernelFitsDirectMap(
    kernel_end_address: usize,
) linksection(boot_text_section) error{ InvalidBootstrapMapping, BootstrapMappingOverflow, KernelImageTooLarge }!void {
    if (kernel_end_address == 0) {
        return error.InvalidBootstrapMapping;
    }

    if (kernel_end_address > common.DIRECT_MAP_SIZE) {
        return error.KernelImageTooLarge;
    }
}

fn calculateDirectMapPageTableCount() linksection(boot_text_section) error{ InvalidBootstrapMapping, BootstrapMappingOverflow, KernelImageTooLarge }!usize {
    const aligned_direct_map_size = try common.alignForward(common.DIRECT_MAP_SIZE, common.PAGE_TABLE_REGION_SIZE);
    const page_table_count = aligned_direct_map_size / common.PAGE_TABLE_REGION_SIZE;

    if (page_table_count == 0) {
        return error.InvalidBootstrapMapping;
    }

    if (page_table_count > common.HIGHER_HALF_INDEX) {
        return error.KernelImageTooLarge;
    }

    if (common.HIGHER_HALF_INDEX + page_table_count > common.ENTRIES_PER_DIRECTORY) {
        return error.KernelImageTooLarge;
    }

    return page_table_count;
}

fn allocatePageDirectory() linksection(boot_text_section) (arch.EarlyAllocError || error{PageTableAllocationOverflow})!common.PageDirectory {
    const allocation_size = try common.checkedMultiply(@sizeOf(common.PageEntry), common.ENTRIES_PER_DIRECTORY);
    const page_directory: common.PageDirectory = @ptrCast(@alignCast(try arch.early_allocator.allocate(
        allocation_size,
        common.PAGE_SIZE,
        arch.ReservedMapRegionType.PERSISTENT,
    )));

    clearPageEntries(page_directory, common.ENTRIES_PER_DIRECTORY);

    return page_directory;
}

fn allocatePageTables(
    page_table_count: usize,
) linksection(boot_text_section) (arch.EarlyAllocError || error{PageTableAllocationOverflow})![][common.ENTRIES_PER_TABLE]common.PageEntry {
    const page_table_size = try common.checkedMultiply(@sizeOf(common.PageEntry), common.ENTRIES_PER_TABLE);
    const allocation_size = try common.checkedMultiply(page_table_count, page_table_size);
    const page_tables_ptr = try arch.early_allocator.allocate(
        allocation_size,
        common.PAGE_SIZE,
        arch.ReservedMapRegionType.PERSISTENT,
    );
    const page_tables: [][common.ENTRIES_PER_TABLE]common.PageEntry = @as(
        [*][common.ENTRIES_PER_TABLE]common.PageEntry,
        @ptrCast(@alignCast(page_tables_ptr)),
    )[0..page_table_count];

    for (page_tables) |*page_table| {
        clearPageEntries(@ptrCast(page_table), common.ENTRIES_PER_TABLE);
    }

    return page_tables;
}

fn clearPageEntries(
    page_entries: [*]volatile common.PageEntry,
    entry_count: usize,
) linksection(boot_text_section) void {
    var entry_index: usize = 0;
    while (entry_index < entry_count) : (entry_index += 1) {
        page_entries[entry_index] = .{};
    }
}

fn initializeBootstrapMappings(
    page_directory: common.PageDirectory,
    page_tables: [][common.ENTRIES_PER_TABLE]common.PageEntry,
    reserved_map: *const arch.ReservedMap,
) linksection(boot_text_section) void {
    for (page_tables, 0..) |*page_table, directory_index| {
        const directory_entry = makePageDirectoryEntry(page_table);

        page_directory[directory_index] = directory_entry;
        page_directory[common.HIGHER_HALF_INDEX + directory_index] = directory_entry;

        initializePageTable(page_table, directory_index, reserved_map);
    }
}

fn initializeReservedMappings(
    page_directory: common.PageDirectory,
    page_tables: [][common.ENTRIES_PER_TABLE]common.PageEntry,
    reserved_map: *const arch.ReservedMap,
) linksection(boot_text_section) void {
    const reserved_directory_index = common.RESERVED_VIRTUAL_ADDRESS / common.PAGE_TABLE_REGION_SIZE;

    for (page_tables, 0..) |*page_table, table_offset| {
        page_directory[reserved_directory_index + table_offset] = makePageDirectoryEntry(page_table);

        clearPageEntries(@ptrCast(page_table), common.ENTRIES_PER_TABLE);
    }

    mapFramebufferIntoReservedWindow(page_directory, reserved_map);
}

fn mapFramebufferIntoReservedWindow(page_directory: common.PageDirectory, reserved_map: *const arch.ReservedMap) linksection(boot_text_section) void {
    const framebuffer_physical_start = multiboot.framebufferPhysicalAddress() orelse return;
    const framebuffer_size = multiboot.framebufferByteSize() orelse return;
    const framebuffer_physical_end = framebuffer_physical_start +| framebuffer_size;

    const page_mask = ~@as(usize, common.PAGE_SIZE - 1);
    const aligned_physical_start = framebuffer_physical_start & page_mask;
    const aligned_physical_end = (framebuffer_physical_end +| common.PAGE_SIZE - 1) & page_mask;
    const mapped_size = aligned_physical_end -| aligned_physical_start;
    if (mapped_size > common.RESERVED_SIZE) {
        return;
    }

    var physical_address = aligned_physical_start;
    var virtual_address: usize = common.RESERVED_VIRTUAL_ADDRESS;
    while (physical_address < aligned_physical_end) : ({
        physical_address += common.PAGE_SIZE;
        virtual_address += common.PAGE_SIZE;
    }) {
        const page_directory_index = virtual_address / common.PAGE_TABLE_REGION_SIZE;
        const page_table_index = (virtual_address / common.PAGE_SIZE) % common.ENTRIES_PER_TABLE;
        const page_table = getBootstrapPageTable(page_directory, page_directory_index);

        page_table[page_table_index] = makePageEntry(physical_address, flagsForPhysicalPage(physical_address, reserved_map));
    }
}

fn initializePageTable(
    page_table: *[common.ENTRIES_PER_TABLE]common.PageEntry,
    directory_index: usize,
    reserved_map: *const arch.ReservedMap,
) linksection(boot_text_section) void {
    for (page_table, 0..) |*entry, table_index| {
        const physical_address = (directory_index * common.PAGE_TABLE_REGION_SIZE) + (table_index * common.PAGE_SIZE);

        entry.* = makePageEntry(physical_address, flagsForPhysicalPage(physical_address, reserved_map));
    }
}

fn flagsForPhysicalPage(physical_address: usize, reserved_map: *const arch.ReservedMap) linksection(boot_text_section) PageEntryFlags {
    const physical_page_end = physical_address + common.PAGE_SIZE;
    var found_reservation = false;
    var writeable = false;
    var user_accessible = false;
    var global = false;
    var cache_disabled = false;

    for (reserved_map.entries[0..reserved_map.length]) |reservation| {
        const reservation_end = reservation.address +| reservation.size;
        if (physical_address < reservation_end and physical_page_end > reservation.address) {
            found_reservation = true;
            const reservation_flags = flagsForReservationType(reservation.region_type);

            writeable = writeable or reservation_flags.writeable;
            user_accessible = user_accessible or reservation_flags.user_accessible;
            global = global or reservation_flags.global;
            cache_disabled = cache_disabled or reservation_flags.cache_disabled;
        }
    }

    if (!found_reservation) {
        writeable = true;
    }

    return .{
        .writeable = writeable,
        .user_accessible = user_accessible,
        .global = global,
        .cache_disabled = cache_disabled,
    };
}

fn flagsForReservationType(region_type: arch.ReservedMapRegionType) linksection(boot_text_section) PageEntryFlags {
    var writeable = false;
    var cache_disabled = false;

    switch (region_type) {
        arch.ReservedMapRegionType.KERNEL_READ_ONLY => {},
        arch.ReservedMapRegionType.DEVICE_MEMORY => {
            writeable = true;
            cache_disabled = true;
        },
        arch.ReservedMapRegionType.TEMPORARY,
        arch.ReservedMapRegionType.PERSISTENT,
        arch.ReservedMapRegionType.KERNEL_WRITABLE,
        arch.ReservedMapRegionType.BOOTLOADER_DATA,
        => writeable = true,
    }

    return .{
        .writeable = writeable,
        .user_accessible = false,
        .global = false,
        .cache_disabled = cache_disabled,
    };
}

fn makePageDirectoryEntry(page_table: *[common.ENTRIES_PER_TABLE]common.PageEntry) linksection(boot_text_section) common.PageEntry {
    return .{
        .address = @truncate(getBootstrapPhysicalAddress(@intFromPtr(page_table)) >> 12),
        .present = true,
        .writeable = true,
        .user_accessible = false,
    };
}

fn makePageEntry(physical_address: usize, flags: PageEntryFlags) linksection(boot_text_section) common.PageEntry {
    return .{
        .address = @truncate(physical_address >> 12),
        .present = true,
        .writeable = flags.writeable,
        .user_accessible = flags.user_accessible,
        .cache_disabled = flags.cache_disabled,
        .global = flags.global,
    };
}

fn getBootstrapPageTable(page_directory: common.PageDirectory, directory_index: usize) linksection(boot_text_section) common.PageTable {
    const physical_address = @as(usize, page_directory[directory_index].address) << 12;
    return @ptrFromInt(physical_address);
}

fn getBootstrapPhysicalAddress(address: usize) linksection(boot_text_section) usize {
    if (address >= common.DIRECT_MAP_VIRTUAL_ADDRESS) {
        return address - common.DIRECT_MAP_VIRTUAL_ADDRESS;
    }

    return address;
}

fn activatePaging(page_directory: common.PageDirectory) linksection(boot_text_section) void {
    @disableInstrumentation();
    const page_directory_physical_address = getBootstrapPhysicalAddress(@intFromPtr(page_directory));

    asm volatile (
        \\pusha
        \\mov %[pageDirectoryAddress], %eax
        \\mov %eax, %cr3
        // Enable paging.
        \\mov %cr0, %eax
        \\or $0x80010000, %eax
        \\mov %eax, %cr0
        \\popa
        :
        : [pageDirectoryAddress] "r" (page_directory_physical_address),
        : .{ .eax = true, .memory = true });
}

// ============================================================
// MOVE: multiboot memory map -> memory_map.zig
// ============================================================
//
// Everything from here down is a separate subsystem: parsing and
// caching the multiboot-provided memory map. It shares no state and
// no call relationship with bootstrap paging above - it just happens
// to run around the same point in boot. See the file-level doc
// comment at the top for the suggested split.
