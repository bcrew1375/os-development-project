const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const createFrameCapability = fixtures.createFrameCapability;
const testSetup = fixtures.resetState;

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
    const memory_object_capability = try kernel.capability.createMemoryObjectCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        try createFrameCapability(0x1000),
    );

    try std.testing.expectError(
        error.InvalidCapabilityType,
        kernel.capability.resolveMemoryObject(kernel.process.ROOT_PROCESS_HANDLE, address_space_capability, .{}),
    );

    try std.testing.expectError(
        error.InvalidCapabilityType,
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, memory_object_capability, .{}),
    );
}

test "Capability: local handles do not resolve in another capability space" {
    testSetup();

    const capability = try kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE);
    const foreign_space = try kernel.process.capability_spaces.create();

    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveAddressSpace(foreign_space, capability, .{}),
    );
}
