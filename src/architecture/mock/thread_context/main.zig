//! Deterministic bounded thread-context service for host tests.

const arch = @import("../../architecture.zig");

pub const MAX_CONTEXTS: usize = 32;
pub const KERNEL_CONTEXT_HANDLE: arch.ThreadContextHandle = 0x8000_0001;
const HANDLE_SLOT_BITS: u32 = 5;
const MAX_SLOT_INDEX: u32 = (@as(u32, 1) << HANDLE_SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - HANDLE_SLOT_BITS)) - 1;

pub const SlotInfo = struct {
    handle: arch.ThreadContextHandle,
    configuration: arch.ThreadContextConfiguration,
};

pub const SwitchOperation = struct {
    current: arch.ThreadContextHandle,
    next: arch.ThreadContextHandle,
};

const Slot = struct {
    generation: u32 = 1,
    configuration: arch.ThreadContextConfiguration = undefined,
    used: bool = false,
    retired: bool = false,
};

var slots: [MAX_CONTEXTS]Slot = [_]Slot{.{}} ** MAX_CONTEXTS;
var current_handle: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;
var last_switch: ?SwitchOperation = null;
var activation_count: usize = 0;
var fail_next_create = false;
var kernel_configuration: ?arch.KernelContinuationConfiguration = null;
var kernel_active = false;

pub fn create(
    configuration: arch.ThreadContextConfiguration,
) arch.ThreadContextError!arch.ThreadContextHandle {
    if (configuration.address_space_root.value == 0) return error.InvalidAddressSpaceRoot;
    if (configuration.entry_point == 0) return error.InvalidEntryPoint;
    if (configuration.stack_pointer == 0) return error.InvalidStackPointer;
    if (fail_next_create) {
        fail_next_create = false;
        return error.OutOfThreadContexts;
    }

    const slot_index = findFreeSlot() orelse return error.OutOfThreadContexts;
    const slot = &slots[slot_index];
    slot.* = .{
        .generation = slot.generation,
        .configuration = configuration,
        .used = true,
    };
    return makeHandle(slot_index, slot.generation);
}

pub fn createKernelContinuation(
    configuration: arch.KernelContinuationConfiguration,
) arch.ThreadContextError!arch.ThreadContextHandle {
    if (configuration.address_space_root.value == 0) return error.InvalidAddressSpaceRoot;
    if (kernel_configuration != null) return error.KernelContinuationAlreadyExists;
    kernel_configuration = configuration;
    kernel_active = false;
    return KERNEL_CONTEXT_HANDLE;
}

pub fn destroy(handle: arch.ThreadContextHandle) arch.ThreadContextError!void {
    if (handle == KERNEL_CONTEXT_HANDLE) {
        if (kernel_configuration == null) return error.InvalidThreadContextHandle;
        if (kernel_active or current_handle == handle) return error.ThreadContextInUse;
        kernel_configuration = null;
        return;
    }
    const slot = try resolveMutableSlot(handle);
    if (current_handle == handle) return error.ThreadContextInUse;

    slot.used = false;
    if (slot.generation == MAX_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

pub fn activate(handle: arch.ThreadContextHandle) noreturn {
    const root = contextRoot(handle) catch @panic("invalid mock thread context activation");
    current_handle = handle;
    kernel_active = handle == KERNEL_CONTEXT_HANDLE;
    activation_count += 1;
    arch.mmu.switchAddressSpaceRoot(root);
    @panic("mock architecture cannot activate a thread context");
}

pub fn switchContext(
    current: arch.ThreadContextHandle,
    next: arch.ThreadContextHandle,
) arch.ThreadContextError!void {
    const current_root = try contextRoot(current);
    if (current_handle != arch.INVALID_THREAD_CONTEXT_HANDLE and current_handle != current) {
        return error.InvalidThreadContextHandle;
    }
    if (current == next) {
        current_handle = current;
        arch.mmu.switchAddressSpaceRoot(current_root);
        return;
    }
    const next_root = try contextRoot(next);

    current_handle = next;
    kernel_active = next == KERNEL_CONTEXT_HANDLE;
    last_switch = .{ .current = current, .next = next };
    arch.mmu.switchAddressSpaceRoot(next_root);
}

pub fn availableCount() usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (!slot.used and !slot.retired) count += 1;
    }
    return count;
}

pub fn getForTest(handle: arch.ThreadContextHandle) arch.ThreadContextError!SlotInfo {
    const slot = try resolveSlot(handle);
    return .{ .handle = handle, .configuration = slot.configuration };
}

pub fn getCurrentForTest() arch.ThreadContextHandle {
    return current_handle;
}

pub fn getLastSwitchForTest() ?SwitchOperation {
    return last_switch;
}

pub fn getActivationCountForTest() usize {
    return activation_count;
}

pub fn failNextCreateForTest() void {
    fail_next_create = true;
}

pub fn resetForTest() void {
    slots = [_]Slot{.{}} ** MAX_CONTEXTS;
    current_handle = arch.INVALID_THREAD_CONTEXT_HANDLE;
    last_switch = null;
    activation_count = 0;
    fail_next_create = false;
    kernel_configuration = null;
    kernel_active = false;
}

pub fn getKernelConfigurationForTest() ?arch.KernelContinuationConfiguration {
    return kernel_configuration;
}

fn contextRoot(handle: arch.ThreadContextHandle) arch.ThreadContextError!arch.AddressSpaceRoot {
    if (handle == KERNEL_CONTEXT_HANDLE) {
        const configuration = kernel_configuration orelse return error.InvalidThreadContextHandle;
        return configuration.address_space_root;
    }
    return (try resolveSlot(handle)).configuration.address_space_root;
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
    if (MAX_CONTEXTS != MAX_SLOT_INDEX + 1) @compileError("mock context handle layout mismatch");
}
