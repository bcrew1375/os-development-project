const std = @import("std");
const arch = @import("arch");
const bootstrap = @import("kernel_common").memory_management.physical_memory_bootstrap;
const ranges = @import("kernel_common").memory_management.physical_ranges;

fn normalize(
    memory_map: []const ranges.MemoryMapInput,
    exclusions: []const ranges.Exclusion,
    page_size: u64,
    allocatable: []ranges.Range,
    retained: []ranges.RetainedRange,
) ranges.Error!ranges.Result {
    var scratch = ranges.Scratch{};
    return ranges.normalize(
        memory_map,
        exclusions,
        page_size,
        allocatable,
        retained,
        &scratch,
    );
}

test "Physical ranges normalize deterministically and subtract page-rounded exclusions" {
    const memory_map = [_]ranges.MemoryMapInput{
        .{ .start = 0x9000, .size = 0x3000, .kind = .reserved },
        .{ .start = 3, .size = 0x8ffd, .kind = .available },
    };
    const exclusions = [_]ranges.Exclusion{
        .{ .start = 0x5100, .size = 1, .reason = .boot_module },
        .{ .start = 0x2000, .size = 0x1000, .reason = .kernel_image },
    };
    var allocatable: [8]ranges.Range = undefined;
    var retained: [8]ranges.RetainedRange = undefined;

    const result = try normalize(&memory_map, &exclusions, 0x1000, &allocatable, &retained);

    try std.testing.expectEqual(@as(usize, 3), result.allocatable_count);
    try std.testing.expectEqual(ranges.Range{ .start = 0x1000, .end = 0x2000 }, allocatable[0]);
    try std.testing.expectEqual(ranges.Range{ .start = 0x3000, .end = 0x5000 }, allocatable[1]);
    try std.testing.expectEqual(ranges.Range{ .start = 0x6000, .end = 0x9000 }, allocatable[2]);
    try std.testing.expectEqual(@as(usize, 4), result.retained_count);
    try std.testing.expectEqual(ranges.RetainedReason.page_alignment, retained[0].reason);
    try std.testing.expectEqual(ranges.RetainedReason.kernel_image, retained[1].reason);
    try std.testing.expectEqual(ranges.RetainedReason.boot_module, retained[2].reason);
    try std.testing.expectEqual(ranges.RetainedReason.memory_map_reserved, retained[3].reason);
}

test "Physical ranges reject overlap empty ranges overflow and invalid page sizes" {
    var allocatable: [4]ranges.Range = undefined;
    var retained: [4]ranges.RetainedRange = undefined;

    try std.testing.expectError(error.OverlappingMemoryMap, normalize(
        &.{
            .{ .start = 0, .size = 0x2000, .kind = .available },
            .{ .start = 0x1000, .size = 0x1000, .kind = .reserved },
        },
        &.{},
        0x1000,
        &allocatable,
        &retained,
    ));
    try std.testing.expectError(error.EmptyRange, normalize(
        &.{.{ .start = 0, .size = 0, .kind = .available }},
        &.{},
        0x1000,
        &allocatable,
        &retained,
    ));
    try std.testing.expectError(error.RangeOverflow, normalize(
        &.{.{ .start = std.math.maxInt(u64), .size = 2, .kind = .available }},
        &.{},
        0x1000,
        &allocatable,
        &retained,
    ));
    try std.testing.expectError(error.InvalidPageSize, normalize(
        &.{.{ .start = 0, .size = 0x1000, .kind = .available }},
        &.{},
        3,
        &allocatable,
        &retained,
    ));
}

test "Physical ranges produce identical output for equivalent input orderings" {
    const ascending = [_]ranges.MemoryMapInput{
        .{ .start = 0, .size = 0x2000, .kind = .available },
        .{ .start = 0x2000, .size = 0x1000, .kind = .reserved },
        .{ .start = 0x3000, .size = 0x2000, .kind = .available },
    };
    const shuffled = [_]ranges.MemoryMapInput{ ascending[2], ascending[0], ascending[1] };
    var first_allocatable: [4]ranges.Range = undefined;
    var first_retained: [4]ranges.RetainedRange = undefined;
    var second_allocatable: [4]ranges.Range = undefined;
    var second_retained: [4]ranges.RetainedRange = undefined;

    const first = try normalize(&ascending, &.{}, 0x1000, &first_allocatable, &first_retained);
    const second = try normalize(&shuffled, &.{}, 0x1000, &second_allocatable, &second_retained);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualSlices(ranges.Range, first_allocatable[0..first.allocatable_count], second_allocatable[0..second.allocatable_count]);
    try std.testing.expectEqualSlices(ranges.RetainedRange, first_retained[0..first.retained_count], second_retained[0..second.retained_count]);
}

test "Physical range native conversion is checked at the boundary" {
    const native = try (ranges.Range{ .start = 0x1000, .end = 0x3000 }).toNative();
    try std.testing.expectEqual(ranges.NativeRange{ .start = 0x1000, .end = 0x3000 }, native);

    if (@sizeOf(usize) == 4) {
        try std.testing.expectError(
            error.NativeWidthOverflow,
            (ranges.Range{ .start = 0x1_0000_0000, .end = 0x1_0000_1000 }).toNative(),
        );
    }
}

test "Physical bootstrap adapter preserves reservation provenance" {
    arch.impl.test_support.resetState();
    try arch.early_allocator.reserve(0x1000, 0x1000, .KERNEL_READ_ONLY);
    try arch.early_allocator.reserve(0x3000, 0x1000, .DEVICE_MEMORY);
    try arch.early_allocator.reserve(0x5000, 0x1000, .PAGE_TABLE_POOL);
    var exclusions: [8]ranges.Exclusion = undefined;

    const count = try bootstrap.adaptExclusions(
        &.{},
        arch.early_allocator.getReservedMap(),
        &exclusions,
        std.math.maxInt(u64),
    );

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(ranges.RetainedReason.kernel_image, exclusions[0].reason);
    try std.testing.expectEqual(ranges.RetainedReason.framebuffer_or_mmio, exclusions[1].reason);
    try std.testing.expectEqual(ranges.RetainedReason.kernel_page_table_pool, exclusions[2].reason);
}

test "Physical bootstrap adapter excludes RAM above the physical address limit" {
    arch.impl.test_support.resetState();
    const memory_map = [_]arch.MemoryMapEntry{.{
        .address = 0xffff_f000,
        .size = 0x3000,
        .region_type = .AVAILABLE,
    }};
    var exclusions: [4]ranges.Exclusion = undefined;

    const count = try bootstrap.adaptExclusions(
        &memory_map,
        arch.early_allocator.getReservedMap(),
        &exclusions,
        std.math.maxInt(u32),
    );

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), exclusions[0].start);
    try std.testing.expectEqual(@as(u64, 0x2000), exclusions[0].size);
    try std.testing.expectEqual(ranges.RetainedReason.physical_address_limit, exclusions[0].reason);
}
