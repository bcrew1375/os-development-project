//! Common virtual memory area manager and demand-mapping helpers.

const arch = @import("arch");
const abi = @import("abi");

const pmm = @import("pmm.zig");

/// Errors produced by virtual memory operations.
pub const VMMError = error{
    UndefinedAddressSpace,
    OverlappingVirtualMemoryArea,
    UndefinedVirtualMemoryArea,
    OutOfVirtualMemoryAreas,
    InvalidVirtualMemoryAreaRange,
    UnalignedVirtualMemoryArea,
    FaultBeforeMemoryManagementActive,
    FaultOutsideVirtualMemoryArea,
    ProtectionViolation,
    PhysicalMemoryAllocationFailed,
    MappingFailed,
};

/// Defines the access rights for a specific virtual memory mapping.
pub const MemoryPermissions = struct {
    readable: bool,
    writeable: bool,
    executable: bool,
    user_accessible: bool,
};

/// Virtual memory area tracked in an address space.
pub const VirtualMemoryArea = struct {
    start_address: u64 = undefined,
    end_address: u64 = undefined,
    permissions: MemoryPermissions = undefined,
    memory_object_handle: u32 = abi.syscall.INVALID_HANDLE,
    memory_object_offset: u64 = 0,
};

/// Common address-space metadata backed by caller-provided VMA storage.
pub const AddressSpace = struct {
    virtual_memory_areas: []VirtualMemoryArea = undefined,
    length: usize = 0,
};

var currentAddressSpace: *AddressSpace = undefined;

/// Sets the active common address-space metadata for fault handling.
pub fn setAddressSpace(addressSpace: *AddressSpace) void {
    currentAddressSpace = addressSpace;
}

/// Reserves a virtual range without eagerly allocating backing frames.
pub fn map(addressSpace: *AddressSpace, startAddress: u64, endAddress: u64, memoryPermissions: MemoryPermissions) !void {
    try mapObject(addressSpace, startAddress, endAddress, memoryPermissions, abi.syscall.INVALID_HANDLE, 0);
}

/// Reserves and immediately backs a virtual range in the current hardware address space.
/// Mapping failures preserve the VMA and any pages mapped before the failure.
pub fn mapEager(addressSpace: *AddressSpace, startAddress: u64, endAddress: u64, memoryPermissions: MemoryPermissions) !void {
    try map(addressSpace, startAddress, endAddress, memoryPermissions);

    const pageSize: u64 = @intCast(arch.mmu.getPageSize());
    var pageAddress = startAddress;
    while (pageAddress < endAddress) : (pageAddress += pageSize) {
        try mapAllocatedPage(@intCast(pageAddress), memoryPermissions);
    }
}

/// Reserves and immediately backs a virtual range in `root`.
/// Mapping failures preserve the VMA and any pages mapped before the failure.
pub fn mapEagerInAddressSpace(root: arch.AddressSpaceRoot, addressSpace: *AddressSpace, startAddress: u64, endAddress: u64, memoryPermissions: MemoryPermissions) !void {
    try map(addressSpace, startAddress, endAddress, memoryPermissions);

    const pageSize: u64 = @intCast(arch.mmu.getPageSize());
    var pageAddress = startAddress;
    while (pageAddress < endAddress) : (pageAddress += pageSize) {
        try mapAllocatedPageInAddressSpace(root, @intCast(pageAddress), memoryPermissions);
    }
}

/// Maps bootstrap-time contiguous physical pages for a virtual range in `root`.
/// Mapping failures preserve the VMA and any pages mapped before the failure.
pub fn mapBootstrapContiguousInAddressSpace(
    root: arch.AddressSpaceRoot,
    addressSpace: *AddressSpace,
    startAddress: u64,
    endAddress: u64,
    memoryPermissions: MemoryPermissions,
) !void {
    try map(addressSpace, startAddress, endAddress, memoryPermissions);
    try mapBootstrapContiguousPagesInAddressSpace(root, startAddress, endAddress, memoryPermissions);
}

