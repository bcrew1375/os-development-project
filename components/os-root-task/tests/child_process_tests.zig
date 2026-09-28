const abi = @import("abi");
const memory_management = @import("memory_management");
const process_management = @import("process_management");
const std = @import("std");

const boot_fixtures = @import("support/boot_fixtures.zig");
const child_process_fixtures = @import("support/child_process_fixtures.zig");
const elf_builder = @import("support/elf_builder.zig");

const ChildElfSegment = elf_builder.ChildElfSegment;
const ChildRollbackEnvironment = child_process_fixtures.ChildRollbackEnvironment;
const MemoryObjectFailureEnvironment = child_process_fixtures.MemoryObjectFailureEnvironment;
const PhysicalRangeAllocator = memory_management.PhysicalRangeAllocator;
const child_process = process_management.child_process;
const initializeChildElf32 = elf_builder.initializeChildElf32;
const initializeChildElf64 = elf_builder.initializeChildElf64;
const physicalDescriptor = boot_fixtures.physicalDescriptor;

test "child ELF planner accepts page-disjoint native executable segments" {
    var image = [_]u8{0} ** 0x300;
    const segments = [_]ChildElfSegment{
        .{ .file_offset = 0x200, .virtual_address = 0x0040_0000, .file_size = 4, .memory_size = 0x1000, .flags = 5 },
        .{ .file_offset = 0x210, .virtual_address = 0x0040_2000, .file_size = 4, .memory_size = 0x1000, .flags = 6 },
    };
    initializeChildElf64(&image, 0x0040_0010, &segments);
    const load_plan = try child_process.plan(&image);
    try std.testing.expectEqual(@as(usize, 2), load_plan.segment_count);
    try std.testing.expectEqual(@as(usize, 0x0040_0010), load_plan.entry_point);
    try std.testing.expectEqual(@as(usize, 0x1000), load_plan.segments[0].mapping_size);
}

test "child ELF planner rejects non-native class" {
    var image = [_]u8{0} ** 0x200;
    initializeChildElf32(&image);
    try std.testing.expectError(error.WrongElfClass, child_process.plan(&image));
}

test "child ELF planner rejects aligned segment overlap" {
    var image = [_]u8{0} ** 0x300;
    const segments = [_]ChildElfSegment{
        .{ .file_offset = 0x200, .virtual_address = 0x0040_0000, .file_size = 4, .memory_size = 0x900, .flags = 5 },
        .{ .file_offset = 0x210, .virtual_address = 0x0040_0800, .file_size = 4, .memory_size = 0x800, .flags = 6 },
    };
    initializeChildElf64(&image, 0x0040_0010, &segments);
    try std.testing.expectError(error.PageAlignedSegmentOverlap, child_process.plan(&image));
}

test "child ELF planner rejects stack collision and non-executable entry" {
    var image = [_]u8{0} ** 0x300;
    var segments = [_]ChildElfSegment{.{
        .file_offset = 0x200,
        .virtual_address = child_process.STACK_START,
        .file_size = 4,
        .memory_size = 0x1000,
        .flags = 5,
    }};
    initializeChildElf64(&image, child_process.STACK_START, &segments);
    try std.testing.expectError(error.SegmentOverlapsStack, child_process.plan(&image));

    segments[0].virtual_address = 0x0040_0000;
    segments[0].flags = 6;
    initializeChildElf64(&image, 0x0040_0000, &segments);
    try std.testing.expectError(error.EntryPointNotExecutable, child_process.plan(&image));
}

test "child ELF planner enforces bounded segment metadata" {
    var image = [_]u8{0} ** 0x500;
    var segments: [child_process.MAX_LOAD_SEGMENTS + 1]ChildElfSegment = undefined;
    for (&segments, 0..) |*segment, index| {
        segment.* = .{
            .file_offset = 0x400 + index,
            .virtual_address = 0x0040_0000 + index * 0x2000,
            .file_size = 1,
            .memory_size = 0x1000,
            .flags = 5,
        };
    }
    initializeChildElf64(&image, 0x0040_0000, &segments);
    try std.testing.expectError(error.TooManyLoadSegments, child_process.plan(&image));
}

