const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel_common");

fn setup() !arch.AddressSpaceRoot {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    errdefer arch.impl.test_support.deinitializeMemoryFixture();

    const root = try arch.mmu.createAddressSpaceRoot();
    try arch.mmu.mapTableInAddressSpace(root, 0x0040_0000, 0, .{ .user = true, .write = true });
    try arch.mmu.mapPageInAddressSpace(root, 0x0040_0000, 0x1000, .{ .user = true, .write = true });
    arch.mmu.switchAddressSpaceRoot(root);
    return root;
}

fn teardown() void {
    arch.impl.test_support.deinitializeMemoryFixture();
}

test "User memory: range construction rejects empty, oversized, overflowing, and kernel ranges" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer teardown();

    try std.testing.expectError(error.EmptyRange, kernel.user_memory.UserSlice.init(0x1000, 0));
    try std.testing.expectError(
        error.CopyTooLarge,
        kernel.user_memory.UserSlice.init(0x1000, kernel.user_memory.MAX_COPY_BYTES + 1),
    );
    try std.testing.expectError(
        error.AddressRangeOverflow,
        kernel.user_memory.UserSlice.init(std.math.maxInt(u64), 2),
    );
    try std.testing.expectError(
        error.KernelAddressRange,
        kernel.user_memory.UserSlice.init(arch.mmu.getKernelVirtualAddressStart(), 1),
    );
}

test "User memory: copyFromUser reads a mapped page through the direct map" {
    _ = try setup();
    defer teardown();

    try arch.impl.mmu.writePhysicalMemoryForTest(0x1000, "hello");
    var destination: [5]u8 = undefined;
    try kernel.user_memory.copyFromUser(&destination, 0x0040_0000, destination.len);
    try std.testing.expectEqualStrings("hello", &destination);
}

test "User memory: copyToUser writes only writable user pages" {
    const root = try setup();
    defer teardown();

    try kernel.user_memory.copyToUser(0x0040_0000, "world");
    var destination: [5]u8 = undefined;
    try arch.impl.mmu.readVirtualMemoryInAddressSpaceForTest(root, 0x0040_0000, &destination);
    try std.testing.expectEqualStrings("world", &destination);

    try arch.mmu.mapPageInAddressSpace(root, 0x0040_0000, 0x1000, .{ .user = true });
    try std.testing.expectError(
        error.WriteAccessDenied,
        kernel.user_memory.copyToUser(0x0040_0000, "write"),
    );
}

test "User memory: cross-page copies validate every page" {
    const root = try setup();
    defer teardown();

    try arch.mmu.mapPageInAddressSpace(root, 0x0040_1000, 0x2000, .{ .user = true, .write = true });
    try arch.impl.mmu.writePhysicalMemoryForTest(0x1ffc, "abcd");
    try arch.impl.mmu.writePhysicalMemoryForTest(0x2000, "efgh");

    var destination: [8]u8 = undefined;
    try kernel.user_memory.copyFromUser(&destination, 0x0040_0000 + 4092, destination.len);
    try std.testing.expectEqualStrings("abcdefgh", &destination);
}

test "User memory: unmapped and injected lookup failures are recoverable" {
    _ = try setup();
    defer teardown();

    var destination: [1]u8 = undefined;
    try std.testing.expectError(
        error.UserPageNotMapped,
        kernel.user_memory.copyFromUser(&destination, 0x0050_0000, destination.len),
    );

    arch.mmu.failPhysicalLookupCallForTest(2);
    try std.testing.expectError(
        error.UserPageNotMapped,
        kernel.user_memory.copyFromUser(&destination, 0x0040_0000, destination.len),
    );
}
