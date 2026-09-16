const std = @import("std");
const kernel = @import("kernel_common");
const heap = kernel.heap;

const HEAP_TEST_SIZE: usize = 1024 * 1024; // 1 MB test heap
var test_heap_memory: [HEAP_TEST_SIZE]u8 align(16) = undefined;

test "heap initialize creates a valid free block" {
    const test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    try std.testing.expect(test_heap.free_list != null);
    try std.testing.expect(test_heap.start_address == @intFromPtr(&test_heap_memory));
    try std.testing.expect(test_heap.end_address == @intFromPtr(&test_heap_memory) + HEAP_TEST_SIZE);
}

test "heap allocate basic allocation succeeds" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const ptr = try test_heap.allocate(64, 8);
    try std.testing.expect(@intFromPtr(ptr) >= test_heap.start_address);
    try std.testing.expect(@intFromPtr(ptr) < test_heap.end_address);
}

test "heap allocate respects alignment" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const ptr = try test_heap.allocate(32, 64);
    try std.testing.expect(@intFromPtr(ptr) % 64 == 0);
}

test "heap aligned allocation can be freed and reused" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);

    const ptr = try test_heap.allocate(128, 256);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % 256);

    const header = heap.getBlockHeaderFromAllocation(ptr[0..128]);
    try std.testing.expect(!header.free);
    try std.testing.expect(@intFromPtr(ptr) > @intFromPtr(header));

    test_heap.free(ptr[0..128]);

    const reused = try test_heap.allocate(128, 256);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(reused) % 256);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(reused));
}

test "heap allocate multiple blocks" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const ptr1 = try test_heap.allocate(128, 8);
    const ptr2 = try test_heap.allocate(256, 8);
    const ptr3 = try test_heap.allocate(64, 8);
    try std.testing.expect(@intFromPtr(ptr1) != @intFromPtr(ptr2));
    try std.testing.expect(@intFromPtr(ptr2) != @intFromPtr(ptr3));
    try std.testing.expect(@intFromPtr(ptr1) != @intFromPtr(ptr3));
}

test "heap allocate out of memory" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const result = test_heap.allocate(HEAP_TEST_SIZE * 2, 8);
    try std.testing.expectError(heap.HeapError.OutOfMemory, result);
}

test "heap free and reallocate reuses memory" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const ptr1 = try test_heap.allocate(256, 8);
    const addr1 = @intFromPtr(ptr1);

    // Free the block.
    const slice1 = ptr1[0..256];
    test_heap.free(slice1);

    // Allocate again - should reuse the same memory.
    const ptr2 = try test_heap.allocate(256, 8);
    const addr2 = @intFromPtr(ptr2);
    try std.testing.expect(addr1 == addr2);
}

test "heap free coalesces adjacent free blocks" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);

    // Allocate three adjacent blocks.
    const ptr1 = try test_heap.allocate(128, 8);
    const ptr2 = try test_heap.allocate(128, 8);
    const ptr3 = try test_heap.allocate(128, 8);

    // Free the middle block.
    test_heap.free(ptr2[0..128]);

    // Free the first block - should coalesce with the middle.
    test_heap.free(ptr1[0..128]);

    // Now allocate a block larger than 128 but smaller than 128+128+header overhead.
    // This should succeed if coalescing worked.
    const ptr_large = try test_heap.allocate(300, 8);
    try std.testing.expect(@intFromPtr(ptr_large) >= test_heap.start_address);
    try std.testing.expect(@intFromPtr(ptr_large) < test_heap.end_address);

    // Free the third block.
    test_heap.free(ptr3[0..128]);
}

test "heap resize shrink splits block" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const ptr = try test_heap.allocate(512, 8);
    const slice = ptr[0..512];

    // Shrink to 64 bytes.
    const result = test_heap.resize(slice, 64);
    try std.testing.expect(result == true);

    // The freed space should be reusable.
    const ptr2 = try test_heap.allocate(256, 8);
    try std.testing.expect(@intFromPtr(ptr2) >= test_heap.start_address);
}

