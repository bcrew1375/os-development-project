const arch = @import("arch");
const std = @import("std");
const boot_module_fixture = @import("architecture/boot_module_fixture.zig");

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
    arch.boot.configureModulesForTest(&.{.{ .physical_start = 0x1000, .physical_end = 0x2000 }});
    arch.boot.finishBoot();
    arch.earlyAllocatorActive = false;

    arch.impl.test_support.resetState();

    try std.testing.expectEqual(@as(usize, 0), arch.early_allocator.getReservedMap().length);
    try std.testing.expect(!arch.mmu.isTablePresent(0x400000));
    try std.testing.expectEqual(@as(?usize, null), arch.mmu.getPhysicalAddress(0x400000));
    try std.testing.expectEqual(@as(usize, 0), arch.boot.getBootModuleCount());
    try std.testing.expect(!arch.boot.isBootFinishedForTest());
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

test "Physical boot-module fixture matches the architecture capacity policy" {
    try std.testing.expectEqual(
        arch.MAX_BOOT_MODULES,
        boot_module_fixture.retained_module_count,
    );
    try std.testing.expectEqual(
        arch.MAX_BOOT_MODULES + 1,
        boot_module_fixture.supplied_module_count,
    );

    var modules: [arch.MAX_BOOT_MODULES]arch.BootModule = undefined;
    for (&modules, 0..) |*module, index| {
        module.* = .{
            .physical_start = index * 0x1000,
            .physical_end = index * 0x1000 + boot_module_fixture.payloadSize(index),
        };
    }
    arch.boot.configureModulesForTest(&modules);

    try std.testing.expectEqual(arch.MAX_BOOT_MODULES, arch.boot.getBootModuleCount());
    try std.testing.expectEqual(
        @as(?arch.BootModule, null),
        arch.boot.getBootModule(arch.MAX_BOOT_MODULES),
    );
}

test "Mock boot services configure a module from physical bytes" {
    try arch.impl.test_support.initializeMemoryFixture(4 * 4096, &.{.{
        .offset = 0,
        .size = 4 * 4096,
        .region_type = .AVAILABLE,
    }});
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const bytes = "root-process";
    const module = try arch.boot.configureModuleBytesForTest(0x1200, bytes);
    var actual: [bytes.len]u8 = undefined;
    try arch.mmu.readPhysicalMemoryForTest(module.physical_start, &actual);

    try std.testing.expectEqualSlices(u8, bytes, &actual);
    try std.testing.expectEqual(@as(usize, 0x1200 + bytes.len), module.physical_end);
    try std.testing.expectError(
        error.InvalidBootModuleRange,
        arch.boot.configureModuleBytesForTest(4 * 4096 - 2, "toolong"),
    );
}

test "Mock MMU reads explicit address spaces across page boundaries" {
    try arch.impl.test_support.initializeMemoryFixture(8 * 4096, &.{.{
        .offset = 0,
        .size = 8 * 4096,
        .region_type = .AVAILABLE,
    }});
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const first_root = try arch.mmu.createAddressSpaceRoot();
    const second_root = try arch.mmu.createAddressSpaceRoot();
    try arch.mmu.mapTableInAddressSpace(first_root, 0x400000, 0, .{});
    try arch.mmu.mapTableInAddressSpace(second_root, 0x400000, 0, .{});
    try arch.mmu.mapPageInAddressSpace(first_root, 0x400000, 0x1000, .{});
    try arch.mmu.mapPageInAddressSpace(first_root, 0x401000, 0x3000, .{});
    try arch.mmu.mapPageInAddressSpace(second_root, 0x400000, 0x5000, .{});
    try arch.mmu.writePhysicalMemoryForTest(0x1ffe, "ab");
    try arch.mmu.writePhysicalMemoryForTest(0x3000, "cd");
    try arch.mmu.writePhysicalMemoryForTest(0x5ffe, "xy");

    var first: [4]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(first_root, 0x400ffe, &first);
    try std.testing.expectEqualSlices(u8, "abcd", &first);

    var second: [2]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(second_root, 0x400ffe, &second);
    try std.testing.expectEqualSlices(u8, "xy", &second);

    try std.testing.expectError(
        error.VirtualAddressNotMapped,
        arch.mmu.readVirtualMemoryInAddressSpaceForTest(second_root, 0x401000, &second),
    );
}

