//! Bounded x86-64 saved contexts and per-thread kernel stacks.

const arch = @import("arch");
const std = @import("std");

const gdt = @import("../interrupts/global_descriptor_table.zig");
const frames = @import("../interrupts/trap_frame.zig");
const context_switch = @import("switch.zig");

pub const MAX_CONTEXTS: usize = 32;
pub const KERNEL_STACK_SIZE: usize = 16 * 1024;
pub const KERNEL_STACK_ALIGNMENT: usize = 4096;
pub const KERNEL_CONTEXT_HANDLE: arch.ThreadContextHandle = 0x8000_0001;
const HANDLE_SLOT_BITS: u32 = 5;
const MAX_SLOT_INDEX: u32 = (@as(u32, 1) << HANDLE_SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - HANDLE_SLOT_BITS)) - 1;
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

const Slot = struct {
    generation: u32 = 1,
    saved_stack_pointer: usize = 0,
    address_space_root: arch.AddressSpaceRoot = .{ .value = 0 },
    used: bool = false,
    active: bool = false,
    retired: bool = false,
};

var slots: [MAX_CONTEXTS]Slot = [_]Slot{.{}} ** MAX_CONTEXTS;
var kernel_stacks: [MAX_CONTEXTS][KERNEL_STACK_SIZE]u8 align(KERNEL_STACK_ALIGNMENT) = undefined;
var kernel_continuation_stack: [KERNEL_STACK_SIZE]u8 align(KERNEL_STACK_ALIGNMENT) = undefined;
var kernel_continuation_slot = Slot{};
var current_handle: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;

pub fn create(
    configuration: arch.ThreadContextConfiguration,
) arch.ThreadContextError!arch.ThreadContextHandle {
    if (configuration.address_space_root.value == 0) return error.InvalidAddressSpaceRoot;
    if (configuration.entry_point == 0) return error.InvalidEntryPoint;
    if (configuration.stack_pointer == 0 or configuration.stack_pointer % 16 != 8) {
        return error.InvalidStackPointer;
    }

    const slot_index = findFreeSlot() orelse return error.OutOfThreadContexts;
    const slot = &slots[slot_index];
    slot.used = true;
    slot.active = false;
    slot.address_space_root = configuration.address_space_root;
    initializeStack(slot_index, slot, configuration);
    return makeHandle(slot_index, slot.generation);
}

pub fn createKernelContinuation(
    configuration: arch.KernelContinuationConfiguration,
) arch.ThreadContextError!arch.ThreadContextHandle {
    if (configuration.address_space_root.value == 0) return error.InvalidAddressSpaceRoot;
    if (kernel_continuation_slot.used) return error.KernelContinuationAlreadyExists;

    kernel_continuation_slot = .{
        .saved_stack_pointer = initializeKernelContinuationStack(configuration.entry),
        .address_space_root = configuration.address_space_root,
        .used = true,
    };
    return KERNEL_CONTEXT_HANDLE;
}

pub fn destroy(handle: arch.ThreadContextHandle) arch.ThreadContextError!void {
    if (handle == KERNEL_CONTEXT_HANDLE) {
        if (!kernel_continuation_slot.used) return error.InvalidThreadContextHandle;
        if (kernel_continuation_slot.active or current_handle == handle) {
            return error.ThreadContextInUse;
        }
        kernel_continuation_slot = .{};
        return;
    }
    const slot = try resolveMutableSlot(handle);
    if (slot.active or current_handle == handle) return error.ThreadContextInUse;

    slot.used = false;
    slot.saved_stack_pointer = 0;
    slot.address_space_root = .{ .value = 0 };
    if (slot.generation == MAX_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

pub fn activate(handle: arch.ThreadContextHandle) noreturn {
    const slot = resolveContextMutable(handle) catch @panic("invalid x86-64 context activation");
    if (current_handle != arch.INVALID_THREAD_CONTEXT_HANDLE) {
        @panic("x86-64 thread context already active");
    }
    current_handle = handle;
    slot.active = true;
    arch.mmu.switchAddressSpaceRoot(slot.address_space_root);
    gdt.setPrivilegeStack(contextKernelStackTop(handle));
    activateKernelStack(slot.saved_stack_pointer);
}

pub fn switchContext(
    current: arch.ThreadContextHandle,
    next: arch.ThreadContextHandle,
) arch.ThreadContextError!void {
    const current_slot = try resolveContextMutable(current);
    if (current_handle != current or !current_slot.active) {
        return error.InvalidThreadContextHandle;
    }
    if (current == next) return;
    const next_slot = try resolveContextMutable(next);

    current_slot.active = false;
    next_slot.active = true;
    current_handle = next;
    arch.mmu.switchAddressSpaceRoot(next_slot.address_space_root);
    gdt.setPrivilegeStack(contextKernelStackTop(next));
    context_switch.switchKernelStack(
        &current_slot.saved_stack_pointer,
        next_slot.saved_stack_pointer,
    );
}

pub fn availableCount() usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (!slot.used and !slot.retired) count += 1;
    }
    return count;
}

pub fn getKernelStackBoundsForTest(
    handle: arch.ThreadContextHandle,
) arch.ThreadContextError!struct { start: usize, end: usize } {
    const slot = try resolveSlot(handle);
    _ = slot;
    const slot_index = handleSlotIndex(handle).?;
    return .{
        .start = @intFromPtr(&kernel_stacks[slot_index]),
        .end = kernelStackTop(slot_index),
    };
}

