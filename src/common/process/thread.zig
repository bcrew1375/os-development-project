//! Bounded architecture-neutral thread objects and lifecycle policy.

const std = @import("std");
const arch = @import("arch");
const capability_space = @import("../capability/space.zig");
const endpoint = @import("../ipc/endpoint.zig");

pub const MAX_THREADS: usize = 32;
const HANDLE_SLOT_BITS: u32 = 5;
const MAX_SLOT_INDEX: u32 = (@as(u32, 1) << HANDLE_SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - HANDLE_SLOT_BITS)) - 1;

pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;
pub const CapabilitySpaceHandle = capability_space.Handle;
pub const AddressSpaceHandle = u32;
pub const ProcessHandle = u32;

pub const State = enum {
    new,
    ready,
    running,
    blocked,
    faulted,
    exited,
};

pub const BlockReason = union(enum) {
    suspended,
    fault_manager: endpoint.Handle,
    endpoint_send: endpoint.Handle,
    endpoint_receive: endpoint.Handle,
    endpoint_transfer_send: endpoint.Handle,
    endpoint_transfer_receive: endpoint.Handle,
};

pub const UserFaultKind = enum {
    divide_by_zero,
    invalid_opcode,
    general_protection,
    page_fault,
    alignment_check,
};

pub const UserFault = struct {
    kind: UserFaultKind,
    instruction_pointer: u64,
    address: u64 = 0,
    architecture_error: u64 = 0,
};

pub const Configuration = struct {
    capability_space_handle: CapabilitySpaceHandle,
    address_space_handle: AddressSpaceHandle,
    entry_point: u64,
    stack_pointer: u64,
    argument: u64 = 0,
    lifecycle_endpoint_handle: endpoint.Handle = endpoint.INVALID_HANDLE,
    lifecycle_token: u32 = 0,
    fault_endpoint_handle: endpoint.Handle = endpoint.INVALID_HANDLE,
    fault_token: u32 = 0,
};

pub const Thread = struct {
    owner_process_handle: ProcessHandle,
    state: State = .new,
    capability_space_handle: CapabilitySpaceHandle = 0,
    address_space_handle: AddressSpaceHandle = 0,
    entry_point: u64 = 0,
    stack_pointer: u64 = 0,
    argument: u64 = 0,
    architecture_context_handle: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE,
    exit_status: ?u64 = null,
    user_fault: ?UserFault = null,
    block_reason: ?BlockReason = null,
    lifecycle_endpoint_handle: endpoint.Handle = endpoint.INVALID_HANDLE,
    lifecycle_token: u32 = 0,
    fault_endpoint_handle: endpoint.Handle = endpoint.INVALID_HANDLE,
    fault_token: u32 = 0,

    pub fn isConfigured(self: Thread) bool {
        return self.capability_space_handle != 0 and
            self.address_space_handle != 0 and
            self.entry_point != 0 and
            self.stack_pointer != 0 and
            self.architecture_context_handle != arch.INVALID_THREAD_CONTEXT_HANDLE;
    }
};

pub const Error = error{
    OutOfThreads,
    InvalidThreadHandle,
    InvalidCapabilitySpaceHandle,
    InvalidAddressSpaceHandle,
    InvalidEntryPoint,
    InvalidStackPointer,
    ThreadAlreadyConfigured,
    ThreadNotConfigured,
    InvalidStateTransition,
    ThreadInUse,
    InvalidLifecycleToken,
    InvalidFaultToken,
    FaultReplyUnauthorized,
} || arch.ThreadContextError;

const Slot = struct {
    generation: u32 = 1,
    thread: Thread = emptyThread(),
    used: bool = false,
    retired: bool = false,
};

var slots: [MAX_THREADS]Slot = [_]Slot{.{}} ** MAX_THREADS;

