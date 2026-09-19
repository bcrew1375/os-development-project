const arch = @import("arch");
const builtin = @import("builtin");
const framework = @import("../framework.zig");

const fault_virtual_address: usize = 0x0040_0000;
const user_stack_virtual_address: usize = fault_virtual_address + 0x2000;

pub fn unmappedRead() !void {
    try switchToFreshAddressSpace();

    const target: *const volatile u8 = @ptrFromInt(fault_virtual_address);
    _ = target.*;
    return framework.TestError.ExpectationFailed;
}

pub fn unmappedWrite() !void {
    try switchToFreshAddressSpace();

    const target: *volatile u8 = @ptrFromInt(fault_virtual_address);
    target.* = 0xA5;
    return framework.TestError.ExpectationFailed;
}

pub fn writeProtectionViolation() !void {
    const root = try createPreparedAddressSpace();
    const physical_address = try allocatePage();
    try arch.mmu.mapPageInAddressSpace(root, fault_virtual_address, physical_address, .{});
    arch.mmu.switchAddressSpaceRoot(root);

    const target: *volatile u8 = @ptrFromInt(fault_virtual_address);
    target.* = 0xA5;
    return framework.TestError.ExpectationFailed;
}

pub fn userSupervisorInstructionFetch() !void {
    const root = try prepareUserTransition(.{ .execute = true });
    arch.mmu.switchAddressSpaceRoot(root);
    arch.cpu.enterUserMode(
        fault_virtual_address,
        user_stack_virtual_address + arch.mmu.getPageSize(),
        0,
    );
}

pub fn nonExecutableInstructionFetch() !void {
    if (comptime builtin.cpu.arch != .x86_64) {
        @compileError("non-executable page faults require x86-64 paging");
    }

    const root = try createPreparedAddressSpace();
    const physical_address = try allocatePage();
    writePageBytes(physical_address, &.{0xC3});
    try arch.mmu.mapPageInAddressSpace(root, fault_virtual_address, physical_address, .{
        .execute = false,
    });
    arch.mmu.switchAddressSpaceRoot(root);

    const entry_point: *const fn () callconv(.c) void = @ptrFromInt(fault_virtual_address);
    entry_point();
    return framework.TestError.ExpectationFailed;
}

pub fn invalidOpcode() !void {
    finishBoot();
    asm volatile ("ud2");
    return framework.TestError.ExpectationFailed;
}

pub fn generalProtectionFromUserInterrupt() !void {
    const root = try prepareUserTransition(.{ .user = true, .execute = true });
    arch.mmu.switchAddressSpaceRoot(root);
    arch.cpu.enterUserMode(
        fault_virtual_address,
        user_stack_virtual_address + arch.mmu.getPageSize(),
        0,
    );
}

fn switchToFreshAddressSpace() !void {
    const root = try arch.mmu.createAddressSpaceRoot();
    finishBoot();
    arch.mmu.switchAddressSpaceRoot(root);
}

fn createPreparedAddressSpace() !arch.AddressSpaceRoot {
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_table_physical_address = try allocatePage();
    try arch.mmu.mapTableInAddressSpace(
        root,
        fault_virtual_address,
        page_table_physical_address,
        .{},
    );
    finishBoot();
    return root;
}

fn prepareUserTransition(code_protection: arch.PageProtection) !arch.AddressSpaceRoot {
    const root = try arch.mmu.createAddressSpaceRoot();
    const page_table_physical_address = try allocatePage();
    try arch.mmu.mapTableInAddressSpace(
        root,
        fault_virtual_address,
        page_table_physical_address,
        .{ .user = true },
    );

    const code_physical_address = try allocatePage();
    writePageBytes(code_physical_address, &.{ 0xCD, 0x20, 0xF4 });
    try arch.mmu.mapPageInAddressSpace(
        root,
        fault_virtual_address,
        code_physical_address,
        code_protection,
    );

    const stack_physical_address = try allocatePage();
    try arch.mmu.mapPageInAddressSpace(
        root,
        user_stack_virtual_address,
        stack_physical_address,
        .{ .write = true, .user = true },
    );

    finishBoot();
    return root;
}

fn allocatePage() !usize {
    const page_size = arch.mmu.getPageSize();
    return @intFromPtr(try arch.early_allocator.allocate(
        page_size,
        page_size,
        .PERSISTENT,
    ));
}

fn writePageBytes(physical_address: usize, bytes: []const u8) void {
    const direct_map_address: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    const destination: [*]u8 = @ptrFromInt(direct_map_address + physical_address);
    @memcpy(destination[0..bytes.len], bytes);
}

fn finishBoot() void {
    @call(.never_inline, arch.boot.finishBoot, .{});
}
