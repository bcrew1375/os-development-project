const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel_common");

fn testSetup() !void {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    try arch.early_allocator.initialize();
}

test "Virtual Memory Manager: Map Region Adds Virtual Memory Area" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [2]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, 0x10000000, 0x10400000, permissions);
    try std.testing.expectEqual(@as(usize, 1), addressSpace.length);
    try std.testing.expectEqual(@as(u64, 0x10000000), addressSpace.virtual_memory_areas[0].start_address);
    try std.testing.expectEqual(@as(u64, 0x10400000), addressSpace.virtual_memory_areas[0].end_address);
}

test "Virtual Memory Manager: Overlapping Region Returns Error" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [2]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, 0x10000000, 0x10400000, permissions);
    const overlapping = kernel.vmm.map(&addressSpace, 0x10200000, 0x10600000, permissions);
    try std.testing.expectError(error.OverlappingVirtualMemoryArea, overlapping);
}

test "Virtual Memory Manager: Undefined Address Space Returns Error" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [0]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    const result = kernel.vmm.map(&addressSpace, 0x10000000, 0x10400000, permissions);
    try std.testing.expectError(error.UndefinedAddressSpace, result);
}

test "Virtual Memory Manager: Full Address Space Returns Error" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, 0x10000000, 0x10400000, permissions);
    const result = kernel.vmm.map(&addressSpace, 0x20000000, 0x20400000, permissions);
    try std.testing.expectError(error.OutOfVirtualMemoryAreas, result);
}

test "Virtual Memory Manager: Invalid Range Returns Error" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    const reversed = kernel.vmm.map(&addressSpace, 0x10400000, 0x10000000, permissions);
    try std.testing.expectError(error.InvalidVirtualMemoryAreaRange, reversed);

    const empty = kernel.vmm.map(&addressSpace, 0x10000000, 0x10000000, permissions);
    try std.testing.expectError(error.InvalidVirtualMemoryAreaRange, empty);
}

test "Virtual Memory Manager: Unaligned Range Returns Error" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    const unaligned_start = kernel.vmm.map(&addressSpace, 0x10000001, 0x10400000, permissions);
    try std.testing.expectError(error.UnalignedVirtualMemoryArea, unaligned_start);

    const unaligned_end = kernel.vmm.map(&addressSpace, 0x10000000, 0x10400001, permissions);
    try std.testing.expectError(error.UnalignedVirtualMemoryArea, unaligned_end);
}

test "Virtual Memory Manager: Unmap Removes Virtual Memory Area" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [2]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, 0x10000000, 0x10400000, permissions);
    try kernel.vmm.map(&addressSpace, 0x20000000, 0x20400000, permissions);
    try std.testing.expectEqual(@as(usize, 2), addressSpace.length);

    kernel.vmm.unmap(&addressSpace, 0x10000000, 0x10400000);
    try std.testing.expectEqual(@as(usize, 1), addressSpace.length);
    try std.testing.expectEqual(@as(u64, 0x20000000), addressSpace.virtual_memory_areas[0].start_address);
}

test "Virtual Memory Manager: Unmap Non-Existent Region Does Nothing" {
    try testSetup();
    try kernel.pmm.initialize();

    var vmaBacking: [2]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, 0x10000000, 0x10400000, permissions);
    kernel.vmm.unmap(&addressSpace, 0xdead0000, 0xdead4000);
    try std.testing.expectEqual(@as(usize, 1), addressSpace.length);
}

test "VMM mapEager: uses early allocator before PMM initialization" {
    try testSetup();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x100000;
    const vmaEnd = vmaStart + pageSize * 2;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.mapEager(&addressSpace, vmaStart, vmaEnd, permissions);

    try std.testing.expectEqual(@as(usize, 1), addressSpace.length);
    try std.testing.expect(arch.mmu.isTablePresent(@as(usize, @intCast(vmaStart))));
    try std.testing.expect(arch.mmu.getPhysicalAddress(@as(usize, @intCast(vmaStart))) != null);
    try std.testing.expect(arch.mmu.getPhysicalAddress(@as(usize, @intCast(vmaStart + pageSize))) != null);

    const firstPage: [*]u8 = @ptrFromInt(@as(usize, @intCast(vmaStart)));
    const secondPage: [*]u8 = @ptrFromInt(@as(usize, @intCast(vmaStart + pageSize)));
    try std.testing.expectEqual(@as(u8, 0), firstPage[0]);
    try std.testing.expectEqual(@as(u8, 0), secondPage[0]);
}