test "Mock MMU reports permissions and unmaps explicit address spaces idempotently" {
    arch.impl.test_support.resetState();

    const first_root = try arch.mmu.createAddressSpaceRoot();
    const second_root = try arch.mmu.createAddressSpaceRoot();
    const virtual_address = 0x400000;
    const protection = arch.PageProtection{
        .write = true,
        .user = true,
        .execute = false,
        .global = true,
    };

    try arch.mmu.mapTableInAddressSpace(first_root, virtual_address, 0, protection);
    try arch.mmu.mapTableInAddressSpace(second_root, virtual_address, 0, .{});
    try arch.mmu.mapPageInAddressSpace(first_root, virtual_address, 0x1000, protection);
    try arch.mmu.mapPageInAddressSpace(second_root, virtual_address, 0x2000, .{});

    try std.testing.expectEqual(
        protection,
        arch.mmu.getPageProtectionInAddressSpace(first_root, virtual_address).?,
    );
    try std.testing.expectEqual(
        arch.PageProtection{},
        arch.mmu.getPageProtectionInAddressSpace(second_root, virtual_address).?,
    );

    arch.mmu.unmapPageInAddressSpace(first_root, virtual_address);
    arch.mmu.unmapPageInAddressSpace(first_root, virtual_address);
    try std.testing.expectEqual(
        @as(?arch.PageProtection, null),
        arch.mmu.getPageProtectionInAddressSpace(first_root, virtual_address),
    );
    try std.testing.expectEqual(
        @as(?usize, 0x2000),
        arch.mmu.getPhysicalAddressInAddressSpace(second_root, virtual_address),
    );

    arch.mmu.switchAddressSpaceRoot(second_root);
    try std.testing.expectEqual(
        arch.PageProtection{},
        arch.mmu.getPageProtection(virtual_address).?,
    );
    arch.mmu.unmapPage(virtual_address);
    arch.mmu.unmapPage(virtual_address);
    try std.testing.expectEqual(@as(?usize, null), arch.mmu.getPhysicalAddress(virtual_address));
}

test "Mock reset clears physical lookup failure injection but preserves backing" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const root = try arch.mmu.createAddressSpaceRoot();
    try arch.mmu.mapTableInAddressSpace(root, 0x400000, 0, .{});
    try arch.mmu.mapPageInAddressSpace(root, 0x400000, 0x1000, .{});
    arch.mmu.failPhysicalLookupCallForTest(1);
    try std.testing.expectEqual(@as(?usize, null), arch.mmu.getPhysicalAddressInAddressSpace(root, 0x400000));

    arch.impl.test_support.resetState();
    try std.testing.expect(arch.mmu.isMemoryFixtureInitializedForTest());

    const reset_root = try arch.mmu.createAddressSpaceRoot();
    try arch.mmu.mapTableInAddressSpace(reset_root, 0x400000, 0, .{});
    try arch.mmu.mapPageInAddressSpace(reset_root, 0x400000, 0x1000, .{});
    try std.testing.expectEqual(@as(?usize, 0x1000), arch.mmu.getPhysicalAddressInAddressSpace(reset_root, 0x400000));
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

    arch.impl.platform.recordTimerInterruptForTest();
    try std.testing.expectEqual(@as(usize, 1), arch.platform.getTimerInterruptCount());

    arch.platform.initializeTimer(1000);

    const state = arch.platform.getStateForTest();
    try std.testing.expectEqual(@as(usize, 1), state.timer_initialization_count);
    try std.testing.expectEqual(@as(?usize, 1000), state.timer_frequency);
    try std.testing.expectEqual(@as(usize, 0), arch.platform.getTimerInterruptCount());

    arch.impl.platform.recordTimerInterruptForTest();
    arch.impl.platform.recordTimerInterruptForTest();
    try std.testing.expectEqual(@as(usize, 2), arch.platform.getTimerInterruptCount());
    arch.platform.resetTimerInterruptCount();
    try std.testing.expectEqual(@as(usize, 0), arch.platform.getTimerInterruptCount());

    arch.impl.platform.recordTimerInterruptForTest();
    arch.impl.test_support.resetState();
    try std.testing.expectEqual(@as(usize, 0), arch.platform.getTimerInterruptCount());
}

test "Mock CPU operation observation starts reset" {
    arch.impl.test_support.resetState();

    try std.testing.expectEqual(@as(?arch.cpu.Operation, null), arch.cpu.getLastOperationForTest());
}
