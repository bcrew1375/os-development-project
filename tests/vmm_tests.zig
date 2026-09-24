const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");
const std = @import("std");

const permissions = kernel.vmm.MemoryPermissions{
    .readable = true,
    .writeable = true,
    .executable = false,
    .user_accessible = true,
};

fn testSetup() !void {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    try arch.early_allocator.initialize();
}

fn addressSpace(backing: []kernel.vmm.VirtualMemoryArea) kernel.vmm.AddressSpace {
    return .{ .virtual_memory_areas = backing, .length = 0 };
}

test "VMM reserves an aligned virtual range without physical backing" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);

    try kernel.vmm.map(&space, 0x1000_0000, 0x1000_2000, permissions);
    try std.testing.expectEqual(@as(usize, 1), space.length);
    try std.testing.expectEqual(abi.syscall.INVALID_HANDLE, backing[0].memory_object_handle);
    try std.testing.expectEqual(@as(?usize, null), arch.mmu.getPhysicalAddress(0x1000_0000));
}

test "VMM rejects undefined full invalid unaligned and overlapping ranges" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    var empty: [0]kernel.vmm.VirtualMemoryArea = undefined;
    var undefined_space = addressSpace(&empty);
    try std.testing.expectError(
        error.UndefinedAddressSpace,
        kernel.vmm.map(&undefined_space, 0x1000, 0x2000, permissions),
    );

    var backing: [2]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    try std.testing.expectError(
        error.InvalidVirtualMemoryAreaRange,
        kernel.vmm.map(&space, 0x2000, 0x1000, permissions),
    );
    try std.testing.expectError(
        error.UnalignedVirtualMemoryArea,
        kernel.vmm.map(&space, 0x1001, 0x2000, permissions),
    );
    try kernel.vmm.map(&space, 0x4000, 0x5000, permissions);
    try std.testing.expectError(
        error.OverlappingVirtualMemoryArea,
        kernel.vmm.map(&space, 0x4000, 0x6000, permissions),
    );
    try kernel.vmm.map(&space, 0x9000, 0xA000, permissions);
    try std.testing.expectError(
        error.OutOfVirtualMemoryAreas,
        kernel.vmm.map(&space, 0xB000, 0xC000, permissions),
    );
}

test "VMM bootstrap contiguous mapping uses sequential physical pages" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_size: u64 = arch.mmu.getPageSize();
    const start: u64 = 0x2400_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);

    try kernel.vmm.mapBootstrapContiguousInAddressSpace(
        root,
        &space,
        start,
        start + 2 * page_size,
        permissions,
    );
    const first = arch.mmu.getPhysicalAddressInAddressSpace(root, @intCast(start)).?;
    const second = arch.mmu.getPhysicalAddressInAddressSpace(root, @intCast(start + page_size)).?;
    try std.testing.expectEqual(first + arch.mmu.getPageSize(), second);
    try std.testing.expectEqual(@as(usize, 1), space.length);
}

test "VMM object mapping is isolated and preserves permissions" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    const other_root = try arch.mmu.createAddressSpaceRoot();
    const start: u64 = 0x2800_0000;
    const page_size: u64 = arch.mmu.getPageSize();
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    const requested = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = true,
    };

    try kernel.vmm.mapBackedObjectInAddressSpace(
        root,
        &space,
        start,
        start + page_size,
        requested,
        7,
        0,
        0x4000,
    );
    const mapping = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    try std.testing.expect(!mapping.protection.write);
    try std.testing.expect(mapping.protection.user);
    try std.testing.expect(mapping.protection.execute);
    try std.testing.expectEqual(
        @as(?usize, null),
        arch.mmu.getPhysicalAddressInAddressSpace(other_root, @intCast(start)),
    );
}

test "VMM object mapping rolls back pages and VMA on partial failure" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    const start: u64 = 0x2D00_0000;
    const page_size: u64 = arch.mmu.getPageSize();
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    arch.mmu.failPageMappingCallForTest(2);

    try std.testing.expectError(
        error.MappingFailed,
        kernel.vmm.mapBackedObjectInAddressSpace(
            root,
            &space,
            start,
            start + 2 * page_size,
            permissions,
            8,
            0,
            0x8000,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), space.length);
    try std.testing.expectEqual(
        @as(?usize, null),
        arch.mmu.getPhysicalAddressInAddressSpace(root, @intCast(start)),
    );
}

test "VMM object-backed fault restores immutable physical backing" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    arch.mmu.switchAddressSpaceRoot(root);
    const start: u64 = 0x2E00_0000;
    const physical_start: u64 = 0xC000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    kernel.vmm.setAddressSpace(&space);

    try kernel.vmm.mapBackedObjectInAddressSpace(
        root,
        &space,
        start,
        start + arch.mmu.getPageSize(),
        permissions,
        9,
        0,
        physical_start,
    );
    _ = arch.mmu.unmapPageInAddressSpace(root, @intCast(start));
    try kernel.vmm.resolveFault(.{
        .address = @intCast(start),
        .present = false,
        .write = true,
        .user = true,
        .instruction_fetch = false,
    });
    try std.testing.expectEqual(
        @as(?usize, @intCast(physical_start)),
        arch.mmu.getPhysicalAddressInAddressSpace(root, @intCast(start)),
    );
}