/// Updates permissions for an existing VMA and any currently mapped pages.
/// Mapping failures preserve earlier page updates but leave VMA metadata unchanged.
pub fn protect(addressSpace: *AddressSpace, startAddress: u64, endAddress: u64, memoryPermissions: MemoryPermissions) !void {
    const vma = findVirtualMemoryAreaByRange(addressSpace, startAddress, endAddress) orelse return VMMError.UndefinedVirtualMemoryArea;

    const pageSize: u64 = @intCast(arch.mmu.getPageSize());
    var pageAddress = startAddress;
    while (pageAddress < endAddress) : (pageAddress += pageSize) {
        const virtualAddress: usize = @intCast(pageAddress);
        const physicalAddress = arch.mmu.getPhysicalAddress(virtualAddress) orelse continue;
        arch.mmu.mapPage(virtualAddress, physicalAddress & ~(arch.mmu.getPageSize() - 1), .{
            .write = memoryPermissions.writeable,
            .user = memoryPermissions.user_accessible,
            .execute = memoryPermissions.executable,
        }) catch {
            return VMMError.MappingFailed;
        };
    }

    vma.permissions = memoryPermissions;
}

/// Updates permissions for an existing VMA and mapped pages in `root`.
/// Mapping failures preserve earlier page updates but leave VMA metadata unchanged.
pub fn protectInAddressSpace(root: arch.AddressSpaceRoot, addressSpace: *AddressSpace, startAddress: u64, endAddress: u64, memoryPermissions: MemoryPermissions) !void {
    const vma = findVirtualMemoryAreaByRange(addressSpace, startAddress, endAddress) orelse return VMMError.UndefinedVirtualMemoryArea;

    const pageSize: u64 = @intCast(arch.mmu.getPageSize());
    var pageAddress = startAddress;
    while (pageAddress < endAddress) : (pageAddress += pageSize) {
        const virtualAddress: usize = @intCast(pageAddress);
        const physicalAddress = arch.mmu.getPhysicalAddressInAddressSpace(root, virtualAddress) orelse continue;
        arch.mmu.mapPageInAddressSpace(root, virtualAddress, physicalAddress & ~(arch.mmu.getPageSize() - 1), .{
            .write = memoryPermissions.writeable,
            .user = memoryPermissions.user_accessible,
            .execute = memoryPermissions.executable,
        }) catch {
            return VMMError.MappingFailed;
        };
    }

    vma.permissions = memoryPermissions;
}

/// Reserves a virtual range backed by a memory object and offset.
pub fn mapObject(
    addressSpace: *AddressSpace,
    startAddress: u64,
    endAddress: u64,
    memoryPermissions: MemoryPermissions,
    memoryObjectHandle: u32,
    memoryObjectOffset: u64,
) !void {
    if (addressSpace.virtual_memory_areas.len == 0) {
        return VMMError.UndefinedAddressSpace;
    }

    if (addressSpace.length >= addressSpace.virtual_memory_areas.len) {
        return VMMError.OutOfVirtualMemoryAreas;
    }

    if (startAddress >= endAddress) {
        return VMMError.InvalidVirtualMemoryAreaRange;
    }

    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    if ((startAddress % page_size != 0) or (endAddress % page_size != 0)) {
        return VMMError.UnalignedVirtualMemoryArea;
    }

    for (addressSpace.virtual_memory_areas[0..addressSpace.length]) |vma| {
        if ((startAddress < vma.end_address) and (endAddress > vma.start_address)) {
            return VMMError.OverlappingVirtualMemoryArea;
        }
    }

    addressSpace.virtual_memory_areas[addressSpace.length].start_address = startAddress;
    addressSpace.virtual_memory_areas[addressSpace.length].end_address = endAddress;
    addressSpace.virtual_memory_areas[addressSpace.length].permissions = memoryPermissions;
    addressSpace.virtual_memory_areas[addressSpace.length].memory_object_handle = memoryObjectHandle;
    addressSpace.virtual_memory_areas[addressSpace.length].memory_object_offset = memoryObjectOffset;

    addressSpace.length += 1;
}

/// Removes an exact VMA and unmaps pages in the current hardware address space.
pub fn unmap(addressSpace: *AddressSpace, startAddress: u64, endAddress: u64) VMMError!void {
    try unmapInAddressSpace(null, addressSpace, startAddress, endAddress);
}

