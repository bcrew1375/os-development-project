const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const testSetup = fixtures.resetState;

test "Capability: installation attenuates rights and isolates local handles" {
    testSetup();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        target_capability,
        .{ .manage = true },
    );
    const thread_capability = try kernel.capability.createThreadCapability(root_space);
    const installed = try kernel.capability.installCapability(
        root_space,
        target_capability,
        thread_capability,
        .{ .terminate = true },
    );
    _ = try kernel.capability.resolveThread(target_space, installed, .{ .terminate = true });
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolveThread(target_space, installed, .{ .configure = true }),
    );
    try std.testing.expectError(
        error.InvalidCapabilityRights,
        kernel.capability.installCapability(
            root_space,
            target_capability,
            thread_capability,
            .{ .execute = true },
        ),
    );
    try std.testing.expectError(
        error.CapabilityHasDescendants,
        kernel.capability.destroyThreadCapability(root_space, thread_capability),
    );
    try std.testing.expectError(
        error.CapabilitySpaceNotEmpty,
        kernel.capability.destroyCapabilitySpaceCapability(root_space, target_capability),
    );
    try kernel.capability.deleteCapability(target_space, installed);
    try kernel.capability.destroyThreadCapability(root_space, thread_capability);
    try kernel.capability.destroyCapabilitySpaceCapability(root_space, target_capability);
}

test "Capability: exact-slot installation prepares commits and rolls back transactionally" {
    testSetup();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        target_space_capability,
        .{},
    );
    const source = try kernel.capability.createEndpointCapability(root_space);
    const destination_slot: u32 = 17;
    const prepared = try kernel.capability.prepareExactInstall(
        root_space,
        source,
        target_space,
        destination_slot,
        .{ .send = true },
    );
    try std.testing.expectEqual(@as(usize, 0), try kernel.capability.activeCountIn(target_space));

    const installed = kernel.capability.commitExactInstall(prepared);
    try std.testing.expectEqual(destination_slot, abi.capability.capabilitySlotIndex(installed));
    _ = try kernel.capability.resolveEndpoint(target_space, installed, .{ .send = true });
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolveEndpoint(target_space, installed, .{ .receive = true }),
    );

    kernel.capability.rollbackExactInstall(prepared, installed);
    try std.testing.expectEqual(@as(usize, 0), try kernel.capability.activeCountIn(target_space));
    const reinstalled = kernel.capability.commitExactInstall(prepared);
    try std.testing.expectEqual(installed, reinstalled);
}

test "Capability: exact-slot preparation rejects occupied invalid amplified and ungranted sources" {
    testSetup();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const target_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const target_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        target_space_capability,
        .{},
    );
    const source = try kernel.capability.createEndpointCapability(root_space);
    const first = try kernel.capability.prepareExactInstall(
        root_space,
        source,
        target_space,
        9,
        .{ .receive = true },
    );
    _ = kernel.capability.commitExactInstall(first);
    try std.testing.expectError(
        error.CapabilitySlotOccupied,
        kernel.capability.prepareExactInstall(root_space, source, target_space, 9, .{}),
    );
    try std.testing.expectError(
        error.InvalidCapabilitySlot,
        kernel.capability.prepareExactInstall(
            root_space,
            source,
            target_space,
            kernel.capability.MAX_CAPABILITIES,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidCapabilityRights,
        kernel.capability.prepareExactInstall(
            root_space,
            source,
            target_space,
            10,
            .{ .terminate = true },
        ),
    );

    const ungranted = try kernel.capability.installCapability(
        root_space,
        target_space_capability,
        source,
        .{ .send = true },
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.prepareExactInstall(target_space, ungranted, root_space, 20, .{}),
    );
}
