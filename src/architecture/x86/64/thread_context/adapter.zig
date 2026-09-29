//! x86-64 frame, stack, and switch mechanisms for shared context policy.

const arch = @import("arch");
const std = @import("std");

const gdt = @import("../interrupts/global_descriptor_table.zig");
const frames = @import("../interrupts/trap_frame.zig");
const context_switch = @import("switch.zig");

pub const TrapFrame = frames.TrapFrame;
pub const StackBounds = struct { start: usize, end: usize };
pub const KERNEL_STACK_SIZE: usize = 32 * 1024;
pub const KERNEL_STACK_ALIGNMENT: usize = 4096;
pub const KERNEL_STACK_COUNT: usize = 32;
const INITIAL_FLAGS: u64 = 0x202;

const SwitchFrame = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbp: u64 = 0,
    rbx: u64 = 0,
    return_address: u64,
};

const InitialStackFrame = extern struct {
    switch_frame: SwitchFrame,
    user_frame: frames.TrapFrame,
};

pub const InitialStateForTest = struct {
    saved_stack_pointer: usize,
    entry_point: usize,
    user_stack_pointer: usize,
    argument: usize,
    code_selector: usize,
    data_selector: usize,
    flags: usize,
};

var kernel_stacks: [KERNEL_STACK_COUNT][KERNEL_STACK_SIZE]u8 align(KERNEL_STACK_ALIGNMENT) =
    undefined;
var kernel_continuation_stack: [KERNEL_STACK_SIZE]u8 align(KERNEL_STACK_ALIGNMENT) = undefined;

pub fn validateConfiguration(
    configuration: arch.ThreadContextConfiguration,
) arch.ThreadContextError!void {
    if (configuration.entry_point == 0) return error.InvalidEntryPoint;
    if (configuration.stack_pointer == 0 or configuration.stack_pointer % 16 != 8) {
        return error.InvalidStackPointer;
    }
}

pub fn initializeStack(slot_index: usize, configuration: arch.ThreadContextConfiguration) usize {
    const frame_address = kernelStackTop(slot_index) - @sizeOf(InitialStackFrame);
    const frame: *InitialStackFrame = @ptrFromInt(frame_address);
    frame.* = .{
        .switch_frame = .{
            .return_address = @intFromPtr(&context_switch.restoreInitialContext),
        },
        .user_frame = .{
            .r15 = 0,
            .r14 = 0,
            .r13 = 0,
            .r12 = 0,
            .r11 = 0,
            .r10 = 0,
            .r9 = 0,
            .r8 = 0,
            .rdi = configuration.argument,
            .rsi = 0,
            .rbp = 0,
            .rbx = 0,
            .rdx = 0,
            .rcx = 0,
            .rax = 0,
            .error_code = 0,
            .instruction_pointer = configuration.entry_point,
            .code_selector = gdt.USER_CODE_SELECTOR,
            .flags = INITIAL_FLAGS,
            .stack_pointer = configuration.stack_pointer,
            .stack_selector = gdt.USER_DATA_SELECTOR,
        },
    };
    return frame_address;
}

pub fn initializeKernelContinuationStack(entry: *const fn () callconv(.c) noreturn) usize {
    return initializeContinuationStack(kernelContinuationStackTop(), entry);
}

pub fn initializeThreadContinuationStack(
    slot_index: usize,
    entry: *const fn () callconv(.c) noreturn,
) usize {
    return initializeContinuationStack(kernelStackTop(slot_index), entry);
}

pub fn activateKernelStack(stack_pointer: usize) noreturn {
    asm volatile (
        \\movq %[stack_pointer], %%rsp
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbp
        \\popq %%rbx
        \\retq
        :
        : [stack_pointer] "r" (stack_pointer),
        : .{ .memory = true });
    unreachable;
}

pub const switchKernelStack = context_switch.switchKernelStack;
pub const setPrivilegeStack = gdt.setPrivilegeStack;