/// Removes an exact VMA and unmaps pages in `root`. Repeated removal reports
/// `UndefinedVirtualMemoryArea`; low-level page unmapping itself is idempotent.
pub fn unmapInAddressSpace(
    root: ?arch.AddressSpaceRoot,
    addressSpace: *AddressSpace,
    startAddress: u64,
    endAddress: u64,
) VMMError!void {
    const vma_index = findVirtualMemoryAreaIndex(addressSpace, startAddress, endAddress) orelse
        return VMMError.UndefinedVirtualMemoryArea;
    const page_size = @as(u64, @intCast(arch.mmu.getPageSize()));
    var page_address = startAddress;
    while (page_address < endAddress) : (page_address += page_size) {
        if (root) |address_space_root| {
            _ = arch.mmu.unmapPageInAddressSpace(address_space_root, @intCast(page_address));
        } else {
            _ = arch.mmu.unmapPage(@intCast(page_address));
        }
    }

    removeVirtualMemoryArea(addressSpace, vma_index);
}

/// Returns the exact VMA covering the supplied range.
pub fn query(
    addressSpace: *AddressSpace,
    startAddress: u64,
    endAddress: u64,
) VMMError!VirtualMemoryArea {
    const index = findVirtualMemoryAreaIndex(addressSpace, startAddress, endAddress) orelse
        return VMMError.UndefinedVirtualMemoryArea;
    return addressSpace.virtual_memory_areas[index];
}

/// Panic-on-error wrapper around `resolveFault`.
pub fn faultHandler(faultInfo: arch.FaultInfo) void {
    resolveFault(faultInfo) catch |err| {
        @panic(@errorName(err));
    };
}

/// Resolves a not-present page fault by allocating and mapping a frame.
pub fn resolveFault(faultInfo: arch.FaultInfo) VMMError!void {
    const vma = findVirtualMemoryArea(faultInfo.address) orelse {
        return VMMError.FaultOutsideVirtualMemoryArea;
    };

    if (!isAccessAllowed(faultInfo, vma)) {
        return VMMError.ProtectionViolation;
    }

    if (faultInfo.present) {
        return VMMError.ProtectionViolation;
    }

    try mapAllocatedPage(faultInfo.address, vma.permissions);
}

fn mapAllocatedPage(virtualAddress: usize, memoryPermissions: MemoryPermissions) VMMError!void {
    const pageSize = arch.mmu.getPageSize();
    const pageAlignedAddress = virtualAddress & ~(pageSize - 1);
    const tableAlignedAddress = virtualAddress & ~(arch.mmu.getPageTableRegionSize() - 1);

    const pageProtection = arch.PageProtection{
        .write = memoryPermissions.writeable,
        .user = memoryPermissions.user_accessible,
        .execute = memoryPermissions.executable,
    };

    if (!arch.mmu.isTablePresent(tableAlignedAddress)) {
        const tablePhysicalAddress = try allocatePhysicalPage();

        arch.mmu.mapTable(tableAlignedAddress, tablePhysicalAddress, pageProtection) catch {
            return VMMError.MappingFailed;
        };
    }

    const dataPhysicalAddress = try allocatePhysicalPage();

    arch.mmu.mapPage(pageAlignedAddress, dataPhysicalAddress, pageProtection) catch {
        return VMMError.MappingFailed;
    };

    @memset(@as([*]u8, @ptrFromInt(pageAlignedAddress))[0..pageSize], 0);
}

fn mapAllocatedPageInAddressSpace(root: arch.AddressSpaceRoot, virtualAddress: usize, memoryPermissions: MemoryPermissions) VMMError!void {
    const pageSize = arch.mmu.getPageSize();
    const pageAlignedAddress = virtualAddress & ~(pageSize - 1);
    const tableAlignedAddress = virtualAddress & ~(arch.mmu.getPageTableRegionSize() - 1);

    const pageProtection = arch.PageProtection{
        .write = memoryPermissions.writeable,
        .user = memoryPermissions.user_accessible,
        .execute = memoryPermissions.executable,
    };

    if (!arch.mmu.isTablePresentInAddressSpace(root, tableAlignedAddress)) {
        const tablePhysicalAddress = try allocatePhysicalPage();

        arch.mmu.mapTableInAddressSpace(root, tableAlignedAddress, tablePhysicalAddress, pageProtection) catch {
            return VMMError.MappingFailed;
        };
    }

    const dataPhysicalAddress = try allocatePhysicalPage();

    arch.mmu.mapPageInAddressSpace(root, pageAlignedAddress, dataPhysicalAddress, pageProtection) catch {
        return VMMError.MappingFailed;
    };

    const directMapAddress = @as(usize, @intCast(arch.mmu.getDirectMapVirtualAddress())) + dataPhysicalAddress;
    @memset(@as([*]u8, @ptrFromInt(directMapAddress))[0..pageSize], 0);
}