test "VMM explicit-root eager mapping is isolated and preserves protection" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const other_root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2000_0000;

    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };
    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = true,
    };
    try kernel.vmm.mapEagerInAddressSpace(
        root,
        &address_space,
        start,
        start + 2 * page_size,
        permissions,
    );

    const first = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    try std.testing.expect(!first.protection.write);
    try std.testing.expect(first.protection.user);
    try std.testing.expect(first.protection.execute);
    try std.testing.expectEqual(
        @as(?usize, null),
        arch.mmu.getPhysicalAddressInAddressSpace(other_root, @intCast(start)),
    );
}

test "VMM bootstrap contiguous mapping uses sequential physical pages" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2400_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };

    try kernel.vmm.mapBootstrapContiguousInAddressSpace(
        root,
        &address_space,
        start,
        start + 2 * page_size,
        .{ .readable = true, .writeable = true, .executable = false, .user_accessible = false },
    );

    const first = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    const second = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start + page_size)).?;
    try std.testing.expectEqual(first.physical_page + @as(usize, @intCast(page_size)), second.physical_page);
}

test "VMM protect updates mapped pages and rejects missing ranges" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2800_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };
    const initial = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };
    try kernel.vmm.mapEagerInAddressSpace(root, &address_space, start, start + page_size, initial);

    const updated = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = true,
    };
    try kernel.vmm.protectInAddressSpace(root, &address_space, start, start + page_size, updated);
    const mapping = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    try std.testing.expect(!mapping.protection.write);
    try std.testing.expect(mapping.protection.user);
    try std.testing.expect(mapping.protection.execute);
    try std.testing.expectEqual(updated, address_space.virtual_memory_areas[0].permissions);
    try std.testing.expectError(
        error.UndefinedVirtualMemoryArea,
        kernel.vmm.protectInAddressSpace(root, &address_space, start + page_size, start + 2 * page_size, updated),
    );
}

test "VMM current-root protect delegates to the active address space root" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2a00_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };
    try kernel.vmm.mapEagerInAddressSpace(
        root,
        &address_space,
        start,
        start + page_size,
        .{ .readable = true, .writeable = true, .executable = false, .user_accessible = false },
    );
    arch.mmu.switchAddressSpaceRoot(root);

    try kernel.vmm.protect(
        &address_space,
        start,
        start + page_size,
        .{ .readable = true, .writeable = false, .executable = true, .user_accessible = false },
    );
    const mapping = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    try std.testing.expect(!mapping.protection.write);
    try std.testing.expect(mapping.protection.execute);
}

test "VMM table mapping failure preserves VMA without mapped pages" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2b00_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };
    arch.mmu.failTableMappingCallForTest(1);

    try std.testing.expectError(
        error.MappingFailed,
        kernel.vmm.mapEagerInAddressSpace(
            root,
            &address_space,
            start,
            start + page_size,
            .{ .readable = true, .writeable = true, .executable = false, .user_accessible = false },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), address_space.length);
    try std.testing.expect(!arch.mmu.isTablePresentInAddressSpace(root, @intCast(start)));
    try std.testing.expect(arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)) == null);
}

test "VMM eager mapping failure preserves VMA and completed pages without rollback" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2c00_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };
    arch.mmu.failPageMappingCallForTest(2);

    try std.testing.expectError(
        error.MappingFailed,
        kernel.vmm.mapEagerInAddressSpace(
            root,
            &address_space,
            start,
            start + 2 * page_size,
            .{ .readable = true, .writeable = true, .executable = false, .user_accessible = false },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), address_space.length);
    try std.testing.expect(arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)) != null);
    try std.testing.expect(arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start + page_size)) == null);
}

test "VMM protection failure leaves partial page updates and old VMA permissions" {
    try testSetup();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x3000_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var address_space = kernel.vmm.AddressSpace{ .virtual_memory_areas = &backing };
    const initial = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };
    try kernel.vmm.mapEagerInAddressSpace(root, &address_space, start, start + 2 * page_size, initial);

    const updated = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = true,
    };
    arch.mmu.failPageMappingCallForTest(2);
    try std.testing.expectError(
        error.MappingFailed,
        kernel.vmm.protectInAddressSpace(root, &address_space, start, start + 2 * page_size, updated),
    );

    const first = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    const second = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start + page_size)).?;
    try std.testing.expect(!first.protection.write);
    try std.testing.expect(second.protection.write);
    try std.testing.expectEqual(initial, address_space.virtual_memory_areas[0].permissions);
}

