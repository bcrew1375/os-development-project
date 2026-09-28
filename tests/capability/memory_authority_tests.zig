const std = @import("std");
const abi = @import("abi");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const testSetup = fixtures.resetState;

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
