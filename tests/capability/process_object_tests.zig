const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const createFrameCapability = fixtures.createFrameCapability;
const testSetup = fixtures.resetState;

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

    const frame_capability = try createFrameCapability(0x1000);
    const capability = try kernel.capability.createMemoryObjectCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        frame_capability,
    );
    try std.testing.expectEqual(frame_capability, capability);
    try std.testing.expectError(
        error.InvalidCapabilityType,
        kernel.capability.resolvePhysicalFrame(kernel.process.ROOT_PROCESS_HANDLE, capability, .{}),
    );

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

test "Capability: memory-object conversion zeroes normal RAM before exposure" {
    testSetup();
    const frame_capability = try createFrameCapability(0x1000);
    try arch.mmu.writePhysicalMemoryForTest(0, &.{ 0xaa, 0xbb, 0xcc, 0xdd });

    _ = try kernel.capability.createMemoryObjectCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        frame_capability,
    );
    var contents: [4]u8 = undefined;
    try arch.mmu.readPhysicalMemoryForTest(0, &contents);
    try std.testing.expectEqual([_]u8{ 0, 0, 0, 0 }, contents);
}

test "Capability: explicit object destruction rejects mappings then releases authority" {
    testSetup();
    const capability = try kernel.capability.createMemoryObjectCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        try createFrameCapability(0x1000),
    );
    const memory_object = try kernel.capability.resolveMemoryObject(
        kernel.process.ROOT_PROCESS_HANDLE,
        capability,
        .{ .read = true },
    );
    const address_space = try kernel.process.createAddressSpace();
    try kernel.process.mapMemoryObject(
        address_space,
        memory_object,
        0x0240_0000,
        0,
        0x1000,
        abi.syscall.MAP_READ,
    );

    try std.testing.expectError(
        error.MemoryObjectInUse,
        kernel.capability.destroyMemoryObjectCapability(
            kernel.process.ROOT_PROCESS_HANDLE,
            capability,
        ),
    );
    try kernel.process.unmapAddressSpace(address_space, 0x0240_0000, 0x1000);
    try kernel.capability.destroyMemoryObjectCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        capability,
    );
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveMemoryObject(kernel.process.ROOT_PROCESS_HANDLE, capability, .{}),
    );
}

test "Capability: parent revoke forcibly unmaps and destroys memory objects" {
    testSetup();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        0x1000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    const frame = try kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0,
        1,
        .physical_frame,
        .{ .manage = true, .read = true },
    );
    const object = try kernel.capability.createMemoryObjectCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        frame,
    );
    const memory_object = try kernel.capability.resolveMemoryObject(
        kernel.process.ROOT_PROCESS_HANDLE,
        object,
        .{ .read = true },
    );
    const address_space = try kernel.process.createAddressSpace();
    const address_space_root = try kernel.process.getAddressSpaceRoot(address_space);
    try kernel.process.mapMemoryObject(
        address_space,
        memory_object,
        0x0250_0000,
        0,
        0x1000,
        abi.syscall.MAP_READ,
    );

    try kernel.capability.revokePhysicalMemoryCapability(kernel.process.ROOT_PROCESS_HANDLE, root);
    try std.testing.expectEqual(@as(usize, 0), (try kernel.process.getAddressSpace(address_space)).length);
    try std.testing.expect(arch.mmu.getPhysicalAddressInAddressSpace(address_space_root, 0x0250_0000) == null);
    try std.testing.expectError(
        error.InvalidCapability,
        kernel.capability.resolveMemoryObject(kernel.process.ROOT_PROCESS_HANDLE, object, .{}),
    );
}
