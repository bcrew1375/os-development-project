const abi = @import("abi");
const memory_management = @import("memory_management");
const startup = @import("startup");
const std = @import("std");

const RecordingEnvironment = @import("support/recording_environment.zig").RecordingEnvironment;
const physicalDescriptor = @import("support/boot_fixtures.zig").physicalDescriptor;
const memory_manager = memory_management.operations;
const Heap = memory_management.Heap;
const PhysicalRangeAllocator = memory_management.PhysicalRangeAllocator;
const manager = memory_manager.MemoryManager(RecordingEnvironment);
const TestRootTaskHeap = memory_management.RootTaskHeap(manager);

test "heap validates requests tracks accounting and completely coalesces" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = try Heap.initialize(@intFromPtr(&backing), backing.len);
    try std.testing.expect(heap.isCompletelyFree());
    try std.testing.expectError(error.EmptyAllocation, heap.allocate(0, 8));
    try std.testing.expectError(error.InvalidAlignment, heap.allocate(1, 3));

    const first = try heap.allocate(128, 64);
    const second = try heap.allocate(256, 256);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first.ptr) % 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(second.ptr) % 256);
    try std.testing.expectEqual(@as(usize, 384), heap.statistics().allocated_payload_bytes);
    try std.testing.expectEqual(@as(usize, 2), heap.statistics().allocation_count);

    try heap.free(first);
    try heap.free(second);
    try std.testing.expect(heap.isCompletelyFree());
    try std.testing.expectEqual(@as(usize, 0), heap.statistics().allocated_payload_bytes);
}

test "heap rejects foreign and duplicate frees" {
    var backing: [4096]u8 align(64) = undefined;
    var foreign_backing: [64]u8 align(64) = undefined;
    var heap = try Heap.initialize(@intFromPtr(&backing), backing.len);
    const allocation = try heap.allocate(64, 8);
    try std.testing.expectError(error.InvalidAllocation, heap.free(foreign_backing[0..32]));
    try heap.free(allocation);
    try std.testing.expectError(error.DuplicateFree, heap.free(allocation));
}

fn initializeHeapPhysicalAllocator(allocator: *PhysicalRangeAllocator) !void {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{physicalDescriptor(
        0x1000,
        4 * startup.INITIAL_HEAP_EXTENT_SIZE,
        1,
    )};
    try allocator.initialize(&descriptors);
}

fn rejectMappedAddress(_: usize, _: usize) ?usize {
    return null;
}

test "root task heap grows deterministically and reclaims empty later extents" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.SYSCALL_SUCCESS,
        22,
        32,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });
    var heap = try TestRootTaskHeap.initialize(
        &allocator,
        .{ .capability = 11 },
        0x0100_0000,
        0x0100_4000,
        startup.INITIAL_HEAP_EXTENT_SIZE,
        RecordingEnvironment.mappedMemoryAddress,
    );
    const first = try heap.allocate(128, 64);
    const second = try heap.allocate(4000, 64);
    try std.testing.expectEqual(@as(usize, 2), heap.statistics().extent_count);
    try std.testing.expect(@intFromPtr(second.ptr) > @intFromPtr(first.ptr));

    try heap.free(second);
    try std.testing.expectEqual(@as(usize, 1), try heap.reclaimEmptyExtents());
    try std.testing.expectEqual(@as(usize, 1), heap.statistics().extent_count);
    try std.testing.expectEqual(@as(usize, 1), allocator.statistics().allocation_count);
    try heap.free(first);
    try std.testing.expectError(error.InitialExtentCannotBeReclaimed, heap.reclaimExtent(0));
}

test "root task heap initialization rolls back each unpublished stage" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);

    RecordingEnvironment.reset(&.{abi.syscall.errorResult(.out_of_resources)});
    try std.testing.expectError(
        error.OutOfResources,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);

    RecordingEnvironment.reset(&.{
        21,
        abi.syscall.errorResult(.out_of_resources),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectError(
        error.OutOfResources,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);

    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectError(
        error.InvalidPermissions,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);
}

test "root task heap retains physical ownership when cleanup fails" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.errorResult(.internal_failure),
    });
    try std.testing.expectError(
        error.CleanupFailed,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), allocator.statistics().allocation_count);
}

test "root task heap resolver failure unwinds mapping object and physical range" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectError(
        error.MappedAddressUnavailable,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            rejectMappedAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 5), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.unmap_address_space),
        RecordingEnvironment.syscalls[3].three.number,
    );
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_memory_object),
        RecordingEnvironment.syscalls[4].three.number,
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);
}

test "root task heap reclamation retries partial cleanup and reuses virtual holes" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.SYSCALL_SUCCESS,
        22,
        32,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.errorResult(.internal_failure),
        abi.syscall.SYSCALL_SUCCESS,
        23,
        33,
        abi.syscall.SYSCALL_SUCCESS,
    });
    var heap = try TestRootTaskHeap.initialize(
        &allocator,
        .{ .capability = 11 },
        0x0100_0000,
        0x0100_4000,
        startup.INITIAL_HEAP_EXTENT_SIZE,
        RecordingEnvironment.mappedMemoryAddress,
    );
    const initial_allocation = try heap.allocate(128, 64);
    const allocation = try heap.allocate(4000, 64);
    const reclaimed_address = @intFromPtr(allocation.ptr);
    try heap.free(allocation);

    try std.testing.expectError(error.CleanupFailed, heap.reclaimExtent(1));
    try std.testing.expectEqual(@as(usize, 2), heap.statistics().extent_count);
    try heap.reclaimExtent(1);
    try std.testing.expectEqual(@as(usize, 1), heap.statistics().extent_count);

    const replacement = try heap.allocate(4000, 64);
    try std.testing.expectEqual(reclaimed_address, @intFromPtr(replacement.ptr));
    try heap.free(replacement);
    try heap.free(initial_allocation);
}
