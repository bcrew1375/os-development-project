const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

fn testSetup() void {
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
    arch.impl.test_support.resetState();
}

test "Execution context: root context is explicit and replaceable" {
    testSetup();

    try std.testing.expectError(
        error.ExecutionContextUninitialized,
        kernel.process.execution_context.current(),
    );

    try kernel.process.execution_context.initializeRoot(7);
    const root = try kernel.process.execution_context.current();
    try std.testing.expectEqual(kernel.process.execution_context.ROOT_THREAD_HANDLE, root.thread_handle);
    try std.testing.expectEqual(kernel.process.execution_context.ROOT_CAPABILITY_SPACE_HANDLE, root.capability_space_handle);
    try std.testing.expectEqual(@as(u32, 7), root.address_space_handle);
    try std.testing.expectEqual(kernel.process.ROOT_PROCESS_HANDLE, root.process_handle);

    try kernel.process.execution_context.replace(.{
        .thread_handle = 2,
        .capability_space_handle = 3,
        .address_space_handle = 4,
        .process_handle = 42,
    });
    const replaced = try kernel.process.execution_context.current();
    try std.testing.expectEqual(@as(u32, 2), replaced.thread_handle);
    try std.testing.expectEqual(@as(u32, 3), replaced.capability_space_handle);
    try std.testing.expectEqual(@as(u32, 4), replaced.address_space_handle);
    try std.testing.expectEqual(@as(u32, 42), replaced.process_handle);
}

test "Execution context: production syscall dispatch rejects an uninitialized context" {
    testSetup();

    const result = kernel.syscall.dispatchFromCurrentContext(.{
        .number = @intFromEnum(abi.syscall.SyscallNumber.create_address_space),
    });
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(kernel.syscall.Operation.resolve_execution_context, failure.operation);
            try std.testing.expectEqual(error.ExecutionContextUninitialized, failure.err);
        },
        else => return error.UnexpectedSyscallResult,
    }
}

test "Process: createAddressSpace returns tracked address space object with hardware root" {
    testSetup();

    const handle = try kernel.process.createAddressSpace();
    try std.testing.expect(handle != abi.syscall.INVALID_HANDLE);

    const address_space = try kernel.process.getAddressSpace(handle);
    try std.testing.expectEqual(@as(usize, 0), address_space.length);
    try std.testing.expect(address_space.virtual_memory_areas.len > 0);
    const root = try kernel.process.getAddressSpaceRoot(handle);
    try std.testing.expect(root.value != 0);
}

test "Process: address spaces receive independent hardware roots" {
    testSetup();

    const first_handle = try kernel.process.createAddressSpace();
    const second_handle = try kernel.process.createAddressSpace();
    const first_root = try kernel.process.getAddressSpaceRoot(first_handle);
    const second_root = try kernel.process.getAddressSpaceRoot(second_handle);

    try std.testing.expect(first_root.value != 0);
    try std.testing.expect(second_root.value != 0);
    try std.testing.expect(first_root.value != second_root.value);

    try arch.mmu.mapTableInAddressSpace(first_root, 0x0040_0000, 0, .{});
    try arch.mmu.mapPageInAddressSpace(first_root, 0x0040_0000, 0x1000, .{});
    try arch.mmu.mapTableInAddressSpace(second_root, 0x0040_0000, 0, .{});
    try arch.mmu.mapPageInAddressSpace(second_root, 0x0040_0000, 0x2000, .{});

    try std.testing.expectEqual(@as(?usize, 0x1000), arch.mmu.getPhysicalAddressInAddressSpace(first_root, 0x0040_0000));
    try std.testing.expectEqual(@as(?usize, 0x2000), arch.mmu.getPhysicalAddressInAddressSpace(second_root, 0x0040_0000));
}

test "Process: address-space creation failure does not publish a slot" {
    testSetup();
    arch.mmu.failAddressSpaceRootCreationForTest(true);

    try std.testing.expectError(
        error.AddressSpaceRootAllocationFailed,
        kernel.process.createAddressSpace(),
    );
    arch.mmu.failAddressSpaceRootCreationForTest(false);

    const handle = try kernel.process.createAddressSpace();
    try std.testing.expectEqual(@as(u32, 1), handle);
}