test "child construction rolls back every resource when final start fails" {
    var image = [_]u8{0} ** 0x300;
    const segments = [_]ChildElfSegment{.{
        .file_offset = 0x200,
        .virtual_address = 0x0040_0000,
        .file_size = 4,
        .memory_size = 0x1000,
        .flags = 5,
    }};
    initializeChildElf64(&image, 0x0040_0000, &segments);
    @memcpy(image[0x200..0x204], "code");

    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{physicalDescriptor(
        0x1000,
        child_process.STACK_SIZE + 0x4000,
        1,
    )};
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    ChildRollbackEnvironment.reset();

    try std.testing.expectError(
        error.InvalidState,
        child_process.createAndStart(
            ChildRollbackEnvironment,
            &allocator,
            .{ .capability = 77 },
            &image,
            .{ .mode = .ipc_ping_pong },
            88,
            89,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);
    try std.testing.expectEqual(@as(u64, child_process.STACK_SIZE + 0x4000), allocator.statistics().free_bytes);

    const expected_tail = [_]abi.syscall.SyscallNumber{
        .destroy_thread,
        .unmap_address_space,
        .destroy_memory_object,
        .unmap_address_space,
        .destroy_memory_object,
        .destroy_address_space,
        .delete_capability,
        .delete_capability,
        .destroy_capability_space,
    };
    try std.testing.expect(ChildRollbackEnvironment.syscall_count >= expected_tail.len);
    const tail_start = ChildRollbackEnvironment.syscall_count - expected_tail.len;
    for (expected_tail, 0..) |expected, index| {
        try std.testing.expectEqual(
            @intFromEnum(expected),
            ChildRollbackEnvironment.syscall_numbers[tail_start + index],
        );
    }
    try std.testing.expectEqual(
        [_]usize{ 100, 88, abi.capability.rightsBits(.{ .receive = true }), 0, 0 },
        ChildRollbackEnvironment.syscall_arguments[2],
    );
    try std.testing.expectEqual(
        [_]usize{ 100, 89, abi.capability.rightsBits(.{ .send = true }), 0, 0 },
        ChildRollbackEnvironment.syscall_arguments[3],
    );
    try std.testing.expectEqual(
        [_]usize{ 100, 103, 0, 0, 0 },
        ChildRollbackEnvironment.syscall_arguments[tail_start + expected_tail.len - 3],
    );
    try std.testing.expectEqual(
        [_]usize{ 100, 102, 0, 0, 0 },
        ChildRollbackEnvironment.syscall_arguments[tail_start + expected_tail.len - 2],
    );

    const startup_offset = child_process.PAGE_SIZE + child_process.STACK_SIZE -
        @sizeOf(abi.process.ChildStartup);
    const child_startup: *const abi.process.ChildStartup = @ptrCast(@alignCast(
        &ChildRollbackEnvironment.loader_memory[startup_offset],
    ));
    try std.testing.expectEqual(abi.process.ChildStartupMode.ipc_ping_pong, child_startup.mode);
    try std.testing.expectEqual(@as(u32, 102), child_startup.request_endpoint_capability);
    try std.testing.expectEqual(@as(u32, 103), child_startup.reply_endpoint_capability);
    try std.testing.expect(child_startup.request_endpoint_capability != 88);
    try std.testing.expect(child_startup.reply_endpoint_capability != 89);
}

test "child construction deletes a derived frame when memory-object creation fails" {
    var image = [_]u8{0} ** 0x300;
    const segments = [_]ChildElfSegment{.{
        .file_offset = 0x200,
        .virtual_address = 0x0040_0000,
        .file_size = 4,
        .memory_size = 0x1000,
        .flags = 5,
    }};
    initializeChildElf64(&image, 0x0040_0000, &segments);

    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{physicalDescriptor(0x1000, 0x4000, 1)};
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    MemoryObjectFailureEnvironment.reset();

    try std.testing.expectError(
        error.OutOfResources,
        child_process.createAndStart(
            MemoryObjectFailureEnvironment,
            &allocator,
            .{ .capability = 77 },
            &image,
            .{ .mode = .invalid_opcode },
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);
    try std.testing.expectEqual(@as(u64, 0x4000), allocator.statistics().free_bytes);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.delete_physical_memory),
        MemoryObjectFailureEnvironment.syscall_numbers[4],
    );
}