// --- VMM fault resolution tests ---
//
// The mock MMU owns one stable 64 MiB physical-memory fixture. The memory
// map exposes physical offsets, while getHostVirtualAddressForTest() provides
// writable host virtual addresses for VMAs that the tests intentionally
// dereference. PMM allocations are accessed through the mock direct map.

test "VMM resolveFault: maps page within VMA" {
    try testSetup();
    try kernel.pmm.initialize();

    // Obtain a writable address inside a mock heap region for the VMA.
    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x100000;
    const vmaEnd = vmaStart + pageSize * 4; // 4 pages

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, permissions);

    // Disable early allocator so faultHandler doesn't panic.
    arch.earlyAllocatorActive = false;

    const initialAvailable = kernel.pmm.getCurrentAvailableFrames();

    // Resolve a page fault at the start of the VMA.
    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = true,
        .user = false,
        .instruction_fetch = false,
    };
    try kernel.vmm.resolveFault(faultInfo);

    // Should have consumed 2 frames: one for the page table, one for the data page.
    const expectedConsumed: usize = 2;
    try std.testing.expectEqual(initialAvailable - expectedConsumed, kernel.pmm.getCurrentAvailableFrames());

    // The table should now be present.
    try std.testing.expect(arch.mmu.isTablePresent(@as(usize, @intCast(vmaStart))));

    const mappedPage = arch.mmu.getMappedPageForTest(@as(usize, @intCast(vmaStart))).?;
    try std.testing.expect(mappedPage.present);
    try std.testing.expectEqual(vmaStart, mappedPage.virtual_page);
    try std.testing.expect(arch.mmu.getPhysicalAddress(@as(usize, @intCast(vmaStart))) != null);
}

test "VMM resolveFault: zeroes mapped page" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x200000;
    const vmaEnd = vmaStart + pageSize * 4;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, permissions);
    arch.earlyAllocatorActive = false;

    // Write known values to the page that will be faulted on.
    const faultAddress: usize = @intCast(vmaStart);
    const pagePtr: [*]u8 = @ptrFromInt(faultAddress);
    pagePtr[0] = 0xFF;
    pagePtr[100] = 0xAB;
    pagePtr[4095] = 0xCD;

    // Resolve fault — resolveFault() should zero the page.
    const faultInfo = arch.FaultInfo{
        .address = faultAddress,
        .present = false,
        .write = true,
        .user = false,
        .instruction_fetch = false,
    };
    try kernel.vmm.resolveFault(faultInfo);

    // The page should be zeroed after fault resolution runs.
    try std.testing.expectEqual(@as(u8, 0), pagePtr[0]);
    try std.testing.expectEqual(@as(u8, 0), pagePtr[100]);
    try std.testing.expectEqual(@as(u8, 0), pagePtr[4095]);
}

test "VMM resolveFault: second fault in same table region skips table allocation" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x300000;
    const vmaEnd = vmaStart + pageSize * 512; // 2 MB — spans many pages in one table region

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    };

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, permissions);
    arch.earlyAllocatorActive = false;

    const initialAvailable = kernel.pmm.getCurrentAvailableFrames();

    // First fault: should consume 2 frames (table + data page).
    const faultInfo1 = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = true,
        .user = false,
        .instruction_fetch = false,
    };
    try kernel.vmm.resolveFault(faultInfo1);
    try std.testing.expectEqual(initialAvailable - 2, kernel.pmm.getCurrentAvailableFrames());

    // Second fault at a different page within the same 4 MB table region:
    // should consume only 1 frame (data page), reusing the existing table.
    const faultInfo2 = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart + pageSize)),
        .present = false,
        .write = true,
        .user = false,
        .instruction_fetch = false,
    };
    try kernel.vmm.resolveFault(faultInfo2);
    try std.testing.expectEqual(initialAvailable - 3, kernel.pmm.getCurrentAvailableFrames());
}

test "VMM resolveFault: permissions propagate to page protection" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x400000;
    const vmaEnd = vmaStart + pageSize * 4;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    // Use non-default permissions to verify they propagate.
    const permissions = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = true,
    };

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, permissions);
    arch.earlyAllocatorActive = false;

    const initialAvailable = kernel.pmm.getCurrentAvailableFrames();

    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = false,
        .user = true,
        .instruction_fetch = false,
    };
    try kernel.vmm.resolveFault(faultInfo);

    // The fault handler should have consumed 2 frames (table + page).
    try std.testing.expectEqual(initialAvailable - 2, kernel.pmm.getCurrentAvailableFrames());

    // The table should be present (proving the handler reached mapTable).
    try std.testing.expect(arch.mmu.isTablePresent(@as(usize, @intCast(vmaStart))));

    const tableProtection = arch.mmu.getTableProtection(@as(usize, @intCast(vmaStart))).?;
    try std.testing.expect(tableProtection.user);
    try std.testing.expect(!tableProtection.write);

    const mappedPage = arch.mmu.getMappedPageForTest(@as(usize, @intCast(vmaStart))).?;
    try std.testing.expect(mappedPage.present);
    try std.testing.expect(mappedPage.protection.user);
    try std.testing.expect(!mappedPage.protection.write);
    try std.testing.expect(mappedPage.protection.execute);
}