test "VMM unbacked fault returns MissingPhysicalBacking without mapping" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const start: u64 = 0x3000_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    kernel.vmm.setAddressSpace(&space);
    try kernel.vmm.map(&space, start, start + arch.mmu.getPageSize(), permissions);

    try std.testing.expectError(
        error.MissingPhysicalBacking,
        kernel.vmm.resolveFault(.{
            .address = @intCast(start),
            .present = false,
            .write = true,
            .user = true,
            .instruction_fetch = false,
        }),
    );
    try std.testing.expectEqual(@as(?usize, null), arch.mmu.getPhysicalAddress(@intCast(start)));
}

test "VMM protect updates mapped pages and metadata" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    const start: u64 = 0x3200_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    try kernel.vmm.mapBackedObjectInAddressSpace(
        root,
        &space,
        start,
        start + arch.mmu.getPageSize(),
        permissions,
        10,
        0,
        0x10000,
    );
    const updated = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = false,
    };
    try kernel.vmm.protectInAddressSpace(
        root,
        &space,
        start,
        start + arch.mmu.getPageSize(),
        updated,
    );
    try std.testing.expectEqual(updated, backing[0].permissions);
    const mapping = arch.mmu.getMappedPageInAddressSpaceForTest(root, @intCast(start)).?;
    try std.testing.expect(!mapping.protection.write);
    try std.testing.expect(mapping.protection.execute);
}

test "VMM protection failure preserves VMA metadata after partial updates" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    const start: u64 = 0x3400_0000;
    const page_size: u64 = arch.mmu.getPageSize();
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    try kernel.vmm.mapBackedObjectInAddressSpace(
        root,
        &space,
        start,
        start + 2 * page_size,
        permissions,
        11,
        0,
        0x14000,
    );
    const updated = kernel.vmm.MemoryPermissions{
        .readable = true,
        .writeable = false,
        .executable = true,
        .user_accessible = false,
    };
    arch.mmu.failPageMappingCallForTest(2);
    try std.testing.expectError(
        error.MappingFailed,
        kernel.vmm.protectInAddressSpace(root, &space, start, start + 2 * page_size, updated),
    );
    try std.testing.expectEqual(permissions, backing[0].permissions);
}

test "VMM unmap targets explicit roots and removes metadata" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const root = try arch.mmu.createAddressSpaceRoot();
    const start: u64 = 0x3600_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    try kernel.vmm.mapBackedObjectInAddressSpace(
        root,
        &space,
        start,
        start + arch.mmu.getPageSize(),
        permissions,
        12,
        0,
        0x18000,
    );
    try kernel.vmm.unmapInAddressSpace(
        root,
        &space,
        start,
        start + arch.mmu.getPageSize(),
    );
    try std.testing.expectEqual(@as(usize, 0), space.length);
    try std.testing.expectEqual(
        @as(?usize, null),
        arch.mmu.getPhysicalAddressInAddressSpace(root, @intCast(start)),
    );
    try std.testing.expectError(
        error.UndefinedVirtualMemoryArea,
        kernel.vmm.unmapInAddressSpace(
            root,
            &space,
            start,
            start + arch.mmu.getPageSize(),
        ),
    );
}

test "VMM fault policy rejects outside present and disallowed accesses" {
    try testSetup();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const start: u64 = 0x3800_0000;
    var backing: [1]kernel.vmm.VirtualMemoryArea = undefined;
    var space = addressSpace(&backing);
    kernel.vmm.setAddressSpace(&space);
    try kernel.vmm.map(&space, start, start + arch.mmu.getPageSize(), .{
        .readable = true,
        .writeable = false,
        .executable = false,
        .user_accessible = false,
    });

    try std.testing.expectError(
        error.FaultOutsideVirtualMemoryArea,
        kernel.vmm.resolveFault(.{
            .address = @intCast(start + 2 * arch.mmu.getPageSize()),
            .present = false,
            .write = false,
            .user = false,
            .instruction_fetch = false,
        }),
    );
    try std.testing.expectError(
        error.ProtectionViolation,
        kernel.vmm.resolveFault(.{
            .address = @intCast(start),
            .present = true,
            .write = false,
            .user = false,
            .instruction_fetch = false,
        }),
    );
    try std.testing.expectError(
        error.ProtectionViolation,
        kernel.vmm.resolveFault(.{
            .address = @intCast(start),
            .present = false,
            .write = true,
            .user = false,
            .instruction_fetch = false,
        }),
    );
    try std.testing.expectError(
        error.ProtectionViolation,
        kernel.vmm.resolveFault(.{
            .address = @intCast(start),
            .present = false,
            .write = false,
            .user = true,
            .instruction_fetch = false,
        }),
    );
    try std.testing.expectError(
        error.ProtectionViolation,
        kernel.vmm.resolveFault(.{
            .address = @intCast(start),
            .present = false,
            .write = false,
            .user = false,
            .instruction_fetch = true,
        }),
    );
}
