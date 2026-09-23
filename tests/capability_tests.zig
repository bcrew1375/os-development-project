const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

fn testSetup() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
}

test "Capability: create and resolve address-space capability" {
    testSetup();

    const capability = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    try std.testing.expect(capability != abi.capability.INVALID_CAPABILITY);

    const address_space_handle = try kernel.capability.resolveAddressSpace(
        kernel.process.ROOT_PROCESS_HANDLE,
        capability,
        .{ .manage = true },
    );

    const address_space = try kernel.process.getAddressSpace(address_space_handle);
    try std.testing.expectEqual(@as(usize, 0), address_space.length);
}

test "Capability: create and resolve memory-object capability" {
    testSetup();

    const capability = try kernel.capability.createMemoryObjectCapability(kernel.process.ROOT_PROCESS_HANDLE, 0x1000);
    try std.testing.expect(capability != abi.capability.INVALID_CAPABILITY);

    const memory_object_handle = try kernel.capability.resolveMemoryObject(
        kernel.process.ROOT_PROCESS_HANDLE,
        capability,
        .{ .read = true, .write = true },
    );

    const address_space_handle = try kernel.process.createAddressSpace();
    try kernel.process.mapMemoryObject(
        address_space_handle,
        memory_object_handle,
        0x0200_0000,
        0,
        0x1000,
        abi.syscall.MAP_READ | abi.syscall.MAP_WRITE,
    );
}

test "Capability: invalid capability is rejected" {
    testSetup();

    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, abi.capability.INVALID_CAPABILITY, .{}),
    );

    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveMemoryObject(kernel.process.ROOT_PROCESS_HANDLE, 1234, .{}),
    );
}

test "Capability: object type mismatch is rejected" {
    testSetup();

    const address_space_capability = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    const memory_object_capability = try kernel.capability.createMemoryObjectCapability(kernel.process.ROOT_PROCESS_HANDLE, 0x1000);

    try std.testing.expectError(
        error.InvalidCapabilityType,
        kernel.capability.resolveMemoryObject(kernel.process.ROOT_PROCESS_HANDLE, address_space_capability, .{}),
    );

    try std.testing.expectError(
        error.InvalidCapabilityType,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, memory_object_capability, .{}),
    );
}

test "Capability: owner mismatch is rejected" {
    testSetup();

    const capability = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);

    try std.testing.expectError(
        error.CapabilityOwnerMismatch,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE + 1, capability, .{}),
    );
}

test "Capability: deleting and reusing a slot rejects the stale handle" {
    testSetup();

    const first = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    try kernel.capability.deleteCapability(kernel.process.ROOT_PROCESS_HANDLE, first);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, first, .{}),
    );

    const second = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    try std.testing.expect(second != first);
    try std.testing.expectEqual(
        abi.capability.capabilitySlotIndex(first),
        abi.capability.capabilitySlotIndex(second),
    );
    try std.testing.expect(
        abi.capability.capabilityGeneration(second) != abi.capability.capabilityGeneration(first),
    );
    _ = try kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, second, .{});
}

test "Capability: destroying an address space invalidates its generation" {
    testSetup();
    kernel.process.execution_context.resetForTest();

    const first = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    try kernel.capability.destroyAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE, first);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, first, .{}),
    );

    const second = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    try std.testing.expectEqual(
        abi.capability.capabilitySlotIndex(first),
        abi.capability.capabilitySlotIndex(second),
    );
    try std.testing.expect(
        abi.capability.capabilityGeneration(first) != abi.capability.capabilityGeneration(second),
    );
}

test "Capability: failed active address-space destruction preserves capability" {
    testSetup();
    kernel.process.execution_context.resetForTest();

    const address_space_capability = try kernel.capability.createAddressSpaceCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
    );
    const address_space_handle = try kernel.capability.resolveAddressSpace(
        kernel.process.ROOT_PROCESS_HANDLE,
        address_space_capability,
        .{ .manage = true },
    );
    try kernel.process.execution_context.initializeRoot(address_space_handle);

    try std.testing.expectError(
        error.AddressSpaceInUse,
        kernel.capability.destroyAddressSpaceCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            address_space_capability,
        ),
    );
    try std.testing.expectEqual(
        address_space_handle,
        try kernel.capability.resolveAddressSpace(
            kernel.process.ROOT_PROCESS_HANDLE,
            address_space_capability,
            .{ .manage = true },
        ),
    );
}

test "Capability: table exhaustion is explicit" {
    testSetup();

    for (0..16) |_| {
        _ = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    }
    try std.testing.expectError(
        error.OutOfCapabilities,
        kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE),
    );
}

test "Capability: missing rights are rejected" {
    testSetup();

    const capability = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);

    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, capability, .{ .execute = true }),
    );
}

test "Capability: creation reports capability exhaustion before backing exhaustion" {
    testSetup();

    for (0..16) |_| {
        _ = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    }
    try std.testing.expectError(
        error.OutOfCapabilities,
        kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE),
    );
}