pub fn create(owner_process_handle: ProcessHandle) Error!Handle {
    const slot_index = findFreeSlot() orelse return Error.OutOfThreads;
    const slot = &slots[slot_index];
    slot.* = .{
        .generation = slot.generation,
        .thread = .{ .owner_process_handle = owner_process_handle },
        .used = true,
        .retired = false,
    };
    return makeHandle(slot_index, slot.generation);
}

pub fn get(handle: Handle) Error!Thread {
    return (try resolveSlot(handle)).thread;
}

pub fn configure(
    handle: Handle,
    configuration: Configuration,
    architecture_context_handle: arch.ThreadContextHandle,
) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .new) return Error.InvalidStateTransition;
    if (slot.thread.isConfigured()) return Error.ThreadAlreadyConfigured;
    if (configuration.capability_space_handle == 0) {
        return Error.InvalidCapabilitySpaceHandle;
    }
    if (configuration.address_space_handle == 0) return Error.InvalidAddressSpaceHandle;
    if (configuration.entry_point == 0) return Error.InvalidEntryPoint;
    if (configuration.stack_pointer == 0) return Error.InvalidStackPointer;
    if (architecture_context_handle == arch.INVALID_THREAD_CONTEXT_HANDLE) {
        return error.InvalidThreadContextHandle;
    }
    if ((configuration.lifecycle_endpoint_handle == endpoint.INVALID_HANDLE) !=
        (configuration.lifecycle_token == 0))
    {
        return error.InvalidLifecycleToken;
    }
    if ((configuration.fault_endpoint_handle == endpoint.INVALID_HANDLE) !=
        (configuration.fault_token == 0))
    {
        return error.InvalidFaultToken;
    }

    slot.thread.capability_space_handle = configuration.capability_space_handle;
    slot.thread.address_space_handle = configuration.address_space_handle;
    slot.thread.entry_point = configuration.entry_point;
    slot.thread.stack_pointer = configuration.stack_pointer;
    slot.thread.argument = configuration.argument;
    slot.thread.architecture_context_handle = architecture_context_handle;
    slot.thread.lifecycle_endpoint_handle = configuration.lifecycle_endpoint_handle;
    slot.thread.lifecycle_token = configuration.lifecycle_token;
    slot.thread.fault_endpoint_handle = configuration.fault_endpoint_handle;
    slot.thread.fault_token = configuration.fault_token;
}

pub fn makeReady(handle: Handle) Error!void {
    const slot = try resolveMutableSlot(handle);
    switch (slot.thread.state) {
        .new => {
            if (!slot.thread.isConfigured()) return Error.ThreadNotConfigured;
        },
        .blocked => if (!sameBlockReason(slot.thread.block_reason, .suspended)) {
            return Error.InvalidStateTransition;
        },
        .running => {},
        .ready, .faulted, .exited => return Error.InvalidStateTransition,
    }
    slot.thread.state = .ready;
    slot.thread.block_reason = null;
}

pub fn startRunning(handle: Handle) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .ready) return Error.InvalidStateTransition;
    slot.thread.state = .running;
}

pub fn block(handle: Handle) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .running) return Error.InvalidStateTransition;
    slot.thread.state = .blocked;
    slot.thread.block_reason = .suspended;
}

pub fn blockForEndpoint(handle: Handle, reason: BlockReason) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .running) return Error.InvalidStateTransition;
    switch (reason) {
        .endpoint_send,
        .endpoint_receive,
        .endpoint_transfer_send,
        .endpoint_transfer_receive,
        => {},
        .suspended, .fault_manager => return Error.InvalidStateTransition,
    }
    slot.thread.state = .blocked;
    slot.thread.block_reason = reason;
}

pub fn wakeFromEndpoint(handle: Handle, expected: BlockReason) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .blocked) return Error.InvalidStateTransition;
    if (!sameBlockReason(slot.thread.block_reason, expected)) return Error.InvalidStateTransition;
    slot.thread.state = .ready;
    slot.thread.block_reason = null;
}

