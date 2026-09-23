const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

fn testSetup() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.memory_management.physical_memory_authority.resetForTest();
}

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
        kernel.capability.resolveAddressSpace(kernel.process.ROOT_PROCESS_HANDLE, capability, .{ .execute = true }),
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

test "Capability: untyped memory resolves authority and destruction is transactional" {
    testSetup();
    const capability = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0x4000,
        0x2000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    const handle = try kernel.capability.resolveUntypedMemory(
        kernel.process.ROOT_PROCESS_HANDLE,
        capability,
        .{ .manage = true },
    );
    try std.testing.expectEqual(
        @as(u64, 0x4000),
        (try kernel.memory_management.physical_memory_authority.get(handle)).physical_start,
    );

    try kernel.capability.destroyUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        capability,
    );
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveUntypedMemory(
            kernel.process.ROOT_PROCESS_HANDLE,
            capability,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidAuthority,
        kernel.memory_management.physical_memory_authority.get(handle),
    );
}

test "Capability: retype attenuates rights and resolves typed frames" {
    testSetup();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0x10_0000,
        0x8000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    const frame = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0x2000,
        2,
        .physical_frame,
        .{ .read = true },
    );
    const authority_handle = try kernel.capability.resolvePhysicalFrame(
        kernel.process.ROOT_PROCESS_HANDLE,
        frame,
        .{ .read = true },
    );
    const metadata = try kernel.memory_management.physical_memory_authority.get(authority_handle);
    try std.testing.expectEqual(@as(u64, 0x10_2000), metadata.physical_start);
    try std.testing.expectEqual(@as(u64, 0x10_4000), metadata.physical_end);
    try std.testing.expectEqual(
        kernel.memory_management.physical_memory_authority.Kind.physical_frame,
        metadata.kind,
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.resolvePhysicalFrame(
            kernel.process.ROOT_PROCESS_HANDLE,
            frame,
            .{ .write = true },
        ),
    );
    try std.testing.expectError(
        error.InsufficientCapabilityRights,
        kernel.capability.deletePhysicalMemoryCapability(kernel.process.ROOT_PROCESS_HANDLE, frame),
    );
}

test "Capability: retype rejects rights amplification and overlapping siblings" {
    testSetup();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        0x8000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    const child = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0,
        4,
        .untyped_memory,
        .{ .read = true, .manage = true },
    );
    try std.testing.expectError(
        error.InvalidCapabilityRights,
        kernel.capability.retypeUntypedMemoryCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            child,
            0,
            1,
            .physical_frame,
            .{ .write = true },
        ),
    );
    try std.testing.expectError(
        error.OverlappingAuthority,
        kernel.capability.retypeUntypedMemoryCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            root,
            0x2000,
            1,
            .physical_frame,
            .{ .manage = true },
        ),
    );
}

test "Capability: delete and revoke invalidate descendants and permit range reuse" {
    testSetup();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        0x8000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    const child = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0,
        4,
        .untyped_memory,
        .{ .manage = true },
    );
    const frame = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        child,
        0,
        1,
        .physical_frame,
        .{ .manage = true },
    );
    try std.testing.expectError(
        error.CapabilityHasDescendants,
        kernel.capability.deletePhysicalMemoryCapability(kernel.process.ROOT_PROCESS_HANDLE, child),
    );
    try kernel.capability.deletePhysicalMemoryCapability(kernel.process.ROOT_PROCESS_HANDLE, frame);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolvePhysicalFrame(kernel.process.ROOT_PROCESS_HANDLE, frame, .{}),
    );

    const replacement = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        child,
        0,
        1,
        .physical_frame,
        .{ .manage = true },
    );
    try std.testing.expect(frame != replacement);
    try kernel.capability.revokePhysicalMemoryCapability(kernel.process.ROOT_PROCESS_HANDLE, root);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveUntypedMemory(kernel.process.ROOT_PROCESS_HANDLE, child, .{}),
    );
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolvePhysicalFrame(kernel.process.ROOT_PROCESS_HANDLE, replacement, .{}),
    );

    const reused = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0,
        1,
        .physical_frame,
        .{ .manage = true },
    );
    _ = try kernel.capability.resolvePhysicalFrame(kernel.process.ROOT_PROCESS_HANDLE, reused, .{});
}

test "Capability: retype capacity preflight leaves authority state unchanged" {
    testSetup();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        0x1000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    var physical_start: u64 = 0x10_0000;
    while (kernel.capability.availableCount() > 0) {
        _ = try kernel.capability.createUntypedMemoryCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            physical_start,
            0x1000,
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            0x1000,
        );
        physical_start += 0x1000;
    }
    const authorities_before = kernel.memory_management.physical_memory_authority.activeCount();
    try std.testing.expectError(
        error.OutOfCapabilities,
        kernel.capability.retypeUntypedMemoryCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            root,
            0,
            1,
            .physical_frame,
            .{ .manage = true },
        ),
    );
    try std.testing.expectEqual(
        authorities_before,
        kernel.memory_management.physical_memory_authority.activeCount(),
    );
}

test "Capability: authority capacity preflight leaves capability state unchanged" {
    testSetup();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        0x1000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    var physical_start: u64 = 0x10_0000;
    while (kernel.memory_management.physical_memory_authority.availableCount() > 0) {
        _ = try kernel.memory_management.physical_memory_authority.createRoot(
            physical_start,
            0x1000,
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            0x1000,
        );
        physical_start += 0x1000;
    }
    const capabilities_before = kernel.capability.activeCount();
    try std.testing.expectError(
        error.OutOfAuthorities,
        kernel.capability.retypeUntypedMemoryCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            root,
            0,
            1,
            .physical_frame,
            .{ .manage = true },
        ),
    );
    try std.testing.expectEqual(capabilities_before, kernel.capability.activeCount());
}
