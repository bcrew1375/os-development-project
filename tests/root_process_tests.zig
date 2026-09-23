const abi = @import("abi");
const arch = @import("arch");
const elf_fixture = @import("elf_fixture");
const kernel_common = @import("kernel_common");
const launch_root_process = @import("launch_root_process");
const std = @import("std");

const vmm = kernel_common.memory_management.virtual_memory;
const module_physical_start = 48 * 1024 * 1024;

fn initializeLoaderTest() !void {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    try arch.early_allocator.initialize();
    kernel_common.capability.resetForTest();
    kernel_common.process.resetForTest();
    kernel_common.process.execution_context.resetForTest();
}

fn makeTestElf() [0x240]u8 {
    var image: [0x240]u8 = undefined;
    elf_fixture.initializeElf32(&image, 0x0040_0ffe, &.{
        .{
            .file_offset = 0x200,
            .virtual_address = 0x0040_0ffe,
            .file_size = 4,
            .memory_size = 8,
            .flags = 5,
        },
        .{
            .file_offset = 0x220,
            .virtual_address = 0x0080_0000,
            .file_size = 8,
            .memory_size = 0x1000,
            .flags = 6,
        },
    });
    @memcpy(image[0x200..0x204], "text");
    @memcpy(image[0x220..0x228], "data1234");
    return image;
}

fn prepare(image: []const u8) !launch_root_process.PreparedRootProcess {
    _ = try arch.boot.configureModuleBytesForTest(module_physical_start, image);
    return launch_root_process.prepareRootProcess();
}

test "Root process preparation rejects missing and invalid boot modules" {
    try initializeLoaderTest();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    try std.testing.expectError(
        error.RootProcessModuleMissing,
        launch_root_process.prepareRootProcess(),
    );

    const direct_map_size: usize = @intCast(arch.mmu.getDirectMapMaxSize());
    const invalid_modules = [_]arch.BootModule{
        .{ .physical_start = 1, .physical_end = 1 },
        .{ .physical_start = 2, .physical_end = 1 },
        .{ .physical_start = direct_map_size, .physical_end = direct_map_size + 1 },
        .{ .physical_start = direct_map_size - 1, .physical_end = direct_map_size + 1 },
    };
    for (invalid_modules) |module| {
        arch.impl.test_support.resetState();
        try arch.early_allocator.initialize();
        arch.boot.configureModulesForTest(&.{module});
        kernel_common.capability.resetForTest();
        kernel_common.process.resetForTest();
        try std.testing.expectError(
            error.InvalidBootModuleRange,
            launch_root_process.prepareRootProcess(),
        );
    }
}

test "Root process preparation propagates malformed ELF errors" {
    try initializeLoaderTest();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    try std.testing.expectError(error.InvalidElfImage, prepare("not an elf"));
}