pub fn suspendReady(handle: Handle) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .ready) return Error.InvalidStateTransition;
    slot.thread.state = .blocked;
    slot.thread.block_reason = .suspended;
}

pub fn suspendRunning(handle: Handle) Error!void {
    return block(handle);
}

pub fn exit(handle: Handle, status: u64) Error!void {
    const slot = try resolveMutableSlot(handle);
    switch (slot.thread.state) {
        .new, .ready, .running, .blocked => {},
        .faulted, .exited => return Error.InvalidStateTransition,
    }
    if (slot.thread.block_reason) |reason| switch (reason) {
        .fault_manager => try arch.thread_context.clearFaultFrame(
            slot.thread.architecture_context_handle,
        ),
        else => {},
    };
    slot.thread.state = .exited;
    _ = endpoint.cancelThread(handle);
    slot.thread.block_reason = null;
    slot.thread.exit_status = status;
    slot.thread.user_fault = null;
}

pub fn recordFault(handle: Handle, fault: UserFault) Error!void {
    const slot = try resolveMutableSlot(handle);
    switch (slot.thread.state) {
        .ready, .running, .blocked => {},
        .new, .faulted, .exited => return Error.InvalidStateTransition,
    }
    slot.thread.state = .faulted;
    _ = endpoint.cancelThread(handle);
    slot.thread.block_reason = null;
    slot.thread.exit_status = null;
    slot.thread.user_fault = fault;
}

pub fn suspendForFault(handle: Handle, fault: UserFault) Error!void {
    const slot = try resolveMutableSlot(handle);
    if (slot.thread.state != .running or
        slot.thread.fault_endpoint_handle == endpoint.INVALID_HANDLE)
    {
        return error.InvalidStateTransition;
    }
    slot.thread.state = .blocked;
    slot.thread.block_reason = .{ .fault_manager = slot.thread.fault_endpoint_handle };
    slot.thread.exit_status = null;
    slot.thread.user_fault = fault;
}

pub fn authorizeFaultReply(
    handle: Handle,
    endpoint_handle: endpoint.Handle,
    token: u32,
) Error!Thread {
    const object = (try resolveSlot(handle)).thread;
    if (object.state != .blocked or
        !sameBlockReason(object.block_reason, .{ .fault_manager = endpoint_handle }))
    {
        return error.InvalidStateTransition;
    }
    if (token == 0 or object.fault_token != token or object.user_fault == null) {
        return error.FaultReplyUnauthorized;
    }
    return object;
}

pub fn resumeFromFault(handle: Handle, endpoint_handle: endpoint.Handle, token: u32) Error!void {
    const slot = try resolveMutableSlot(handle);
    _ = try authorizeFaultReply(handle, endpoint_handle, token);
    slot.thread.state = .ready;
    slot.thread.block_reason = null;
    slot.thread.user_fault = null;
}

pub fn destroy(handle: Handle) Error!void {
    const slot = try resolveMutableSlot(handle);
    switch (slot.thread.state) {
        .new, .faulted, .exited => {},
        .ready, .running, .blocked => return Error.ThreadInUse,
    }

    if (slot.thread.architecture_context_handle != arch.INVALID_THREAD_CONTEXT_HANDLE) {
        try arch.thread_context.destroy(slot.thread.architecture_context_handle);
    }

    slot.used = false;
    slot.thread = emptyThread();
    if (slot.generation == MAX_GENERATION) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

pub fn referencesAddressSpace(address_space_handle: AddressSpaceHandle) bool {
    if (address_space_handle == 0) return false;
    for (slots) |slot| {
        if (slot.used and slot.thread.address_space_handle == address_space_handle) {
            return true;
        }
    }
    return false;
}

pub fn referencesCapabilitySpace(capability_space_handle: CapabilitySpaceHandle) bool {
    if (capability_space_handle == capability_space.INVALID_HANDLE) return false;
    for (slots) |slot| {
        if (slot.used and slot.thread.capability_space_handle == capability_space_handle) {
            return true;
        }
    }
    return false;
}

pub fn referencesLifecycleEndpoint(endpoint_handle: endpoint.Handle) bool {
    if (endpoint_handle == endpoint.INVALID_HANDLE) return false;
    for (slots) |slot| {
        if (slot.used and slot.thread.lifecycle_endpoint_handle == endpoint_handle) return true;
    }
    return false;
}

pub fn referencesFaultEndpoint(endpoint_handle: endpoint.Handle) bool {
    if (endpoint_handle == endpoint.INVALID_HANDLE) return false;
    for (slots) |slot| {
        if (slot.used and slot.thread.fault_endpoint_handle == endpoint_handle) return true;
    }
    return false;
}

pub fn availableCount() usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (!slot.used and !slot.retired) count += 1;
    }
    return count;
}

