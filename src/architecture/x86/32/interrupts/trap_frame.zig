//! x86-32 software-saved interrupt and privilege-transition frames.

const std = @import("std");

pub const TrapFrame = extern struct {
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

pub const UserTrapFrame = extern struct {
    trap: TrapFrame,
    stack_pointer: u32,
    stack_selector: u32,
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) == 16 * @sizeOf(u32));
    std.debug.assert(@sizeOf(UserTrapFrame) == 18 * @sizeOf(u32));
    std.debug.assert(@offsetOf(TrapFrame, "error_code") == 12 * @sizeOf(u32));
    std.debug.assert(@offsetOf(UserTrapFrame, "stack_pointer") == @sizeOf(TrapFrame));
}