pub fn getInitialStateForTest(
    handle: arch.ThreadContextHandle,
) arch.ThreadContextError!InitialStateForTest {
    const slot = try resolveSlot(handle);
    const frame: *const InitialStackFrame = @ptrFromInt(slot.saved_stack_pointer);
    return .{
        .saved_stack_pointer = slot.saved_stack_pointer,
        .entry_point = frame.user_frame.instruction_pointer,
        .user_stack_pointer = frame.user_frame.stack_pointer,
        .argument = frame.user_frame.rdi,
        .code_selector = frame.user_frame.code_selector,
        .data_selector = frame.user_frame.stack_selector,
        .flags = frame.user_frame.flags,
    };
}

pub fn prepareKernelContinuationForTest(
    handle: arch.ThreadContextHandle,
    entry: *const fn () callconv(.c) noreturn,
) arch.ThreadContextError!void {
    const slot_index = handleSlotIndex(handle) orelse return error.InvalidThreadContextHandle;
    const slot = try resolveMutableSlot(handle);
    const continuation_top = kernelStackTop(slot_index) - @sizeOf(u64);
    const frame_address = continuation_top - @sizeOf(SwitchFrame);
    const frame: *SwitchFrame = @ptrFromInt(frame_address);
    frame.* = .{ .return_address = @intFromPtr(entry) };
    slot.saved_stack_pointer = frame_address;
}

pub fn bindCurrentForTest(handle: arch.ThreadContextHandle) arch.ThreadContextError!void {
    const slot = try resolveMutableSlot(handle);
    if (current_handle != arch.INVALID_THREAD_CONTEXT_HANDLE) return error.ThreadContextInUse;
    current_handle = handle;
    slot.active = true;
    gdt.setPrivilegeStack(kernelStackTop(handleSlotIndex(handle).?));
}

pub fn getCurrentAddressSpaceRootForTest() arch.AddressSpaceRoot {
    const value = asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> usize),
    );
    return .{ .value = value & ~@as(usize, 0xFFF) };
}

pub fn getPrivilegeStackForTest() usize {
    return gdt.getPrivilegeStackForTest();
}

fn initializeStack(
    slot_index: usize,
    slot: *Slot,
    configuration: arch.ThreadContextConfiguration,
) void {
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
    slot.saved_stack_pointer = frame_address;
}

fn activateKernelStack(stack_pointer: usize) noreturn {
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

fn kernelStackTop(slot_index: usize) usize {
    return @intFromPtr(&kernel_stacks[slot_index]) + KERNEL_STACK_SIZE;
}

fn kernelContinuationStackTop() usize {
    return @intFromPtr(&kernel_continuation_stack) + KERNEL_STACK_SIZE;
}

fn contextKernelStackTop(handle: arch.ThreadContextHandle) usize {
    if (handle == KERNEL_CONTEXT_HANDLE) return kernelContinuationStackTop();
    return kernelStackTop(handleSlotIndex(handle).?);
}

fn initializeKernelContinuationStack(entry: *const fn () callconv(.c) noreturn) usize {
    const continuation_top = kernelContinuationStackTop() - @sizeOf(u64);
    const frame_address = continuation_top - @sizeOf(SwitchFrame);
    const frame: *SwitchFrame = @ptrFromInt(frame_address);
    frame.* = .{ .return_address = @intFromPtr(entry) };
    return frame_address;
}

fn resolveContextMutable(handle: arch.ThreadContextHandle) arch.ThreadContextError!*Slot {
    if (handle == KERNEL_CONTEXT_HANDLE) {
        if (!kernel_continuation_slot.used) return error.InvalidThreadContextHandle;
        return &kernel_continuation_slot;
    }
    return resolveMutableSlot(handle);
}

fn resolveSlot(handle: arch.ThreadContextHandle) arch.ThreadContextError!*const Slot {
    const slot_index = handleSlotIndex(handle) orelse return error.InvalidThreadContextHandle;
    const generation = handle >> HANDLE_SLOT_BITS;
    const slot = &slots[slot_index];
    if (!slot.used or slot.generation != generation) return error.InvalidThreadContextHandle;
    return slot;
}

fn resolveMutableSlot(handle: arch.ThreadContextHandle) arch.ThreadContextError!*Slot {
    return @constCast(try resolveSlot(handle));
}

fn findFreeSlot() ?usize {
    for (slots, 0..) |slot, index| {
        if (!slot.used and !slot.retired) return index;
    }
    return null;
}

fn makeHandle(slot_index: usize, generation: u32) arch.ThreadContextHandle {
    return (generation << HANDLE_SLOT_BITS) | @as(u32, @intCast(slot_index));
}

fn handleSlotIndex(handle: arch.ThreadContextHandle) ?usize {
    if (handle == arch.INVALID_THREAD_CONTEXT_HANDLE) return null;
    const generation = handle >> HANDLE_SLOT_BITS;
    if (generation == 0) return null;
    const slot_index: usize = @intCast(handle & MAX_SLOT_INDEX);
    if (slot_index >= slots.len) return null;
    return slot_index;
}

comptime {
    std.debug.assert(MAX_CONTEXTS == MAX_SLOT_INDEX + 1);
    std.debug.assert(@sizeOf(SwitchFrame) == 7 * @sizeOf(u64));
    std.debug.assert(@offsetOf(InitialStackFrame, "user_frame") == @sizeOf(SwitchFrame));
}
