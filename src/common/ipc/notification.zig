//! Bounded generation-checked counted notification registry.

const std = @import("std");

pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;
pub const MAX_NOTIFICATIONS: usize = 32;

const SLOT_BITS: u32 = 5;
const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - SLOT_BITS)) - 1;

pub const Error = error{
    OutOfNotifications,
    InvalidNotificationHandle,
    NotificationInUse,
    NotificationAlreadyHasWaiter,
    NotificationWaiterNotFound,
};

pub const Authorization = struct {
    capability_space_handle: u32,
    capability_handle: u32,
};

pub const Waiter = struct {
    thread_handle: u32,
    architecture_context_handle: u32,
    authorization: Authorization,
};

pub const Pending = struct {
    count: u32,
    overflowed: bool,
};

const Slot = struct {
    generation: u32 = 1,
    pending_count: u32 = 0,
    overflowed: bool = false,
    waiter: ?Waiter = null,
    bound_source: ?u32 = null,
    used: bool = false,
    retired: bool = false,
};

var slots: [MAX_NOTIFICATIONS]Slot = [_]Slot{.{}} ** MAX_NOTIFICATIONS;

pub fn create() Error!Handle {
    for (&slots, 0..) |*slot, index| {
        if (slot.used or slot.retired) continue;
        slot.* = .{ .generation = slot.generation, .used = true };
        return makeHandle(index, slot.generation);
    }
    return error.OutOfNotifications;
}

pub fn destroy(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.waiter != null or slot.bound_source != null) return error.NotificationInUse;
    retire(slot);
}

pub fn consume(handle: Handle) Error!?Pending {
    const slot = try resolve(handle);
    if (slot.pending_count == 0 and !slot.overflowed) return null;
    const pending = Pending{ .count = slot.pending_count, .overflowed = slot.overflowed };
    slot.pending_count = 0;
    slot.overflowed = false;
    return pending;
}

pub fn addSignal(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.pending_count == std.math.maxInt(u32)) {
        slot.overflowed = true;
    } else {
        slot.pending_count += 1;
    }
}

pub fn setWaiter(handle: Handle, waiter: Waiter) Error!void {
    const slot = try resolve(handle);
    if (slot.waiter != null) return error.NotificationAlreadyHasWaiter;
    slot.waiter = waiter;
}

pub fn getWaiter(handle: Handle) Error!?Waiter {
    return (try resolve(handle)).waiter;
}

pub fn clearWaiter(handle: Handle, thread_handle: u32) Error!void {
    const slot = try resolve(handle);
    if (slot.waiter == null or slot.waiter.?.thread_handle != thread_handle) {
        return error.NotificationWaiterNotFound;
    }
    slot.waiter = null;
}

pub fn findByAuthorization(
    authorization: Authorization,
) ?struct { handle: Handle, waiter: Waiter } {
    for (&slots, 0..) |*slot, index| {
        const waiter = slot.waiter orelse continue;
        if (waiter.authorization.capability_space_handle == authorization.capability_space_handle and
            waiter.authorization.capability_handle == authorization.capability_handle)
        {
            return .{ .handle = makeHandle(index, slot.generation), .waiter = waiter };
        }
    }
    return null;
}

pub fn bindSource(handle: Handle, source_handle: u32) Error!void {
    const slot = try resolve(handle);
    if (slot.bound_source != null) return error.NotificationInUse;
    slot.bound_source = source_handle;
}

pub fn boundSource(handle: Handle) Error!?u32 {
    return (try resolve(handle)).bound_source;
}

pub fn unbindSource(handle: Handle, source_handle: u32) Error!void {
    const slot = try resolve(handle);
    if (slot.bound_source != source_handle) return error.NotificationInUse;
    slot.bound_source = null;
}

pub fn pendingForTest(handle: Handle) Error!Pending {
    const slot = try resolve(handle);
    return .{ .count = slot.pending_count, .overflowed = slot.overflowed };
}

pub fn setPendingForTest(handle: Handle, count: u32, overflowed: bool) Error!void {
    const slot = try resolve(handle);
    slot.pending_count = count;
    slot.overflowed = overflowed;
}

pub fn resetForTest() void {
    slots = [_]Slot{.{}} ** MAX_NOTIFICATIONS;
}

fn resolve(handle: Handle) Error!*Slot {
    if (handle == INVALID_HANDLE) return error.InvalidNotificationHandle;
    const generation = handle >> SLOT_BITS;
    const index: usize = @intCast(handle & SLOT_MASK);
    if (generation == 0 or index >= slots.len) return error.InvalidNotificationHandle;
    const slot = &slots[index];
    if (!slot.used or slot.generation != generation) return error.InvalidNotificationHandle;
    return slot;
}

fn retire(slot: *Slot) void {
    const generation = slot.generation;
    const retired = generation == MAX_GENERATION;
    slot.* = .{
        .generation = if (retired) generation else generation + 1,
        .retired = retired,
    };
}

fn makeHandle(index: usize, generation: u32) Handle {
    return (generation << SLOT_BITS) | @as(u32, @intCast(index));
}

comptime {
    std.debug.assert(MAX_NOTIFICATIONS == @as(usize, 1) << SLOT_BITS);
}
