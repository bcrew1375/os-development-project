const arch = @import("arch");
const std = @import("std");

fn initializeFixture(regions: []const arch.mmu.FixtureRegion) !void {
    try arch.impl.test_support.initializeMemoryFixture(16 * 4096, regions);
}

test "Early allocator rejects invalid size and alignment" {
    try initializeFixture(&.{.{ .offset = 0, .size = 16 * 4096, .region_type = .AVAILABLE }});
    defer arch.impl.test_support.deinitializeMemoryFixture();

    try std.testing.expectError(error.InvalidSize, arch.early_allocator.allocate(0, 4096, .PERSISTENT));
    try std.testing.expectError(error.InvalidAlignment, arch.early_allocator.allocate(4096, 0, .PERSISTENT));
    try std.testing.expectError(error.InvalidAlignment, arch.early_allocator.allocate(4096, 3, .PERSISTENT));
}

test "Early allocator aligns allocations and preserves reservation type" {
    try initializeFixture(&.{.{ .offset = 1, .size = 8 * 4096, .region_type = .AVAILABLE }});
    defer arch.impl.test_support.deinitializeMemoryFixture();

    const allocation = try arch.early_allocator.allocate(4096, 4096, .DEVICE_MEMORY);
    try std.testing.expectEqual(@as(usize, 4096), @intFromPtr(allocation));
    const reserved = arch.early_allocator.getReservedMap();
    try std.testing.expectEqual(@as(usize, 1), reserved.length);
    try std.testing.expectEqual(arch.ReservedMapRegionType.DEVICE_MEMORY, reserved.entries[0].region_type);
}

test "Early allocator skips reservations and later unavailable regions" {
    try initializeFixture(&.{
        .{ .offset = 0, .size = 2 * 4096, .region_type = .AVAILABLE },
        .{ .offset = 2 * 4096, .size = 2 * 4096, .region_type = .RESERVED },
        .{ .offset = 4 * 4096, .size = 4 * 4096, .region_type = .AVAILABLE },
    });
    defer arch.impl.test_support.deinitializeMemoryFixture();
    try arch.early_allocator.initialize();
    try arch.early_allocator.reserve(0, 2 * 4096, .TEMPORARY);

    const allocation = try arch.early_allocator.allocate(4096, 4096, .PERSISTENT);
    try std.testing.expectEqual(@as(usize, 4 * 4096), @intFromPtr(allocation));
}

test "Early allocator reports out of space and reservation exhaustion" {
    try initializeFixture(&.{.{ .offset = 0, .size = 4096, .region_type = .AVAILABLE }});
    defer arch.impl.test_support.deinitializeMemoryFixture();

    _ = try arch.early_allocator.allocate(4096, 4096, .PERSISTENT);
    try std.testing.expectError(error.OutOfSpace, arch.early_allocator.allocate(1, 1, .PERSISTENT));

    arch.impl.test_support.resetState();
    for (0..arch.MAX_EARLY_RESERVATIONS) |index| {
        try arch.early_allocator.reserve(index, 1, .TEMPORARY);
    }
    try std.testing.expectError(error.OutOfReservations, arch.early_allocator.reserve(4096, 1, .TEMPORARY));
}

test "Early allocator rejects malformed and overlapping memory maps" {
    try initializeFixture(&.{.{ .offset = 0, .size = 4096, .region_type = .AVAILABLE }});
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const memory_map = arch.mmu.getMemoryMap();

    memory_map.entries[0].size = 0;
    try std.testing.expectError(error.InvalidMemoryMap, arch.early_allocator.initialize());

    memory_map.entries[0] = .{ .address = 4096, .size = 4096, .region_type = .AVAILABLE };
    memory_map.entries[1] = .{ .address = 4096, .size = 4096, .region_type = .AVAILABLE };
    memory_map.length = 2;
    try std.testing.expectError(error.InvalidMemoryMap, arch.early_allocator.allocate(1, 1, .PERSISTENT));

    memory_map.entries[0] = .{
        .address = std.math.maxInt(u64),
        .size = 2,
        .region_type = .AVAILABLE,
    };
    memory_map.length = 1;
    try std.testing.expectError(error.InvalidMemoryMap, arch.early_allocator.initialize());
}

test "Early allocator accepts a region ending at the native address limit" {
    try initializeFixture(&.{.{ .offset = 0, .size = 4096, .region_type = .AVAILABLE }});
    defer arch.impl.test_support.deinitializeMemoryFixture();
    const memory_map = arch.mmu.getMemoryMap();
    memory_map.entries[0] = .{
        .address = std.math.maxInt(usize) - 4095,
        .size = 4096,
        .region_type = .RESERVED,
    };

    try arch.early_allocator.initialize();
    const reserved = arch.early_allocator.getReservedMap();
    try std.testing.expectEqual(@as(usize, 1), reserved.length);
    try std.testing.expectEqual(std.math.maxInt(usize) - 4095, reserved.entries[0].address);
}
