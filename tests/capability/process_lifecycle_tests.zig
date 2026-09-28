const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const testSetup = fixtures.resetState;

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