fn mapBootstrapContiguousPagesInAddressSpace(
    root: arch.AddressSpaceRoot,
    startAddress: u64,
    endAddress: u64,
    memoryPermissions: MemoryPermissions,
) VMMError!void {
    const pageSize = arch.mmu.getPageSize();
    const allocationSize: usize = @intCast(endAddress - startAddress);
    const physicalBase = @intFromPtr(arch.early_allocator.allocate(
        allocationSize,
        pageSize,
        arch.ReservedMapRegionType.PERSISTENT,
    ) catch {
        return VMMError.PhysicalMemoryAllocationFailed;
    });

    const directMapBase = @as(usize, @intCast(arch.mmu.getDirectMapVirtualAddress())) + physicalBase;
    @memset(@as([*]u8, @ptrFromInt(directMapBase))[0..allocationSize], 0);

    const pageProtection = arch.PageProtection{
        .write = memoryPermissions.writeable,
        .user = memoryPermissions.user_accessible,
        .execute = memoryPermissions.executable,
    };

    var mappedBytes: usize = 0;
    while (mappedBytes < allocationSize) : (mappedBytes += pageSize) {
        const virtualAddress = @as(usize, @intCast(startAddress)) + mappedBytes;
        const tableAlignedAddress = virtualAddress & ~(arch.mmu.getPageTableRegionSize() - 1);

        if (!arch.mmu.isTablePresentInAddressSpace(root, tableAlignedAddress)) {
            const tablePhysicalAddress = try allocatePhysicalPage();
            arch.mmu.mapTableInAddressSpace(root, tableAlignedAddress, tablePhysicalAddress, pageProtection) catch {
                return VMMError.MappingFailed;
            };
        }

        arch.mmu.mapPageInAddressSpace(root, virtualAddress, physicalBase + mappedBytes, pageProtection) catch {
            return VMMError.MappingFailed;
        };
    }
}

fn allocatePhysicalPage() VMMError!usize {
    const pageSize = arch.mmu.getPageSize();

    if (arch.earlyAllocatorActive) {
        const page = arch.early_allocator.allocate(pageSize, pageSize, arch.ReservedMapRegionType.PERSISTENT) catch {
            return VMMError.PhysicalMemoryAllocationFailed;
        };
        return @intFromPtr(page);
    }

    return pmm.allocate(1) catch {
        return VMMError.PhysicalMemoryAllocationFailed;
    };
}

fn findVirtualMemoryArea(address: usize) ?VirtualMemoryArea {
    for (currentAddressSpace.virtual_memory_areas[0..currentAddressSpace.length]) |vma| {
        if ((address >= vma.start_address) and (address < vma.end_address)) {
            return vma;
        }
    }
    return null;
}

fn findVirtualMemoryAreaByRange(addressSpace: *AddressSpace, startAddress: u64, endAddress: u64) ?*VirtualMemoryArea {
    const index = findVirtualMemoryAreaIndex(addressSpace, startAddress, endAddress) orelse return null;
    return &addressSpace.virtual_memory_areas[index];
}

fn findVirtualMemoryAreaIndex(addressSpace: *AddressSpace, startAddress: u64, endAddress: u64) ?usize {
    for (addressSpace.virtual_memory_areas[0..addressSpace.length], 0..) |vma, index| {
        if (vma.start_address == startAddress and vma.end_address == endAddress) return index;
    }
    return null;
}

fn removeVirtualMemoryArea(addressSpace: *AddressSpace, index: usize) void {
    var shift_index = index;
    while (shift_index + 1 < addressSpace.length) : (shift_index += 1) {
        addressSpace.virtual_memory_areas[shift_index] = addressSpace.virtual_memory_areas[shift_index + 1];
    }
    addressSpace.length -= 1;
}

fn isAccessAllowed(faultInfo: arch.FaultInfo, vma: VirtualMemoryArea) bool {
    if (faultInfo.write and !vma.permissions.writeable) {
        return false;
    }

    if (faultInfo.user and !vma.permissions.user_accessible) {
        return false;
    }

    // On current 32-bit non-PAE x86, execute permission is advisory because
    // NX is unavailable. The VMM still enforces its architecture-independent
    // policy here so unsupported hardware semantics remain explicit.
    if (faultInfo.instruction_fetch and !vma.permissions.executable) {
        return false;
    }

    return true;
}