test "Root process preparation loads segments boot info and cdecl stack" {
    try initializeLoaderTest();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const image = makeTestElf();
    const prepared = try prepare(&image);

    try std.testing.expectEqual(@as(usize, 0x0040_0ffe), prepared.entry_point);
    try std.testing.expectEqual(
        @as(usize, launch_root_process.RootProcessLayout.initial_stack_top - 8),
        prepared.initial_stack_pointer,
    );
    try std.testing.expectEqual(@as(usize, 0), arch.mmu.getCurrentAddressSpaceRootForTest().value);
    try std.testing.expectEqual(@as(?arch.cpu.Operation, null), arch.cpu.getLastOperationForTest());

    var text_and_bss: [8]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(
        prepared.address_space_root,
        0x0040_0ffe,
        &text_and_bss,
    );
    try std.testing.expectEqualSlices(u8, "text\x00\x00\x00\x00", &text_and_bss);

    var data_and_bss: [16]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(
        prepared.address_space_root,
        0x0080_0000,
        &data_and_bss,
    );
    try std.testing.expectEqualSlices(u8, "data1234\x00\x00\x00\x00\x00\x00\x00\x00", &data_and_bss);

    const text_mapping = arch.mmu.getMappedPageInAddressSpaceForTest(
        prepared.address_space_root,
        0x0040_0000,
    ).?;
    try std.testing.expect(!text_mapping.protection.write);
    try std.testing.expect(text_mapping.protection.user);
    try std.testing.expect(text_mapping.protection.execute);

    const data_mapping = arch.mmu.getMappedPageInAddressSpaceForTest(
        prepared.address_space_root,
        0x0080_0000,
    ).?;
    try std.testing.expect(data_mapping.protection.write);
    try std.testing.expect(data_mapping.protection.user);
    try std.testing.expect(!data_mapping.protection.execute);

    var boot_info_bytes: [@sizeOf(abi.boot_info.BootInfo)]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(
        prepared.address_space_root,
        @intCast(launch_root_process.RootProcessLayout.boot_info_start),
        &boot_info_bytes,
    );
    const boot_info = std.mem.bytesToValue(abi.boot_info.BootInfo, &boot_info_bytes);
    try std.testing.expectEqual(abi.boot_info.BOOT_INFO_MAGIC, boot_info.magic);
    try std.testing.expectEqual(abi.boot_info.BOOT_INFO_VERSION, boot_info.version);
    try std.testing.expectEqual(@as(u32, 1), boot_info.module_count);
    try std.testing.expectEqual(
        @as(u32, @intCast(launch_root_process.RootProcessLayout.boot_info_start + @sizeOf(abi.boot_info.BootInfo))),
        boot_info.modules_address,
    );

    var module_bytes: [2 * @sizeOf(abi.boot_info.BootModuleInfo)]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(
        prepared.address_space_root,
        boot_info.modules_address,
        &module_bytes,
    );
    const root_module = std.mem.bytesToValue(
        abi.boot_info.BootModuleInfo,
        module_bytes[0..@sizeOf(abi.boot_info.BootModuleInfo)],
    );
    try std.testing.expectEqual(@as(u64, module_physical_start), root_module.physical_start);
    try std.testing.expectEqual(@as(u64, module_physical_start + image.len), root_module.physical_end);
    const unused_module = std.mem.bytesToValue(
        abi.boot_info.BootModuleInfo,
        module_bytes[@sizeOf(abi.boot_info.BootModuleInfo)..],
    );
    try std.testing.expectEqual(@as(u64, 0), unused_module.physical_start);
    try std.testing.expectEqual(@as(u64, 0), unused_module.physical_end);

    var stack_frame_bytes: [8]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(
        prepared.address_space_root,
        prepared.initial_stack_pointer,
        &stack_frame_bytes,
    );
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, stack_frame_bytes[0..4], .little));
    try std.testing.expectEqual(
        @as(u32, @intCast(launch_root_process.RootProcessLayout.boot_info_start)),
        std.mem.readInt(u32, stack_frame_bytes[4..8], .little),
    );
}

test "Root process boot info truncates modules and zeroes unused entries" {
    try initializeLoaderTest();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const image = makeTestElf();
    try arch.mmu.writePhysicalMemoryForTest(module_physical_start, &image);
    var modules: [17]arch.BootModule = undefined;
    modules[0] = .{
        .physical_start = module_physical_start,
        .physical_end = module_physical_start + image.len,
    };
    for (modules[1..], 1..) |*module, index| {
        module.* = .{ .physical_start = index * 0x1000, .physical_end = index * 0x1000 + 1 };
    }
    arch.boot.configureModulesForTest(&modules);

    const prepared = try launch_root_process.prepareRootProcess();

    const blob_size = @sizeOf(abi.boot_info.BootInfo) +
        launch_root_process.MAX_BOOT_INFO_MODULES * @sizeOf(abi.boot_info.BootModuleInfo);
    var blob_bytes: [blob_size]u8 = undefined;
    try arch.mmu.readVirtualMemoryInAddressSpaceForTest(
        prepared.address_space_root,
        @intCast(launch_root_process.RootProcessLayout.boot_info_start),
        &blob_bytes,
    );
    const boot_info = std.mem.bytesToValue(
        abi.boot_info.BootInfo,
        blob_bytes[0..@sizeOf(abi.boot_info.BootInfo)],
    );
    try std.testing.expectEqual(@as(u32, launch_root_process.MAX_BOOT_INFO_MODULES), boot_info.module_count);
    const last_offset = @sizeOf(abi.boot_info.BootInfo) +
        (launch_root_process.MAX_BOOT_INFO_MODULES - 1) * @sizeOf(abi.boot_info.BootModuleInfo);
    const last_module = std.mem.bytesToValue(
        abi.boot_info.BootModuleInfo,
        blob_bytes[last_offset..][0..@sizeOf(abi.boot_info.BootModuleInfo)],
    );
    try std.testing.expectEqual(@as(u64, 15 * 0x1000), last_module.physical_start);
}

test "Root process preparation reports missing explicit-root mapping" {
    try initializeLoaderTest();
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const image = makeTestElf();
    _ = try arch.boot.configureModuleBytesForTest(module_physical_start, &image);
    arch.mmu.failPhysicalLookupCallForTest(1);
    try std.testing.expectError(
        error.RootAddressSpaceMappingMissing,
        launch_root_process.prepareRootProcess(),
    );
}