pub fn activeCount() usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.used) count += 1;
    }
    return count;
}

pub fn resetForTest() void {
    for (&slots) |*slot| {
        if (slot.used and
            slot.thread.architecture_context_handle != arch.INVALID_THREAD_CONTEXT_HANDLE)
        {
            arch.thread_context.destroy(slot.thread.architecture_context_handle) catch {};
        }
    }
    slots = [_]Slot{.{}} ** MAX_THREADS;
}

fn resolveSlot(handle: Handle) Error!*const Slot {
    const slot_index = handleSlotIndex(handle) orelse return Error.InvalidThreadHandle;
    const generation = handle >> HANDLE_SLOT_BITS;
    const slot = &slots[slot_index];
    if (!slot.used or slot.generation != generation) return Error.InvalidThreadHandle;
    return slot;
}

fn resolveMutableSlot(handle: Handle) Error!*Slot {
    return @constCast(try resolveSlot(handle));
}

fn findFreeSlot() ?usize {
    for (slots, 0..) |slot, index| {
        if (!slot.used and !slot.retired) return index;
    }
    return null;
}

fn makeHandle(slot_index: usize, generation: u32) Handle {
    std.debug.assert(slot_index <= MAX_SLOT_INDEX);
    std.debug.assert(generation > 0 and generation <= MAX_GENERATION);
    return (generation << HANDLE_SLOT_BITS) | @as(u32, @intCast(slot_index));
}

fn handleSlotIndex(handle: Handle) ?usize {
    if (handle == INVALID_HANDLE) return null;
    const generation = handle >> HANDLE_SLOT_BITS;
    if (generation == 0) return null;
    const slot_index: usize = @intCast(handle & MAX_SLOT_INDEX);
    if (slot_index >= slots.len) return null;
    return slot_index;
}

fn emptyThread() Thread {
    return .{ .owner_process_handle = 0 };
}

fn sameBlockReason(actual: ?BlockReason, expected: BlockReason) bool {
    const reason = actual orelse return false;
    return switch (reason) {
        .suspended => expected == .suspended,
        .fault_manager => |handle| switch (expected) {
            .fault_manager => |expected_handle| handle == expected_handle,
            else => false,
        },
        .endpoint_send => |handle| switch (expected) {
            .endpoint_send => |expected_handle| handle == expected_handle,
            else => false,
        },
        .endpoint_receive => |handle| switch (expected) {
            .endpoint_receive => |expected_handle| handle == expected_handle,
            else => false,
        },
        .endpoint_transfer_send => |handle| switch (expected) {
            .endpoint_transfer_send => |expected_handle| handle == expected_handle,
            else => false,
        },
        .endpoint_transfer_receive => |handle| switch (expected) {
            .endpoint_transfer_receive => |expected_handle| handle == expected_handle,
            else => false,
        },
    };
}

comptime {
    std.debug.assert(MAX_THREADS == MAX_SLOT_INDEX + 1);
    std.debug.assert(MAX_THREADS <= arch.impl.thread_context.MAX_CONTEXTS);
}
