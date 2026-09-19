const arch = @import("arch");
const fixture = @import("../boot_module_fixture.zig");
const framework = @import("../framework.zig");

pub fn areCachedReservedAndCapacityLimited() !void {
    try framework.expectEqual(fixture.retained_module_count, @as(usize, arch.MAX_BOOT_MODULES));
    try framework.expectEqual(@as(usize, arch.MAX_BOOT_MODULES), arch.boot.getBootModuleCount());
    try framework.expect(arch.boot.getBootModule(arch.MAX_BOOT_MODULES) == null);

    for (0..arch.MAX_BOOT_MODULES) |index| {
        const first_read = arch.boot.getBootModule(index) orelse
            return framework.TestError.ExpectationFailed;
        const second_read = arch.boot.getBootModule(index) orelse
            return framework.TestError.ExpectationFailed;

        try framework.expectEqual(first_read.physical_start, second_read.physical_start);
        try framework.expectEqual(first_read.physical_end, second_read.physical_end);
        try framework.expect(first_read.physical_start < first_read.physical_end);
        try framework.expectEqual(
            fixture.payloadSize(index),
            first_read.physical_end - first_read.physical_start,
        );
        try expectPayload(index, first_read);
        try expectExactReservation(first_read);
        try expectNoOverlap(index, first_read);
    }

    try framework.expectEqual(@as(usize, arch.MAX_BOOT_MODULES), arch.boot.getBootModuleCount());
}

fn expectNoOverlap(index: usize, module: arch.BootModule) !void {
    for (0..index) |earlier_index| {
        const earlier = arch.boot.getBootModule(earlier_index) orelse
            return framework.TestError.ExpectationFailed;
        try framework.expect(
            module.physical_end <= earlier.physical_start or
                module.physical_start >= earlier.physical_end,
        );
    }
}

fn expectPayload(index: usize, module: arch.BootModule) !void {
    try framework.expect(module.physical_end <= arch.mmu.getDirectMapMaxSize());
    const virtual_start = @as(usize, @intCast(arch.mmu.getDirectMapVirtualAddress())) +
        module.physical_start;
    const payload: [*]const u8 = @ptrFromInt(virtual_start);
    for (payload[0..fixture.payloadSize(index)]) |byte| {
        try framework.expectEqual(fixture.payloadByte(index), byte);
    }
}

fn expectExactReservation(module: arch.BootModule) !void {
    const expected_size = module.physical_end - module.physical_start;
    const reserved_map = arch.early_allocator.getReservedMap();
    for (reserved_map.entries[0..reserved_map.length]) |reservation| {
        if (reservation.region_type == .BOOTLOADER_DATA and
            reservation.address == module.physical_start and
            reservation.size == expected_size)
        {
            return;
        }
    }

    return framework.TestError.ExpectationFailed;
}
