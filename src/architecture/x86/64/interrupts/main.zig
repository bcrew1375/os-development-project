const arch = @import("arch");
const root = @import("root");
const kernel_common = @import("kernel_common");
const abi = @import("abi");

const diagnostics = @import("../../common/interrupts/diagnostics.zig");
const vectors = @import("../../common/interrupts/vectors.zig");
const keyboard = @import("../../common/platform/io/keyboard.zig");
const time = @import("../../common/platform/time/main.zig");
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
            time.recordInterrupt();
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
    const result = kernel_common.syscall.dispatchFromCurrentContext(
        .{
            .number = @truncate(trap_frame.rax),
            .arguments = .{
                trap_frame.rbx,
                trap_frame.rcx,
                trap_frame.rdx,
                trap_frame.rsi,
                trap_frame.rdi,
            },
        },
    );
    handleSyscallResult(trap_frame, result);
}

fn handleSyscallResult(trap_frame: *TrapFrame, result: kernel_common.syscall.Result) void {
    switch (result) {
        .returned => |value| trap_frame.rax = value,
        .debug_write => |write| {
            var message: [kernel_common.user_memory.MAX_COPY_BYTES]u8 = undefined;
            kernel_common.user_memory.copyFromUser(&message, write.address, write.length) catch |err| {
                arch.platform.writer().print("debug_write failed: {s}\n", .{@errorName(err)}) catch {};
                trap_frame.rax = abi.syscall.SYSCALL_FAILURE;
                return;
            };
            arch.platform.writer().writeAll(message[0..@intCast(write.length)]) catch {};
            trap_frame.rax = abi.syscall.SYSCALL_SUCCESS;
        },
        .exit => |exit| {
            arch.platform.writer().print(abi.system_smoke.EXIT_FORMAT, .{exit.status}) catch {};
            arch.platform.writer().print("User process exited with status {d}.\n", .{exit.status}) catch {};
            arch.cpu.unrecoverableHalt();
        },
        .unsupported => |unsupported| {
            arch.platform.writer().print("Unknown syscall: {d}\n", .{unsupported.number}) catch {};
            arch.cpu.unrecoverableHalt();
        },
        .failure => |failure_result| {
            arch.platform.writer().print("{s} failed: {s}\n", .{
                @tagName(failure_result.operation),
                @errorName(failure_result.err),
            }) catch {};
            trap_frame.rax = failure_result.return_value;
        },
    }
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
