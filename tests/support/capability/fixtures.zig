const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

pub fn resetState() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.memory_management.physical_memory_authority.resetForTest();
}

pub fn createFrameCapability(size_in_bytes: u64) !abi.capability.CapabilityHandle {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    const root = try kernel.capability.createUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        0,
        size_in_bytes,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );
    return kernel.capability.retypeUntypedMemoryCapability(
        kernel.process.ROOT_PROCESS_HANDLE,
        root,
        0,
        @intCast(size_in_bytes / 0x1000),
        .physical_frame,
        .{ .manage = true, .read = true, .write = true },
    );
}