pub fn kernelStackTop(slot_index: usize) usize {
    return @intFromPtr(&kernel_stacks[slot_index]) + KERNEL_STACK_SIZE;
}

pub fn kernelContinuationStackTop() usize {
    return @intFromPtr(&kernel_continuation_stack) + KERNEL_STACK_SIZE;
}

pub fn kernelStackBounds(slot_index: usize) StackBounds {
    return .{
        .start = @intFromPtr(&kernel_stacks[slot_index]),
        .end = kernelStackTop(slot_index),
    };
}

pub fn writeSyscallResult(trap_frame: *TrapFrame, result: arch.SyscallResultRegisters) void {
    trap_frame.rax = result.status;
    trap_frame.rbx = result.words[0];
    trap_frame.rcx = result.words[1];
    trap_frame.rdx = result.words[2];
    if (result.capability) |installed| trap_frame.rsi = installed;
}

pub fn readSyscallResult(trap_frame: *const TrapFrame) arch.SyscallResultRegisters {
    return .{
        .status = @truncate(trap_frame.rax),
        .words = .{ trap_frame.rbx, trap_frame.rcx, trap_frame.rdx },
        .capability = trap_frame.rsi,
    };
}

pub fn isValidUserInstructionPointer(instruction_pointer: u64) bool {
    if (instruction_pointer == 0) return false;
    const upper = instruction_pointer >> 47;
    if (upper != 0 and upper != 0x1ffff) return false;
    return instruction_pointer < arch.mmu.getKernelVirtualAddressStart();
}

pub fn hasInstructionPointer(trap_frame: *const TrapFrame, instruction_pointer: u64) bool {
    return trap_frame.instruction_pointer == instruction_pointer;
}

pub fn setInstructionPointer(trap_frame: *TrapFrame, instruction_pointer: u64) void {
    trap_frame.instruction_pointer = instruction_pointer;
}

pub fn readInitialState(saved_stack_pointer: usize) InitialStateForTest {
    const frame: *const InitialStackFrame = @ptrFromInt(saved_stack_pointer);
    return .{
        .saved_stack_pointer = saved_stack_pointer,
        .entry_point = frame.user_frame.instruction_pointer,
        .user_stack_pointer = frame.user_frame.stack_pointer,
        .argument = frame.user_frame.rdi,
        .code_selector = frame.user_frame.code_selector,
        .data_selector = frame.user_frame.stack_selector,
        .flags = frame.user_frame.flags,
    };
}

pub fn initialTrapFrameAddress(saved_stack_pointer: usize) usize {
    const frame: *const InitialStackFrame = @ptrFromInt(saved_stack_pointer);
    return @intFromPtr(&frame.user_frame);
}

pub fn getCurrentAddressSpaceRootForTest() arch.AddressSpaceRoot {
    const value = asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> usize),
    );
    return .{ .value = value & ~@as(usize, 0xFFF) };
}

pub const getPrivilegeStackForTest = gdt.getPrivilegeStackForTest;

pub fn panicInvalidActivation() noreturn {
    @panic("invalid x86-64 context activation");
}

pub fn panicContextAlreadyActive() noreturn {
    @panic("x86-64 thread context already active");
}

fn initializeContinuationStack(
    stack_top: usize,
    entry: *const fn () callconv(.c) noreturn,
) usize {
    const continuation_top = stack_top - @sizeOf(u64);
    const frame_address = continuation_top - @sizeOf(SwitchFrame);
    const frame: *SwitchFrame = @ptrFromInt(frame_address);
    frame.* = .{ .return_address = @intFromPtr(entry) };
    return frame_address;
}

comptime {
    std.debug.assert(@sizeOf(SwitchFrame) == 7 * @sizeOf(u64));
    std.debug.assert(@offsetOf(InitialStackFrame, "user_frame") == @sizeOf(SwitchFrame));
}
