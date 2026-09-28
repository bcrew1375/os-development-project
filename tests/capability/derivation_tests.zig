const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const testSetup = fixtures.resetState;

test "Capability: derivation traversal follows reused capability-space generations" {
    testSetup();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const stale_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const stale_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        stale_capability,
        .{ .manage = true },
    );
    try kernel.capability.destroyCapabilitySpaceCapability(root_space, stale_capability);
    const target_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        target_capability,
        .{ .manage = true },
    );
    try std.testing.expect(target_space != stale_space);
    const thread_capability = try kernel.capability.createThreadCapability(root_space);
    const installed = try kernel.capability.installCapability(
        root_space,
        target_capability,
        thread_capability,
        .{ .terminate = true },
    );
    try std.testing.expectError(
        error.CapabilityHasDescendants,
        kernel.capability.destroyThreadCapability(root_space, thread_capability),
    );
    try kernel.capability.deleteCapability(target_space, installed);
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
