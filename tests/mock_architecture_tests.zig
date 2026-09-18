const arch = @import("arch");
const std = @import("std");

test "Mock memory fixture reads are side-effect free" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const first = arch.mmu.getMemoryMap();
    const second = arch.mmu.getMemoryMap();

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), first.length);
    try std.testing.expectEqual(@as(u64, 0), first.entries[0].address);
    try std.testing.expectEqual(arch.MemoryMapRegionType.AVAILABLE, first.entries[0].region_type);
}

test "Mock memory fixture supports configurable regions" {
    try arch.impl.test_support.initializeMemoryFixture(16 * 4096, &.{
        .{ .offset = 0, .size = 4096, .region_type = .RESERVED },
        .{ .offset = 4096, .size = 15 * 4096, .region_type = .AVAILABLE },
    });
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const memory_map = arch.mmu.getMemoryMap();
    try std.testing.expectEqual(@as(usize, 2), memory_map.length);
    try std.testing.expectEqual(@as(usize, 1), memory_map.available_regions);
    try std.testing.expectEqual(@as(u64, 4096), memory_map.entries[1].address);
}

test "Mock reset clears reservations mappings and allocator transition state" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    try arch.early_allocator.initialize();

    _ = try arch.early_allocator.allocate(4096, 4096, .PERSISTENT);
    try arch.mmu.mapTable(0x400000, 0, .{});
    try arch.mmu.mapPage(0x400000, 0, .{});
    arch.earlyAllocatorActive = false;

    arch.impl.test_support.resetState();

    try std.testing.expectEqual(@as(usize, 0), arch.early_allocator.getReservedMap().length);
    try std.testing.expect(!arch.mmu.isTablePresent(0x400000));
    try std.testing.expectEqual(@as(?usize, null), arch.mmu.getPhysicalAddress(0x400000));
    try std.testing.expect(arch.earlyAllocatorActive);
}

test "Mock boot services expose configured modules and finalization" {
    arch.impl.test_support.resetState();
    arch.boot.configureModulesForTest(&.{
        .{ .physical_start = 0x1000, .physical_end = 0x2000 },
        .{ .physical_start = 0x4000, .physical_end = 0x6000 },
    });

    try std.testing.expectEqual(@as(usize, 2), arch.boot.getBootModuleCount());
    try std.testing.expectEqual(
        @as(usize, 0x4000),
        arch.boot.getBootModule(1).?.physical_start,
    );
    try std.testing.expectEqual(@as(?arch.BootModule, null), arch.boot.getBootModule(2));

    arch.boot.finishBoot();
    try std.testing.expect(arch.boot.isBootFinishedForTest());
}

test "Mock interrupt services record externally visible operations" {
    arch.impl.test_support.resetState();

    arch.interrupts.initialize();
    arch.interrupts.set(32, 0x1234, 0x8E);
    arch.interrupts.enableInterrupts();
    arch.interrupts.acknowledgeInterrupt(32);
    arch.interrupts.disableInterrupts();

    const state = arch.interrupts.getStateForTest();
    try std.testing.expectEqual(@as(usize, 1), state.initialization_count);
    try std.testing.expectEqual(@as(usize, 1), state.enable_count);
    try std.testing.expectEqual(@as(usize, 1), state.disable_count);
    try std.testing.expect(!state.enabled);
    try std.testing.expectEqual(@as(usize, 32), arch.interrupts.getInstalledVectorsForTest()[0].interrupt_vector);
    try std.testing.expectEqualSlices(usize, &.{32}, arch.interrupts.getAcknowledgementsForTest());
}

test "Mock platform records timer initialization" {
    arch.impl.test_support.resetState();

    arch.platform.initializeTimer(1000);

    const state = arch.platform.getStateForTest();
    try std.testing.expectEqual(@as(usize, 1), state.timer_initialization_count);
    try std.testing.expectEqual(@as(?usize, 1000), state.timer_frequency);
}

test "Mock CPU operation observation starts reset" {
    arch.impl.test_support.resetState();

    try std.testing.expectEqual(@as(?arch.cpu.Operation, null), arch.cpu.getLastOperationForTest());
}
