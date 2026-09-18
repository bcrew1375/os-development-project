const arch = @import("arch");
const kernel_common = @import("kernel_common");
const abi = @import("abi");

const diagnostics = @import("../../common/interrupts/diagnostics.zig");
const vectors = @import("../../common/interrupts/vectors.zig");
pub const idt = @import("interrupt_descriptor_table.zig");
pub const pic = @import("../../common/interrupts/pic.zig");
const keyboard = @import("../../common/platform/io/keyboard.zig");
var diagnostic_state: diagnostics.State = .{};

pub fn enableInterrupts() void {
    asm volatile (
        \\sti
    );
}

pub fn disableInterrupts() void {
    asm volatile (
        \\cli
    );
}

pub fn acknowledgeInterrupt(vector: usize) void {
    pic.sendEndOfInterrupt(vector);
}

pub fn interruptHandler(vector: usize, stack_pointer: usize) callconv(.c) void {
    const trap_frame: *TrapFrame = @ptrFromInt(stack_pointer);
    const diagnostic = diagnostic_state.recordInterrupt(vector);
    if (diagnostic.print) {
        arch.platform.writer().print("Interrupt 0x{x}: ", .{vector}) catch {};
    }

    switch (vector) {
        vectors.divide_by_zero => {
            arch.platform.writer().writeAll("Divide by zero.\n") catch {};
        },
        vectors.debug_exception => {
            arch.platform.writer().writeAll("Debug exception.\n") catch {};
        },
        0x02...0x05 => {},
        vectors.invalid_opcode => {
            arch.platform.writer().writeAll("Invalid opcode.\n") catch {};
        },
        0x07 => {},
        vectors.double_fault => {
            arch.platform.writer().writeAll("Double fault.\n") catch {};
        },
        0x09 => {},
        vectors.invalid_tss => {
            arch.platform.writer().writeAll("Invalid TSS.\n") catch {};
        },
        0x0B => {},
        vectors.stack_segment_fault => {
            arch.platform.writer().writeAll("Stack segment fault.\n") catch {};
        },
        vectors.general_protection_fault => {
            const interrupted_frame = readInterruptedFrame(trap_frame);
            arch.platform.writer().writeAll("General protection fault.\n") catch {};
            arch.platform.writer().print(" EIP: 0x{x}, CS: 0x{x}, error: 0x{x}\n", .{ interrupted_frame.instruction_pointer, interrupted_frame.code_selector, interrupted_frame.error_code }) catch {};
            if (interrupted_frame.user_mode) {
                arch.platform.writer().writeAll(" Fault originated in user mode; first user process reached CPL 3.\n") catch {};
                arch.cpu.unrecoverableHalt();
            }
        },
        vectors.page_fault => handlePageFault(trap_frame, diagnostic),
        0x0F => {},
        0x10 => {},
        vectors.alignment_check => {
            arch.platform.writer().writeAll("Alignment check.\n") catch {};
        },
        0x12...0x1F => {},
        vectors.timer => {
            if (diagnostic.print) {
                arch.platform.writer().print("Timer ({d} ticks).\n", .{diagnostic.count}) catch {};
            }
        },
        vectors.keyboard => {
            if (diagnostic.print) {
                arch.platform.writer().writeAll("Keyboard pressed.\n") catch {};
            }
            keyboard.clearKeyboard();
        },
        0x22...0x7F => {},
        vectors.syscall => handleSyscall(trap_frame),
        0x81...0xFFFFFFFF => {},
    }

    if (diagnostic.print) {
        arch.platform.writer().print(" --- Stack Index: {x}\n", .{stack_pointer}) catch {};
    }

    acknowledgeInterrupt(vector);
}

fn handlePageFault(trap_frame: *const TrapFrame, diagnostic: diagnostics.Decision) void {
    kernel_common.vmm.faultHandler(readPageFaultInfo(trap_frame));
    if (diagnostic.print) {
        arch.platform.writer().writeAll("Page fault.\n") catch {};
    }
}

