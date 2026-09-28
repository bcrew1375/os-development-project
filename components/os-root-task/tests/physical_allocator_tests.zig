const abi = @import("abi");
const memory_management = @import("memory_management");
const std = @import("std");

const physicalDescriptor = @import("support/boot_fixtures.zig").physicalDescriptor;
const PhysicalRangeAllocator = memory_management.PhysicalRangeAllocator;

test "physical allocator splits aligned first-fit ranges and preserves accounting" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x8000, 1),
        physicalDescriptor(0x20_000, 0x2000, 2),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);

    const handle = try allocator.allocate(0x2000, 0x4000);
    const range = try allocator.resolve(handle);
    try std.testing.expectEqual(@as(u64, 0x4000), range.physical_start);
    try std.testing.expectEqual(@as(u64, 0x3000), range.offset);
    try std.testing.expectEqual(descriptors[0].capability, range.parent_capability);
    try std.testing.expectEqual(@as(u64, 0x2000), range.size);

    const statistics = allocator.statistics();
    try std.testing.expectEqual(@as(u64, 0xA000), statistics.delegated_bytes);
    try std.testing.expectEqual(@as(u64, 0x8000), statistics.free_bytes);
    try std.testing.expectEqual(@as(u64, 0x2000), statistics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 3), statistics.free_extent_count);
    try std.testing.expectEqual(@as(usize, 1), statistics.allocation_count);
}

test "physical allocator exhausts without returning holes" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x1000, 1),
        physicalDescriptor(0x4000, 0x1000, 2),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);

    const first = try allocator.allocate(0x1000, 0x1000);
    const second = try allocator.allocate(0x1000, 0x1000);
    try std.testing.expectEqual(@as(u64, 0x1000), (try allocator.resolve(first)).physical_start);
    try std.testing.expectEqual(@as(u64, 0x4000), (try allocator.resolve(second)).physical_start);
    try std.testing.expectError(error.Exhausted, allocator.allocate(1, 1));
    try std.testing.expectEqual(@as(u64, 0), allocator.statistics().free_bytes);
}

test "physical allocator rejects invalid requests and overflow transactionally" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x4000, 1),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    const before = allocator.statistics();

    try std.testing.expectError(error.EmptyAllocation, allocator.allocate(0, 0x1000));
    try std.testing.expectError(error.InvalidAlignment, allocator.allocate(1, 0));
    try std.testing.expectError(error.InvalidAlignment, allocator.allocate(1, 3));
    try std.testing.expectError(error.AllocationOverflow, allocator.allocate(std.math.maxInt(u64), 1));
    try std.testing.expectEqualDeep(before, allocator.statistics());
}

test "physical allocator rejects duplicate foreign fabricated and stale handles" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x4000, 1),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    var foreign_allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    try foreign_allocator.initialize(&descriptors);

    const original = try allocator.allocate(0x1000, 0x1000);
    try std.testing.expectError(error.ForeignHandle, foreign_allocator.resolve(original));
    var fabricated = original;
    fabricated.guard ^= 1;
    try std.testing.expectError(error.InvalidHandle, allocator.resolve(fabricated));

    try allocator.free(original);
    try std.testing.expectError(error.DuplicateFree, allocator.free(original));
    const replacement = try allocator.allocate(0x1000, 0x1000);
    try std.testing.expectError(error.StaleHandle, allocator.resolve(original));
    try std.testing.expectEqual(@as(u64, 0x1000), (try allocator.resolve(replacement)).physical_start);
}

test "physical allocator coalesces only adjacent ranges with the same parent" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x3000, 1),
        physicalDescriptor(0x4000, 0x1000, 2),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);

    const first = try allocator.allocate(0x1000, 0x1000);
    const second = try allocator.allocate(0x1000, 0x1000);
    const third = try allocator.allocate(0x1000, 0x1000);
    try allocator.free(second);
    try allocator.free(first);
    try allocator.free(third);

    const statistics = allocator.statistics();
    try std.testing.expectEqual(statistics.delegated_bytes, statistics.free_bytes);
    try std.testing.expectEqual(@as(u64, 0), statistics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 2), statistics.free_extent_count);
    try std.testing.expectEqual(@as(usize, 0), statistics.allocation_count);
}

test "physical allocator reports allocation-slot exhaustion without mutation" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x1000 * (PhysicalRangeAllocator.MAX_ALLOCATIONS + 1), 1),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    var handles: [PhysicalRangeAllocator.MAX_ALLOCATIONS]PhysicalRangeAllocator.AllocationHandle = undefined;
    for (&handles) |*handle| handle.* = try allocator.allocate(0x1000, 0x1000);
    const before = allocator.statistics();

    try std.testing.expectError(error.MetadataExhausted, allocator.allocate(0x1000, 0x1000));
    try std.testing.expectEqualDeep(before, allocator.statistics());
    for (handles) |handle| _ = try allocator.resolve(handle);
}

test "physical allocator reports extent exhaustion without mutation" {
    var descriptors: [PhysicalRangeAllocator.MAX_FREE_EXTENTS]abi.boot_info.PhysicalMemoryInfo = undefined;
    descriptors[0] = physicalDescriptor(0x1000, 0x5000, 1);
    for (descriptors[1..], 1..) |*descriptor, index| {
        descriptor.* = physicalDescriptor(0x10_000 + index * 0x2000, 0x1000, @intCast(index + 1));
    }
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    const before = allocator.statistics();

    try std.testing.expectError(error.MetadataExhausted, allocator.allocate(0x1000, 0x4000));
    try std.testing.expectEqualDeep(before, allocator.statistics());
}
