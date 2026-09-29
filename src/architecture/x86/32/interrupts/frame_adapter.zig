//! x86-32 interrupt trap-frame access and register ABI conversion.

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
        : [out] "=r" (-> u32),
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
    const error_code: usize = trap_frame.error_code;
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
        .number = trap_frame.eax,
        .arguments = .{
            trap_frame.ebx,
            trap_frame.ecx,
            trap_frame.edx,
            trap_frame.esi,
            trap_frame.edi,
        },
    };
}

pub fn writeSyscallResult(trap_frame: *TrapFrame, result: arch.SyscallResultRegisters) void {
    trap_frame.eax = result.status;
    trap_frame.ebx = @truncate(result.words[0]);
    trap_frame.ecx = @truncate(result.words[1]);
    trap_frame.edx = @truncate(result.words[2]);
    if (result.capability) |installed| trap_frame.esi = @truncate(installed);
}

comptime {
    policy.validateFrameAdapter(@This());
}
