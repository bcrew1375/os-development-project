const arch = @import("arch");
const framework = @import("../framework.zig");

const test_virtual_address = 0x400000;
const first_physical_address = 0x200000;
const second_physical_address = 0x300000;

pub fn addressSpaceRootCanBeCreated() !void {
    const kernel_virtual_address = @intFromPtr(&addressSpaceRootCanBeCreated);
    const expected_physical_address = arch.mmu.getPhysicalAddress(kernel_virtual_address) orelse
        return framework.TestError.ExpectationFailed;

    const root = try arch.mmu.createAddressSpaceRoot();
    try framework.expect(root.value != 0);
    try framework.expect(root.value % arch.mmu.getPageSize() == 0);
    try framework.expectEqual(
        @as(?usize, expected_physical_address),
        arch.mmu.getPhysicalAddressInAddressSpace(root, kernel_virtual_address),
    );

    arch.mmu.switchAddressSpaceRoot(root);
    const nested_root = try arch.mmu.createAddressSpaceRoot();
    try framework.expect(nested_root.value != 0);
    try framework.expect(nested_root.value != root.value);
    try framework.expectEqual(
        @as(?usize, expected_physical_address),
        arch.mmu.getPhysicalAddressInAddressSpace(nested_root, kernel_virtual_address),
    );
}

pub fn explicitRootMappingTranslates() !void {
    const root = try arch.mmu.createAddressSpaceRoot();
    try mapTestPage(root, test_virtual_address, first_physical_address, .{});

    try framework.expectEqual(
        @as(?usize, first_physical_address + 0x321),
        arch.mmu.getPhysicalAddressInAddressSpace(root, test_virtual_address + 0x321),
    );
}

pub fn addressSpacesAreIsolatedAndSwitchable() !void {
    const first_root = try arch.mmu.createAddressSpaceRoot();
    const second_root = try arch.mmu.createAddressSpaceRoot();
    try mapTestPage(first_root, test_virtual_address, first_physical_address, .{});
    try mapTestPage(second_root, test_virtual_address, second_physical_address, .{});

    try framework.expectEqual(
        @as(?usize, first_physical_address),
        arch.mmu.getPhysicalAddressInAddressSpace(first_root, test_virtual_address),
    );
    try framework.expectEqual(
        @as(?usize, second_physical_address),
        arch.mmu.getPhysicalAddressInAddressSpace(second_root, test_virtual_address),
    );

    arch.mmu.switchAddressSpaceRoot(first_root);
    try framework.expectEqual(
        @as(?usize, first_physical_address),
        arch.mmu.getPhysicalAddress(test_virtual_address),
    );
    arch.mmu.switchAddressSpaceRoot(second_root);
    try framework.expectEqual(
        @as(?usize, second_physical_address),
        arch.mmu.getPhysicalAddress(test_virtual_address),
    );
    arch.mmu.switchAddressSpaceRoot(first_root);
    try framework.expectEqual(
        @as(?usize, second_physical_address),
        arch.mmu.unmapPageInAddressSpace(second_root, test_virtual_address),
    );
    arch.mmu.destroyAddressSpaceRoot(second_root);
    try framework.expectEqual(
        @as(?usize, first_physical_address),
        arch.mmu.getPhysicalAddress(test_virtual_address),
    );
}

pub fn unmappingIsIdempotent() !void {
    const root = try arch.mmu.createAddressSpaceRoot();
    try mapTestPage(root, test_virtual_address, first_physical_address, .{});

    try framework.expectEqual(
        @as(?usize, first_physical_address),
        arch.mmu.unmapPageInAddressSpace(root, test_virtual_address),
    );
    try framework.expectEqual(
        @as(?usize, null),
        arch.mmu.unmapPageInAddressSpace(root, test_virtual_address),
    );
    try framework.expectEqual(
        @as(?usize, null),
        arch.mmu.unmapPageInAddressSpace(
            root,
            test_virtual_address + arch.mmu.getPageTableRegionSize(),
        ),
    );

    try framework.expectEqual(
        @as(?usize, null),
        arch.mmu.getPhysicalAddressInAddressSpace(root, test_virtual_address),
    );
}

pub fn effectivePermissionsAreReported() !void {
    const root = try arch.mmu.createAddressSpaceRoot();
    const requested = arch.PageProtection{
        .write = true,
        .user = true,
        .execute = false,
        .global = true,
    };
    try mapTestPage(root, test_virtual_address, first_physical_address, requested);

    const actual = arch.mmu.getPageProtectionInAddressSpace(root, test_virtual_address) orelse
        return framework.TestError.ExpectationFailed;
    try framework.expect(actual.write);
    try framework.expect(actual.user);
    try framework.expect(actual.global);

    if (@import("builtin").cpu.arch == .x86) {
        try framework.expect(actual.execute);
    } else {
        try framework.expect(!actual.execute);
    }
}

pub fn allocatorExhaustionIsBounded() !void {
    while (arch.early_allocator.getReservedMap().length < arch.MAX_EARLY_RESERVATIONS) {
        _ = try arch.mmu.createAddressSpaceRoot();
    }

    const result = arch.mmu.createAddressSpaceRoot();
    if (result) |_| {
        return framework.TestError.ExpectationFailed;
    } else |err| {
        try framework.expectEqual(arch.MmuError.AddressSpaceRootAllocationFailed, err);
    }
}

fn mapTestPage(
    root: arch.AddressSpaceRoot,
    virtual_address: usize,
    physical_address: usize,
    protection: arch.PageProtection,
) !void {
    const page_size = arch.mmu.getPageSize();
    const page_table_physical_address = @intFromPtr(try arch.early_allocator.allocate(
        page_size,
        page_size,
        .PERSISTENT,
    ));
    try arch.mmu.mapTableInAddressSpace(
        root,
        virtual_address,
        page_table_physical_address,
        protection,
    );
    try arch.mmu.mapPageInAddressSpace(root, virtual_address, physical_address, protection);
}
