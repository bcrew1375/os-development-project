//! Initial user stack mapping and target-ABI call-frame construction.

const arch = @import("arch");
const builtin = @import("builtin");
const kernel_common = @import("kernel_common");
const std = @import("std");

const layout = @import("layout.zig");
const user_memory = @import("user_memory.zig");

const RootProcessLayout = layout.RootProcessLayout;
const vmm = kernel_common.memory_management.virtual_memory;

pub fn mapInitialUserStack(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
) !void {
    try vmm.mapBootstrapContiguousInAddressSpace(
        page_table_root,
        address_space,
        RootProcessLayout.initial_stack_start,
        RootProcessLayout.initial_stack_top,
        user_memory.readWriteUserPagePermissions,
    );
}

/// Constructs the target C ABI's function-entry stack shape. x86-32 carries
/// the boot-info pointer on the stack; x86-64 carries it in RDI.
pub fn writeInitialCallFrame(
    page_table_root: arch.AddressSpaceRoot,
    stack_top: u64,
    boot_info_address: u64,
) !usize {
    var stack_pointer = @as(usize, @intCast(stack_top));

    switch (builtin.cpu.arch) {
        .x86 => {
            stack_pointer -= 3 * @sizeOf(u32);
            stack_pointer -= @sizeOf(u32);
            const boot_info_argument: u32 = @intCast(boot_info_address);
            try user_memory.copyIntoUserSpace(
                page_table_root,
                stack_pointer,
                std.mem.asBytes(&boot_info_argument),
            );

            stack_pointer -= @sizeOf(u32);
            const fake_return_address: u32 = 0;
            try user_memory.copyIntoUserSpace(
                page_table_root,
                stack_pointer,
                std.mem.asBytes(&fake_return_address),
            );
        },
        .x86_64 => {
            stack_pointer -= @sizeOf(u64);
            const fake_return_address: u64 = 0;
            try user_memory.copyIntoUserSpace(
                page_table_root,
                stack_pointer,
                std.mem.asBytes(&fake_return_address),
            );
        },
        else => @compileError("unsupported root-process entry ABI"),
    }

    return stack_pointer;
}