test "VMM resolveFault: bootstrap VMA fault uses early allocator" {
    try testSetup();

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x500000;
    const vmaEnd = vmaStart + pageSize;

    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = false,
        .user = false,
        .instruction_fetch = false,
    };

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, .{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = false,
    });

    try kernel.vmm.resolveFault(faultInfo);

    try std.testing.expect(arch.mmu.isTablePresent(@as(usize, @intCast(vmaStart))));

    const mappedPage = arch.mmu.getMappedPageForTest(@as(usize, @intCast(vmaStart))).?;
    try std.testing.expect(mappedPage.present);
    try std.testing.expect(mappedPage.protection.write);
    try std.testing.expect(!mappedPage.protection.user);
    try std.testing.expect(!mappedPage.protection.execute);
}

test "VMM resolveFault: fault outside VMA returns error" {
    try testSetup();
    try kernel.pmm.initialize();
    arch.earlyAllocatorActive = false;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    const faultInfo = arch.FaultInfo{
        .address = 0x10000000,
        .present = false,
        .write = false,
        .user = false,
        .instruction_fetch = false,
    };

    try std.testing.expectError(error.FaultOutsideVirtualMemoryArea, kernel.vmm.resolveFault(faultInfo));
}

test "VMM resolveFault: present page fault returns protection violation" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x500000;
    const vmaEnd = vmaStart + pageSize;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, .{
        .readable = true,
        .writeable = true,
        .executable = true,
        .user_accessible = false,
    });
    arch.earlyAllocatorActive = false;

    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = true,
        .write = false,
        .user = false,
        .instruction_fetch = false,
    };

    try std.testing.expectError(error.ProtectionViolation, kernel.vmm.resolveFault(faultInfo));
}

test "VMM resolveFault: write to read-only VMA returns protection violation" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x600000;
    const vmaEnd = vmaStart + pageSize;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, .{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = false,
    });
    arch.earlyAllocatorActive = false;

    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = true,
        .user = false,
        .instruction_fetch = false,
    };

    try std.testing.expectError(error.ProtectionViolation, kernel.vmm.resolveFault(faultInfo));
}

test "VMM resolveFault: user access to supervisor VMA returns protection violation" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x700000;
    const vmaEnd = vmaStart + pageSize;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, .{
        .readable = true,
        .writeable = true,
        .executable = true,
        .user_accessible = false,
    });
    arch.earlyAllocatorActive = false;

    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = false,
        .user = true,
        .instruction_fetch = false,
    };

    try std.testing.expectError(error.ProtectionViolation, kernel.vmm.resolveFault(faultInfo));
}

test "VMM resolveFault: instruction fetch from non-executable VMA returns protection violation" {
    try testSetup();
    try kernel.pmm.initialize();

    const memoryMap = arch.mmu.getMemoryMap();
    const regionBase = arch.mmu.getHostVirtualAddressForTest(
        @intCast(memoryMap.entries[0].address),
    );
    const pageSize: u64 = arch.mmu.getPageSize();
    const vmaStart = regionBase + 0x800000;
    const vmaEnd = vmaStart + pageSize;

    var vmaBacking: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var addressSpace = kernel.vmm.AddressSpace{
        .virtual_memory_areas = &vmaBacking,
        .length = 0,
    };
    kernel.vmm.setAddressSpace(&addressSpace);

    try kernel.vmm.map(&addressSpace, vmaStart, vmaEnd, .{
        .readable = true,
        .writeable = false,
        .executable = false,
        .user_accessible = false,
    });
    arch.earlyAllocatorActive = false;

    const faultInfo = arch.FaultInfo{
        .address = @as(usize, @intCast(vmaStart)),
        .present = false,
        .write = false,
        .user = false,
        .instruction_fetch = true,
    };

    try std.testing.expectError(error.ProtectionViolation, kernel.vmm.resolveFault(faultInfo));
}
