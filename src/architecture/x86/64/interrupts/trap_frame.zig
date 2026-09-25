//! x86-64 software-saved interrupt and privilege-transition frame.

const std = @import("std");

pub const TrapFrame = extern struct {
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
    std.debug.assert(@sizeOf(TrapFrame) == 21 * @sizeOf(u64));
    std.debug.assert(@offsetOf(TrapFrame, "error_code") == 15 * @sizeOf(u64));
    std.debug.assert(@offsetOf(TrapFrame, "stack_pointer") == 19 * @sizeOf(u64));
}
