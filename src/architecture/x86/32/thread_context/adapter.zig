//! x86-32 frame, stack, and switch mechanisms for shared context policy.

const arch = @import("arch");
const std = @import("std");

const gdt = @import("../interrupts/global_descriptor_table.zig");
const frames = @import("../interrupts/trap_frame.zig");
const context_switch = @import("switch.zig");

pub const TrapFrame = frames.TrapFrame;
pub const StackBounds = struct { start: usize, end: usize };
pub const KERNEL_STACK_SIZE: usize = 16 * 1024;
pub const KERNEL_STACK_ALIGNMENT: usize = 4096;
pub const KERNEL_STACK_COUNT: usize = 32;
const INITIAL_FLAGS: u32 = 0x202;

const SwitchFrame = extern struct {
    ebp: u32 = 0,
    edi: u32 = 0,
    esi: u32 = 0,
    ebx: u32 = 0,
    return_address: u32,
};

const InitialStackFrame = extern struct {
    switch_frame: SwitchFrame,
    user_frame: frames.UserTrapFrame,
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
    if (configuration.entry_point == 0 or configuration.entry_point > std.math.maxInt(u32)) {
        return error.InvalidEntryPoint;
    }
    if (configuration.stack_pointer == 0 or
        configuration.stack_pointer > std.math.maxInt(u32) or
        configuration.stack_pointer % 16 != 12)
    {
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
            .trap = .{
                .gs = gdt.USER_DATA_SELECTOR,
                .fs = gdt.USER_DATA_SELECTOR,
                .es = gdt.USER_DATA_SELECTOR,
                .ds = gdt.USER_DATA_SELECTOR,
                .edi = 0,
                .esi = 0,
                .ebp = 0,
                .original_stack_pointer = 0,
                .ebx = 0,
                .edx = 0,
                .ecx = 0,
                .eax = 0,
                .error_code = 0,
                .instruction_pointer = @intCast(configuration.entry_point),
                .code_selector = gdt.USER_CODE_SELECTOR,
                .flags = INITIAL_FLAGS,
            },
            .stack_pointer = @intCast(configuration.stack_pointer),
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
        \\mov %[stack_pointer], %esp
        \\pop %ebp
        \\pop %edi
        \\pop %esi
        \\pop %ebx
        \\ret
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
    trap_frame.eax = result.status;
    trap_frame.ebx = @truncate(result.words[0]);
    trap_frame.ecx = @truncate(result.words[1]);
    trap_frame.edx = @truncate(result.words[2]);
    if (result.capability) |installed| trap_frame.esi = @truncate(installed);
}

pub fn readSyscallResult(trap_frame: *const TrapFrame) arch.SyscallResultRegisters {
    return .{
        .status = trap_frame.eax,
        .words = .{ trap_frame.ebx, trap_frame.ecx, trap_frame.edx },
        .capability = trap_frame.esi,
    };
}

pub fn isValidUserInstructionPointer(instruction_pointer: u64) bool {
    return instruction_pointer != 0 and instruction_pointer <= std.math.maxInt(u32);
}

pub fn hasInstructionPointer(trap_frame: *const TrapFrame, instruction_pointer: u64) bool {
    return trap_frame.instruction_pointer == @as(u32, @intCast(instruction_pointer));
}

pub fn setInstructionPointer(trap_frame: *TrapFrame, instruction_pointer: u64) void {
    trap_frame.instruction_pointer = @intCast(instruction_pointer);
}

pub fn readInitialState(saved_stack_pointer: usize) InitialStateForTest {
    const frame: *const InitialStackFrame = @ptrFromInt(saved_stack_pointer);
    return .{
        .saved_stack_pointer = saved_stack_pointer,
        .entry_point = frame.user_frame.trap.instruction_pointer,
        .user_stack_pointer = frame.user_frame.stack_pointer,
        .argument = 0,
        .code_selector = frame.user_frame.trap.code_selector,
        .data_selector = frame.user_frame.stack_selector,
        .flags = frame.user_frame.trap.flags,
    };
}

pub fn initialTrapFrameAddress(saved_stack_pointer: usize) usize {
    const frame: *const InitialStackFrame = @ptrFromInt(saved_stack_pointer);
    return @intFromPtr(&frame.user_frame.trap);
}

pub fn getCurrentAddressSpaceRootForTest() arch.AddressSpaceRoot {
    const value = asm volatile ("mov %cr3, %[value]"
        : [value] "=r" (-> usize),
    );
    return .{ .value = value };
}

pub const getPrivilegeStackForTest = gdt.getPrivilegeStackForTest;

pub fn panicInvalidActivation() noreturn {
    @panic("invalid x86-32 context activation");
}

pub fn panicContextAlreadyActive() noreturn {
    @panic("x86-32 thread context already active");
}

fn initializeContinuationStack(
    stack_top: usize,
    entry: *const fn () callconv(.c) noreturn,
) usize {
    const continuation_top = stack_top - @sizeOf(u32);
    const frame_address = continuation_top - @sizeOf(SwitchFrame);
    const frame: *SwitchFrame = @ptrFromInt(frame_address);
    frame.* = .{ .return_address = @intFromPtr(entry) };
    return frame_address;
}

comptime {
    std.debug.assert(@sizeOf(SwitchFrame) == 5 * @sizeOf(u32));
    std.debug.assert(@offsetOf(InitialStackFrame, "user_frame") == @sizeOf(SwitchFrame));
}
