const arch = @import("arch");
const abi = @import("abi");
const kernel = @import("kernel_common");
const framework = @import("../framework.zig");

pub fn interruptGatePreservesRegisterAbi() !void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
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
    const memory_object_capability = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_memory_object),
        memory_object_size,
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
        abi.syscall.SYSCALL_FAILURE,
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
}