fn handleSyscall(trap_frame: *TrapFrame) void {
    const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(trap_frame.eax);
    const root_process_handle = kernel_common.process.ROOT_PROCESS_HANDLE;

    switch (syscall_number) {
        .debug_write => {
            const message: [*]const u8 = @ptrFromInt(trap_frame.ebx);
            const length: usize = @intCast(trap_frame.ecx);
            arch.platform.writer().writeAll(message[0..length]) catch {};
            trap_frame.eax = 0;
        },
        .exit => {
            arch.platform.writer().print("User process exited with status {d}.\n", .{trap_frame.ebx}) catch {};
            arch.cpu.unrecoverableHalt();
        },
        .create_address_space => {
            const capability = kernel_common.capability.createAddressSpaceCapability(root_process_handle) catch |err| {
                arch.platform.writer().print("create_address_space failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.capability.INVALID_CAPABILITY;
                return;
            };
            trap_frame.eax = capability;
        },
        .map_memory => {
            const address_space_handle = kernel_common.capability.resolveAddressSpace(root_process_handle, trap_frame.ebx, .{ .manage = true }) catch |err| {
                arch.platform.writer().print("map_memory address-space capability failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.syscall.SYSCALL_FAILURE;
                return;
            };

            kernel_common.process.mapMemory(address_space_handle, trap_frame.ecx, trap_frame.edx) catch |err| {
                arch.platform.writer().print("map_memory failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.syscall.SYSCALL_FAILURE;
                return;
            };
            trap_frame.eax = abi.syscall.SYSCALL_SUCCESS;
        },
        .create_memory_object => {
            const capability = kernel_common.capability.createMemoryObjectCapability(root_process_handle, trap_frame.ebx) catch |err| {
                arch.platform.writer().print("create_memory_object failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.capability.INVALID_CAPABILITY;
                return;
            };
            trap_frame.eax = capability;
        },
        .map_memory_object => {
            const address_space_handle = kernel_common.capability.resolveAddressSpace(root_process_handle, trap_frame.ebx, .{ .manage = true }) catch |err| {
                arch.platform.writer().print("map_memory_object address-space capability failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.syscall.SYSCALL_FAILURE;
                return;
            };

            const memory_object_handle = kernel_common.capability.resolveMemoryObject(root_process_handle, trap_frame.ecx, rightsFromMapFlags(trap_frame.edi)) catch |err| {
                arch.platform.writer().print("map_memory_object memory-object capability failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.syscall.SYSCALL_FAILURE;
                return;
            };

            kernel_common.process.mapMemoryObject(
                address_space_handle,
                memory_object_handle,
                trap_frame.edx,
                0,
                trap_frame.esi,
                trap_frame.edi,
            ) catch |err| {
                arch.platform.writer().print("map_memory_object failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.eax = abi.syscall.SYSCALL_FAILURE;
                return;
            };
            trap_frame.eax = abi.syscall.SYSCALL_SUCCESS;
        },
        _ => {
            arch.platform.writer().print("Unknown syscall: {d}\n", .{trap_frame.eax}) catch {};
            arch.cpu.unrecoverableHalt();
        },
    }
}

fn rightsFromMapFlags(permission_flags: u32) abi.capability.Rights {
    return .{
        .read = (permission_flags & abi.syscall.MAP_READ) != 0,
        .write = (permission_flags & abi.syscall.MAP_WRITE) != 0,
        .execute = (permission_flags & abi.syscall.MAP_EXECUTE) != 0,
    };
}

fn readPageFaultInfo(trap_frame: *const TrapFrame) arch.FaultInfo {
    const virtual_address = asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (-> u32),
    );
    const error_code: usize = @intCast(trap_frame.error_code);

    return .{
        .address = virtual_address,
        .present = (error_code & 0x1) != 0,
        .write = (error_code & 0x2) != 0,
        .user = (error_code & 0x4) != 0,
        .instruction_fetch = (error_code & 0x10) != 0,
    };
}

const TrapFrame = extern struct {
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    original_stack_pointer: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    error_code: u32,
    instruction_pointer: u32,
    code_selector: u32,
    flags: u32,
};

comptime {
    @import("std").debug.assert(@sizeOf(TrapFrame) == 16 * @sizeOf(u32));
}

const InterruptedFrame = struct {
    error_code: u32,
    instruction_pointer: u32,
    code_selector: u32,
    user_mode: bool,
};

fn readInterruptedFrame(trap_frame: *const TrapFrame) InterruptedFrame {
    return .{
        .error_code = trap_frame.error_code,
        .instruction_pointer = trap_frame.instruction_pointer,
        .code_selector = trap_frame.code_selector,
        .user_mode = (trap_frame.code_selector & 0x3) == 0x3,
    };
}
