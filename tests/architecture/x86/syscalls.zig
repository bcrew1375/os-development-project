const arch = @import("arch");
const abi = @import("abi");
const kernel = @import("kernel_common");
const framework = @import("../framework.zig");

pub fn interruptGatePreservesRegisterAbi() !void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
    kernel.memory_management.physical_memory_authority.resetForTest();
    const active_capability = try kernel.capability.createAddressSpaceCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
    );
    const active_address_space = try kernel.capability.resolveAddressSpace(
        kernel.process.ROOT_PROCESS_HANDLE,
        active_capability,
        .{ .manage = true },
    );
    try kernel.process.execution_context.initializeRoot(active_address_space);
    @call(.never_inline, arch.boot.finishBoot, .{});

    const address_space_capability = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_address_space),
        0,
        0,
        0,
    );
    try framework.expect(address_space_capability != abi.capability.INVALID_CAPABILITY);

    const anonymous_virtual_start: usize = 0x0200_0000;
    const anonymous_size: usize = 0x2000;
    try framework.expectEqual(
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.syscall3(
            @intFromEnum(abi.syscall.SyscallNumber.map_memory),
            address_space_capability,
            anonymous_virtual_start,
            anonymous_size,
        ),
    );

    const memory_object_size: usize = 0x3000;
    const physical_frames = arch.early_allocator.allocate(
        memory_object_size,
        arch.mmu.getPageSize(),
        arch.ReservedMapRegionType.PERSISTENT,
    ) catch return framework.TestError.ExpectationFailed;
    const untyped_capability = kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        @intFromPtr(physical_frames),
        memory_object_size,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        arch.mmu.getPageSize(),
    ) catch return framework.TestError.ExpectationFailed;
    const frame_capability = abi.syscall.syscall5(
        @intFromEnum(abi.syscall.SyscallNumber.retype_untyped_memory),
        untyped_capability,
        0,
        0,
        memory_object_size / arch.mmu.getPageSize(),
        abi.syscall.packRetypeTarget(
            .physical_frame,
            .{ .manage = true, .read = true, .write = true, .execute = true },
        ),
    );
    try framework.expect(frame_capability != abi.capability.INVALID_CAPABILITY);
    const memory_object_capability = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_memory_object),
        frame_capability,
        0,
        0,
    );
    try framework.expect(memory_object_capability != abi.capability.INVALID_CAPABILITY);

    const object_virtual_start: usize = 0x0300_0000;
    const object_size: usize = 0x1000;
    const permission_flags = abi.syscall.MAP_READ | abi.syscall.MAP_EXECUTE;
    try framework.expectEqual(
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.syscall5(
            @intFromEnum(abi.syscall.SyscallNumber.map_memory_object),
            address_space_capability,
            memory_object_capability,
            object_virtual_start,
            object_size,
            permission_flags,
        ),
    );
    try framework.expectEqual(
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.syscall5(
            @intFromEnum(abi.syscall.SyscallNumber.map_memory_object),
            address_space_capability,
            memory_object_capability,
            0x0400_0000,
            object_size,
            0,
        ),
    );

    const address_space_handle = kernel.capability.resolveAddressSpace(
        kernel.process.ROOT_PROCESS_HANDLE,
        address_space_capability,
        .{ .manage = true },
    ) catch return framework.TestError.ExpectationFailed;
    const address_space = kernel.process.getAddressSpace(address_space_handle) catch
        return framework.TestError.ExpectationFailed;

    try framework.expectEqual(@as(usize, 2), address_space.length);
    const anonymous_area = address_space.virtual_memory_areas[0];
    try framework.expectEqual(@as(u64, anonymous_virtual_start), anonymous_area.start_address);
    try framework.expectEqual(@as(u64, anonymous_virtual_start + anonymous_size), anonymous_area.end_address);

    const object_area = address_space.virtual_memory_areas[1];
    try framework.expectEqual(@as(u64, object_virtual_start), object_area.start_address);
    try framework.expectEqual(@as(u64, object_virtual_start + object_size), object_area.end_address);
    try framework.expect(object_area.permissions.readable);
    try framework.expect(!object_area.permissions.writeable);
    try framework.expect(object_area.permissions.executable);
    try framework.expectEqual(@as(u64, 0), object_area.memory_object_offset);
    try framework.expectEqual(
        @as(?usize, @intFromPtr(physical_frames)),
        arch.mmu.getPhysicalAddressInAddressSpace(
            kernel.process.getAddressSpaceRoot(address_space_handle) catch
                return framework.TestError.ExpectationFailed,
            object_virtual_start,
        ),
    );

    const capability_space = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_capability_space),
        0,
        0,
        0,
    );
    try framework.expect(capability_space != abi.capability.INVALID_CAPABILITY);
    const thread = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_thread),
        0,
        0,
        0,
    );
    try framework.expect(thread != abi.capability.INVALID_CAPABILITY);
    const installed = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.install_capability),
        capability_space,
        thread,
        abi.capability.rightsBits(.{ .terminate = true }),
    );
    try framework.expect(installed != abi.capability.INVALID_CAPABILITY);
    try framework.expectEqual(
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.syscall3(
            @intFromEnum(abi.syscall.SyscallNumber.delete_capability),
            capability_space,
            installed,
            0,
        ),
    );
    try framework.expectEqual(
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.syscall3(
            @intFromEnum(abi.syscall.SyscallNumber.destroy_thread),
            thread,
            0,
            0,
        ),
    );
    try framework.expectEqual(
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.syscall3(
            @intFromEnum(abi.syscall.SyscallNumber.destroy_capability_space),
            capability_space,
            0,
            0,
        ),
    );
}