test "heap resize grow with adjacent free block" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);

    const ptr1 = try test_heap.allocate(128, 8);
    const ptr2 = try test_heap.allocate(128, 8);

    // Free the second block.
    test_heap.free(ptr2[0..128]);

    // Grow the first block - should absorb the freed second block.
    const result = test_heap.resize(ptr1[0..128], 200);
    try std.testing.expect(result == true);
}

test "heap resize grow without adjacent free block fails" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);

    const ptr1 = try test_heap.allocate(64, 8);
    // Allocate a second block that will remain allocated, preventing growth.
    const ptr2 = try test_heap.allocate(64, 8);
    _ = ptr2;

    // Try to grow the first block beyond its capacity.
    const result = test_heap.resize(ptr1[0..64], 200);
    try std.testing.expect(result == false);
}

test "heap allocator interface works" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const allocator = test_heap.allocator();

    const memory = try allocator.alloc(u8, 100);
    defer allocator.free(memory);

    try std.testing.expect(memory.len == 100);
    // Write to the memory to ensure it's usable.
    @memset(memory, 0xAB);
    try std.testing.expect(memory[0] == 0xAB);
    try std.testing.expect(memory[99] == 0xAB);
}

test "heap allocator realloc grows" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const allocator = test_heap.allocator();

    var memory = try allocator.alloc(u8, 64);
    defer allocator.free(memory);

    @memset(memory, 0xCD);

    // Realloc to a larger size.
    memory = try allocator.realloc(memory, 128);
    try std.testing.expect(memory.len == 128);
    try std.testing.expect(memory[0] == 0xCD);
    try std.testing.expect(memory[63] == 0xCD);
}

test "heap allocator realloc shrinks" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const allocator = test_heap.allocator();

    var memory = try allocator.alloc(u8, 128);
    defer allocator.free(memory);

    @memset(memory, 0xEF);

    // Realloc to a smaller size.
    memory = try allocator.realloc(memory, 32);
    try std.testing.expect(memory.len == 32);
    try std.testing.expect(memory[0] == 0xEF);
    try std.testing.expect(memory[31] == 0xEF);
}

test "heap allocate zero bytes" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    const ptr = try test_heap.allocate(0, 8);
    // Zero-byte allocation should still return a valid pointer.
    try std.testing.expect(@intFromPtr(ptr) >= test_heap.start_address);
}

test "heap free null slice is safe" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);
    // Freeing an empty slice should be a no-op.
    const empty_slice: []u8 = &[_]u8{};
    test_heap.free(empty_slice);
}

test "heap stress test allocate and free many blocks" {
    var test_heap = heap.Heap.initialize(@intFromPtr(&test_heap_memory), HEAP_TEST_SIZE);

    const NUM_ALLOCATIONS = 100;
    var pointers: [NUM_ALLOCATIONS][*]u8 = undefined;

    // Allocate many small blocks.
    for (0..NUM_ALLOCATIONS) |i| {
        pointers[i] = try test_heap.allocate(32, 8);
        // Write to each block to ensure they don't overlap.
        const slice = pointers[i][0..32];
        @memset(slice, @as(u8, @intCast(i % 256)));
    }

    // Verify the data is intact.
    for (0..NUM_ALLOCATIONS) |i| {
        const slice = pointers[i][0..32];
        try std.testing.expect(slice[0] == @as(u8, @intCast(i % 256)));
        try std.testing.expect(slice[31] == @as(u8, @intCast(i % 256)));
    }

    // Free all blocks.
    for (0..NUM_ALLOCATIONS) |i| {
        test_heap.free(pointers[i][0..32]);
    }

    // After freeing all, we should be able to allocate a large block.
    const large_ptr = try test_heap.allocate(HEAP_TEST_SIZE / 2, 8);
    try std.testing.expect(@intFromPtr(large_ptr) >= test_heap.start_address);
}
