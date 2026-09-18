const arch = @import("arch");
const root = @import("root");
const kernel_common = @import("kernel_common");
const abi = @import("abi");

const diagnostics = @import("../../common/interrupts/diagnostics.zig");
const vectors = @import("../../common/interrupts/vectors.zig");
const keyboard = @import("../../common/platform/io/keyboard.zig");
var diagnostic_state: diagnostics.State = .{};

pub const idt = @import("interrupt_descriptor_table.zig");
pub const pic = @import("../../common/interrupts/pic.zig");

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

pub fn interruptHandler(vector: u8, stack_pointer: usize) callconv(.c) void {
    const trap_frame: *TrapFrame = @ptrFromInt(stack_pointer);
    if (comptime @hasDecl(root, "architectureTestObserveException")) {
        if (root.architectureTestObserveException(
            vector,
            trap_frame.error_code,
            trap_frame.instruction_pointer,
            readCr2(),
        )) return;
    }
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
        0x81...0xFF => {},
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
    const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(low32(trap_frame.rax));
    const root_process_handle = kernel_common.process.ROOT_PROCESS_HANDLE;

    switch (syscall_number) {
        .debug_write => {
            const message: [*]const u8 = @ptrFromInt(trap_frame.rbx);
            const length: usize = @intCast(trap_frame.rcx);
            arch.platform.writer().writeAll(message[0..length]) catch {};
            trap_frame.rax = 0;
        },
        .exit => {
            arch.platform.writer().print("User process exited with status {d}.\n", .{trap_frame.rbx}) catch {};
            arch.cpu.unrecoverableHalt();
        },
        .create_address_space => {
            const capability = kernel_common.capability.createAddressSpaceCapability(root_process_handle) catch |err| {
                arch.platform.writer().print("create_address_space failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.capability.INVALID_CAPABILITY;
                return;
            };
            trap_frame.rax = capability;
        },
        .map_memory => {
            const address_space_handle = kernel_common.capability.resolveAddressSpace(root_process_handle, low32(trap_frame.rbx), .{ .manage = true }) catch |err| {
                arch.platform.writer().print("map_memory address-space capability failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.syscall.SYSCALL_FAILURE;
                return;
            };

            kernel_common.process.mapMemory(address_space_handle, low32(trap_frame.rcx), low32(trap_frame.rdx)) catch |err| {
                arch.platform.writer().print("map_memory failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.syscall.SYSCALL_FAILURE;
                return;
            };
            trap_frame.rax = abi.syscall.SYSCALL_SUCCESS;
        },
        .create_memory_object => {
            const capability = kernel_common.capability.createMemoryObjectCapability(root_process_handle, low32(trap_frame.rbx)) catch |err| {
                arch.platform.writer().print("create_memory_object failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.capability.INVALID_CAPABILITY;
                return;
            };
            trap_frame.rax = capability;
        },
        .map_memory_object => {
            const address_space_handle = kernel_common.capability.resolveAddressSpace(root_process_handle, low32(trap_frame.rbx), .{ .manage = true }) catch |err| {
                arch.platform.writer().print("map_memory_object address-space capability failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.syscall.SYSCALL_FAILURE;
                return;
            };

            const memory_object_handle = kernel_common.capability.resolveMemoryObject(root_process_handle, low32(trap_frame.rcx), rightsFromMapFlags(low32(trap_frame.rdi))) catch |err| {
                arch.platform.writer().print("map_memory_object memory-object capability failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.syscall.SYSCALL_FAILURE;
                return;
            };

            kernel_common.process.mapMemoryObject(
                address_space_handle,
                memory_object_handle,
                low32(trap_frame.rdx),
                0,
                low32(trap_frame.rsi),
                low32(trap_frame.rdi),
            ) catch |err| {
                arch.platform.writer().print("map_memory_object failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.syscall.SYSCALL_FAILURE;
                return;
            };
            trap_frame.rax = abi.syscall.SYSCALL_SUCCESS;
        },
        _ => {
            arch.platform.writer().print("Unknown syscall: {d}\n", .{trap_frame.rax}) catch {};
            arch.cpu.unrecoverableHalt();
        },
    }
}

fn low32(value: u64) u32 {
    return @truncate(value);
}

fn rightsFromMapFlags(permission_flags: u32) abi.capability.Rights {
    return .{
        .read = (permission_flags & abi.syscall.MAP_READ) != 0,
        .write = (permission_flags & abi.syscall.MAP_WRITE) != 0,
        .execute = (permission_flags & abi.syscall.MAP_EXECUTE) != 0,
    };
}

fn readPageFaultInfo(trap_frame: *const TrapFrame) arch.FaultInfo {
    const error_code: usize = @intCast(trap_frame.error_code);

    return .{
        .address = readCr2(),
        .present = (error_code & 0x1) != 0,
        .write = (error_code & 0x2) != 0,
        .user = (error_code & 0x4) != 0,
        .instruction_fetch = (error_code & 0x10) != 0,
    };
}

fn readCr2() usize {
    return asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (-> usize),
    );
}

const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    error_code: u64,
    instruction_pointer: u64,
    code_selector: u64,
    flags: u64,
    stack_pointer: u64,
    stack_selector: u64,
};

comptime {
    @import("std").debug.assert(@sizeOf(TrapFrame) == 21 * @sizeOf(u64));
}

const InterruptedFrame = struct {
    error_code: u64,
    instruction_pointer: u64,
    code_selector: u64,
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