test "Process: owner-aware creation preserves object ownership" {
    testSetup();
    const owner: kernel.process.ProcessHandle = 42;
    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const memory_object = try kernel.process.createMemoryObjectForOwner(owner, 0x1000);

    try std.testing.expectEqual(owner, try kernel.process.getAddressSpaceOwner(address_space));
    try std.testing.expectEqual(owner, try kernel.process.getMemoryObjectOwner(memory_object));
    try std.testing.expectError(
        error.InvalidAddressSpaceHandle,
        kernel.process.getAddressSpaceOwner(abi.syscall.INVALID_HANDLE),
    );
    try std.testing.expectError(
        error.InvalidMemoryObjectHandle,
        kernel.process.getMemoryObjectOwner(abi.syscall.INVALID_HANDLE),
    );
}

test "Process: invalid address space handle is rejected" {
    testSetup();

    try std.testing.expectError(error.InvalidAddressSpaceHandle, kernel.process.getAddressSpace(abi.syscall.INVALID_HANDLE));
    try std.testing.expectError(error.InvalidAddressSpaceHandle, kernel.process.getAddressSpace(1234));
}

test "Process: address space table exhaustion returns error" {
    testSetup();

    var created: usize = 0;
    while (created < 16) : (created += 1) {
        _ = try kernel.process.createAddressSpace();
    }

    try std.testing.expectError(error.OutOfAddressSpaces, kernel.process.createAddressSpace());
}

test "Process: mapMemory maps user-accessible virtual memory area" {
    testSetup();

    const handle = try kernel.process.createAddressSpace();
    try kernel.process.mapMemory(handle, 0x0100_0000, 0x2000);

    const address_space = try kernel.process.getAddressSpace(handle);
    try std.testing.expectEqual(@as(usize, 1), address_space.length);

    const mapped_area = address_space.virtual_memory_areas[0];
    try std.testing.expectEqual(@as(u64, 0x0100_0000), mapped_area.start_address);
    try std.testing.expectEqual(@as(u64, 0x0100_2000), mapped_area.end_address);
    try std.testing.expect(mapped_area.permissions.readable);
    try std.testing.expect(mapped_area.permissions.writeable);
    try std.testing.expect(!mapped_area.permissions.executable);
    try std.testing.expect(mapped_area.permissions.user_accessible);
    try std.testing.expectEqual(abi.syscall.INVALID_HANDLE, mapped_area.memory_object_handle);
    try std.testing.expectEqual(@as(u64, 0), mapped_area.memory_object_offset);
}

test "Process: mapMemory rejects invalid ranges" {
    testSetup();

    const handle = try kernel.process.createAddressSpace();

    try std.testing.expectError(error.EmptyMemoryRange, kernel.process.mapMemory(handle, 0x0100_0000, 0));
    try std.testing.expectError(error.UnalignedVirtualMemoryArea, kernel.process.mapMemory(handle, 0x0100_0001, 0x1000));
    try std.testing.expectError(error.MemoryRangeOverflow, kernel.process.mapMemory(handle, std.math.maxInt(u64), 0x1000));
    try std.testing.expectError(error.KernelAddressRange, kernel.process.mapMemory(handle, 0xC000_0000, 0x1000));
    try std.testing.expectError(error.KernelAddressRange, kernel.process.mapMemory(handle, 0xBFFF_F000, 0x2000));
}

test "Process: protect query and unmap require the same exact range" {
    testSetup();
    const handle = try kernel.process.createAddressSpace();
    try kernel.process.mapMemory(handle, 0x0180_0000, 0x2000);

    try kernel.process.protectAddressSpace(
        handle,
        0x0180_0000,
        0x2000,
        abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE,
    );
    try std.testing.expectEqual(
        abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE,
        try kernel.process.queryAddressSpace(handle, 0x0180_0000, 0x2000),
    );
    try std.testing.expectError(
        error.UndefinedVirtualMemoryArea,
        kernel.process.queryAddressSpace(handle, 0x0180_0000, 0x1000),
    );
    try std.testing.expectError(
        error.UndefinedVirtualMemoryArea,
        kernel.process.protectAddressSpace(handle, 0x0180_0000, 0x1000, abi.syscall.MAP_READ),
    );

    try kernel.process.unmapAddressSpace(handle, 0x0180_0000, 0x2000);
    try std.testing.expectError(
        error.UndefinedVirtualMemoryArea,
        kernel.process.unmapAddressSpace(handle, 0x0180_0000, 0x2000),
    );
}

