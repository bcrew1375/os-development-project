const arch = @import("arch");
const builtin = @import("builtin");
const kernel = @import("kernel_common");
const framework = @import("../framework.zig");

const owner = kernel.process.ROOT_PROCESS_HANDLE;
const user_code_address: usize = 0x0040_0000;
const user_stack_address: usize = 0x0060_0000;

pub fn invalidOpcodeFaultIsContained() !void {
    kernel.process.resetForTest();

    const address_space = try kernel.process.createAddressSpaceForOwner(owner);
    const root = try kernel.process.getAddressSpaceRoot(address_space);
    try mapUserPage(root, user_code_address, &.{ 0x0F, 0x0B, 0xF4 }, .{ .user = true, .execute = true });
    try mapUserPage(root, user_stack_address, &.{}, .{ .write = true, .user = true });

    const current = try createThread(address_space, 0x0040_1000, validUserStackPointer(0x0080_0000));
    const faulting = try createThread(
        address_space,
        user_code_address,
        validUserStackPointer(user_stack_address + arch.mmu.getPageSize()),
    );
    const current_object = try kernel.process.thread.get(current);

    try kernel.process.scheduler.initialize(root);
    try kernel.process.thread.makeReady(current);
    try kernel.process.thread.startRunning(current);
    try kernel.process.scheduler.setCurrentThreadForTest(current);
    try kernel.process.scheduler.makeReady(faulting);
    try arch.thread_context.bindCurrentForTest(current_object.architecture_context_handle);
    @call(.never_inline, arch.boot.finishBoot, .{});

    try kernel.process.scheduler.yieldCurrent();

    const faulted = try kernel.process.thread.get(faulting);
    try framework.expectEqual(kernel.process.thread.State.faulted, faulted.state);
    const fault = faulted.user_fault orelse return framework.TestError.ExpectationFailed;
    try framework.expectEqual(kernel.process.thread.UserFaultKind.invalid_opcode, fault.kind);
    try framework.expectEqual(@as(u64, user_code_address), fault.instruction_pointer);
    try framework.expectEqual(@as(u64, 0), fault.architecture_error);
    try framework.expectEqual(
        @as(?kernel.process.thread.Handle, current),
        kernel.process.scheduler.currentThreadForTest(),
    );
}

fn createThread(
    address_space: kernel.process.AddressSpaceHandle,
    entry_point: usize,
    stack_pointer: usize,
) !kernel.process.thread.Handle {
    const handle = try kernel.process.createThread(owner);
    try kernel.process.configureThread(handle, .{
        .capability_space_handle = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space,
        .entry_point = entry_point,
        .stack_pointer = stack_pointer,
    });
    return handle;
}

fn mapUserPage(
    root: arch.AddressSpaceRoot,
    virtual_address: usize,
    bytes: []const u8,
    protection: arch.PageProtection,
) !void {
    const page_size = arch.mmu.getPageSize();
    const physical_memory = try arch.early_allocator.allocate(page_size, page_size, .PERSISTENT);
    const physical_address = @intFromPtr(physical_memory);
    const direct_map_address: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    const page: [*]u8 = @ptrFromInt(direct_map_address + physical_address);
    @memset(page[0..page_size], 0);
    @memcpy(page[0..bytes.len], bytes);

    try arch.mmu.ensurePageTableInAddressSpace(root, virtual_address, protection);
    try arch.mmu.mapPageInAddressSpace(root, virtual_address, physical_address, protection);
}

fn validUserStackPointer(stack_top: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86 => stack_top - 4,
        .x86_64 => stack_top - 8,
        else => @compileError("unsupported architecture"),
    };
}
