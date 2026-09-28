const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const testSetup = fixtures.resetState;

fn fillCapabilityTableWithUntypedMemory() !void {
    for (0..kernel.capability.MAX_CAPABILITIES) |index| {
        _ = try kernel.capability.createUntypedMemoryCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            index * 0x1000,
            0x1000,
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            0x1000,
        );
    }
}

test "Capability: table exhaustion is explicit" {
    testSetup();

    try fillCapabilityTableWithUntypedMemory();
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
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, capability, .{ .configure = true }),
    );
}

test "Capability: creation reports capability exhaustion before backing exhaustion" {
    testSetup();

    try fillCapabilityTableWithUntypedMemory();
    try std.testing.expectError(
        error.OutOfCapabilities,
        kernel.capability.createAddressSpaceCapability(kernel.process.ROOT_PROCESS_HANDLE),
    );
}