test "Process: destroy rejects the active space and reuses bounded storage" {
    testSetup();
    const active_handle = try kernel.process.createAddressSpace();
    const inactive_handle = try kernel.process.createAddressSpace();
    try kernel.process.execution_context.initializeRoot(active_handle);

    try std.testing.expectError(
        error.AddressSpaceInUse,
        kernel.process.destroyAddressSpace(active_handle),
    );
    _ = try kernel.process.getAddressSpace(active_handle);

    try kernel.process.mapMemory(inactive_handle, 0x0190_0000, 0x1000);
    try kernel.process.destroyAddressSpace(inactive_handle);
    try std.testing.expectError(
        error.InvalidAddressSpaceHandle,
        kernel.process.getAddressSpace(inactive_handle),
    );

    var created: usize = 0;
    while (created < 15) : (created += 1) {
        _ = try kernel.process.createAddressSpace();
    }
    try std.testing.expectError(error.OutOfAddressSpaces, kernel.process.createAddressSpace());
}

test "Process: createMemoryObject returns tracked memory object handle" {
    testSetup();

    const handle = try kernel.process.createMemoryObject(0x2000);
    try std.testing.expect(handle != abi.syscall.INVALID_HANDLE);
}

test "Process: createMemoryObject rejects invalid sizes" {
    testSetup();

    try std.testing.expectError(error.EmptyMemoryRange, kernel.process.createMemoryObject(0));
    try std.testing.expectError(error.UnalignedMemoryObjectRange, kernel.process.createMemoryObject(1));
    try std.testing.expectError(error.UnalignedMemoryObjectRange, kernel.process.createMemoryObject(0x1001));
}

test "Process: memory object table exhaustion returns error" {
    testSetup();

    var created: usize = 0;
    while (created < 64) : (created += 1) {
        _ = try kernel.process.createMemoryObject(0x1000);
    }

    try std.testing.expectError(error.OutOfMemoryObjects, kernel.process.createMemoryObject(0x1000));
}

test "Process: mapMemoryObject maps object-backed virtual memory area" {
    testSetup();

    const address_space_handle = try kernel.process.createAddressSpace();
    const memory_object_handle = try kernel.process.createMemoryObject(0x4000);

    try kernel.process.mapMemoryObject(
        address_space_handle,
        memory_object_handle,
        0x0200_0000,
        0x1000,
        0x2000,
        abi.syscall.MAP_READ | abi.syscall.MAP_WRITE,
    );

    const address_space = try kernel.process.getAddressSpace(address_space_handle);
    try std.testing.expectEqual(@as(usize, 1), address_space.length);

    const mapped_area = address_space.virtual_memory_areas[0];
    try std.testing.expectEqual(@as(u64, 0x0200_0000), mapped_area.start_address);
    try std.testing.expectEqual(@as(u64, 0x0200_2000), mapped_area.end_address);
    try std.testing.expectEqual(memory_object_handle, mapped_area.memory_object_handle);
    try std.testing.expectEqual(@as(u64, 0x1000), mapped_area.memory_object_offset);
    try std.testing.expect(mapped_area.permissions.readable);
    try std.testing.expect(mapped_area.permissions.writeable);
    try std.testing.expect(!mapped_area.permissions.executable);
    try std.testing.expect(mapped_area.permissions.user_accessible);
}

test "Process: mapMemoryObject converts execute-only permission flags" {
    testSetup();

    const address_space_handle = try kernel.process.createAddressSpace();
    const memory_object_handle = try kernel.process.createMemoryObject(0x1000);

    try kernel.process.mapMemoryObject(
        address_space_handle,
        memory_object_handle,
        0x0300_0000,
        0,
        0x1000,
        abi.syscall.MAP_EXECUTE,
    );

    const address_space = try kernel.process.getAddressSpace(address_space_handle);
    const mapped_area = address_space.virtual_memory_areas[0];
    try std.testing.expect(!mapped_area.permissions.readable);
    try std.testing.expect(!mapped_area.permissions.writeable);
    try std.testing.expect(mapped_area.permissions.executable);
    try std.testing.expect(mapped_area.permissions.user_accessible);
}

