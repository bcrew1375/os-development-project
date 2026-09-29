//! x86-64 interrupt trap-frame access and register ABI conversion.

const arch = @import("arch");
const kernel_common = @import("kernel_common");
const policy = @import("../../common/interrupts/policy.zig");

pub const TrapFrame = @import("trap_frame.zig").TrapFrame;

pub fn fromStackPointer(stack_pointer: usize) *TrapFrame {
    return @ptrFromInt(stack_pointer);
}

pub fn errorCode(trap_frame: *const TrapFrame) usize {
    return trap_frame.error_code;
}

pub fn instructionPointer(trap_frame: *const TrapFrame) usize {
    return trap_frame.instruction_pointer;
}

pub fn readCr2() usize {
    return asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (-> usize),
    );
}

pub fn isUserMode(trap_frame: *const TrapFrame) bool {
    return (trap_frame.code_selector & 0x3) == 0x3;
}

pub fn readInterruptedFrame(trap_frame: *const TrapFrame) policy.InterruptedFrame {
    return .{
        .error_code = trap_frame.error_code,
        .instruction_pointer = trap_frame.instruction_pointer,
        .code_selector = trap_frame.code_selector,
        .user_mode = isUserMode(trap_frame),
    };
}

pub fn readPageFaultInfo(trap_frame: *const TrapFrame) arch.FaultInfo {
    const error_code: usize = @intCast(trap_frame.error_code);
    return .{
        .address = readCr2(),
        .present = (error_code & 0x1) != 0,
        .write = (error_code & 0x2) != 0,
        .user = (error_code & 0x4) != 0,
        .instruction_fetch = (error_code & 0x10) != 0,
    };
}

pub fn readSyscallRequest(trap_frame: *const TrapFrame) kernel_common.syscall.Request {
    return .{
        .number = @truncate(trap_frame.rax),
        .arguments = .{
            trap_frame.rbx,
            trap_frame.rcx,
            trap_frame.rdx,
            trap_frame.rsi,
            trap_frame.rdi,
        },
    };
}

pub fn writeSyscallResult(trap_frame: *TrapFrame, result: arch.SyscallResultRegisters) void {
    trap_frame.rax = result.status;
    trap_frame.rbx = result.words[0];
    trap_frame.rcx = result.words[1];
    trap_frame.rdx = result.words[2];
    if (result.capability) |installed| trap_frame.rsi = installed;
}

comptime {
    policy.validateFrameAdapter(@This());
}
