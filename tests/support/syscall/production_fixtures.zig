const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

pub fn resetProductionState() void {
    kernel.capability.resetForTest();
    kernel.process.resetForTest();
    kernel.process.execution_context.resetForTest();
    kernel.memory_management.physical_memory_authority.resetForTest();
}

pub fn createProductionFrameCapability(size_in_bytes: u64) !abi.capability.CapabilityHandle {
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

pub fn initializeContext(process_handle: kernel.process.ProcessHandle) !void {
    try kernel.process.execution_context.initialize(.{
        .thread_handle = process_handle,
        .capability_space_handle = process_handle,
        .address_space_handle = process_handle,
        .process_handle = process_handle,
    });
}

pub fn writeFaultReplyRequest(physical_address: usize, fault_reply: abi.process.FaultReplyRequest) !void {
    try arch.mmu.writePhysicalMemoryForTest(physical_address, std.mem.asBytes(&fault_reply));
}

pub fn createPendingManagedFault(
    address_space_handle: kernel.process.AddressSpaceHandle,
    fault_endpoint_handle: kernel.ipc.endpoint.Handle,
    fault_token: u32,
    instruction_pointer: u64,
    trap_frame_address: usize,
) !kernel.process.thread.Handle {
    const handle = try kernel.process.createThread(kernel.process.ROOT_PROCESS_HANDLE);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space_handle,
        .entry_point = instruction_pointer,
        .stack_pointer = 0x0080_0000 + @as(u64, handle) * 0x1000,
        .fault_endpoint_handle = fault_endpoint_handle,
        .fault_token = fault_token,
    });
    try kernel.process.thread.makeReady(handle);
    try kernel.process.thread.startRunning(handle);
    const object = try kernel.process.thread.get(handle);
    try arch.thread_context.retainFaultFrame(
        object.architecture_context_handle,
        trap_frame_address,
        instruction_pointer,
    );
    try kernel.process.thread.suspendForFault(handle, .{
        .kind = .invalid_opcode,
        .instruction_pointer = instruction_pointer,
    });
    return handle;
}