test "Process: mapMemoryObject supports every nonempty permission combination" {
    testSetup();
    const address_space_handle = try kernel.process.createAddressSpace();
    const memory_object_handle = try kernel.process.createMemoryObject(7 * 0x1000);

    for (1..8) |flags| {
        const index = flags - 1;
        try kernel.process.mapMemoryObject(
            address_space_handle,
            memory_object_handle,
            0x0500_0000 + index * 0x1000,
            index * 0x1000,
            0x1000,
            @intCast(flags),
        );
    }

    const address_space = try kernel.process.getAddressSpace(address_space_handle);
    try std.testing.expectEqual(@as(usize, 7), address_space.length);
    for (address_space.virtual_memory_areas[0..address_space.length], 1..) |area, flags| {
        try std.testing.expectEqual((flags & abi.syscall.MAP_READ) != 0, area.permissions.readable);
        try std.testing.expectEqual((flags & abi.syscall.MAP_WRITE) != 0, area.permissions.writeable);
        try std.testing.expectEqual((flags & abi.syscall.MAP_EXECUTE) != 0, area.permissions.executable);
    }
}

test "Process: mapMemoryObject propagates overlap and object range overflow" {
    testSetup();
    const address_space_handle = try kernel.process.createAddressSpace();
    const memory_object_handle = try kernel.process.createMemoryObject(std.math.maxInt(u64) & ~@as(u64, 0xfff));

    try kernel.process.mapMemoryObject(
        address_space_handle,
        memory_object_handle,
        0x0600_0000,
        0,
        0x1000,
        abi.syscall.MAP_READ,
    );
    try std.testing.expectError(
        error.OverlappingVirtualMemoryArea,
        kernel.process.mapMemoryObject(
            address_space_handle,
            memory_object_handle,
            0x0600_0000,
            0x1000,
            0x1000,
            abi.syscall.MAP_READ,
        ),
    );
    try std.testing.expectError(
        error.ObjectRangeOverflow,
        kernel.process.mapMemoryObject(
            address_space_handle,
            memory_object_handle,
            0x0700_0000,
            std.math.maxInt(u64) - 0xfff,
            0x2000,
            abi.syscall.MAP_READ,
        ),
    );
}

test "Process: mapMemoryObject rejects invalid handles and ranges" {
    testSetup();

    const address_space_handle = try kernel.process.createAddressSpace();
    const memory_object_handle = try kernel.process.createMemoryObject(0x2000);

    try std.testing.expectError(
        error.InvalidMemoryObjectHandle,
        kernel.process.mapMemoryObject(address_space_handle, abi.syscall.INVALID_HANDLE, 0x0400_0000, 0, 0x1000, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.InvalidAddressSpaceHandle,
        kernel.process.mapMemoryObject(abi.syscall.INVALID_HANDLE, memory_object_handle, 0x0400_0000, 0, 0x1000, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.EmptyMemoryRange,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0x0400_0000, 0, 0, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.UnalignedMemoryObjectRange,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0x0400_0000, 1, 0x1000, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.UnalignedMemoryObjectRange,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0x0400_0000, 0, 0x1001, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.ObjectRangeOutOfBounds,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0x0400_0000, 0x1000, 0x2000, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.MemoryRangeOverflow,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, std.math.maxInt(u64), 0, 0x1000, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.KernelAddressRange,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0xBFFF_F000, 0, 0x2000, abi.syscall.MAP_READ),
    );
    try std.testing.expectError(
        error.InvalidMemoryPermissions,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0x0400_0000, 0, 0x1000, 0),
    );
    try std.testing.expectError(
        error.InvalidMemoryPermissions,
        kernel.process.mapMemoryObject(address_space_handle, memory_object_handle, 0x0400_0000, 0, 0x1000, 1 << 8),
    );
}
