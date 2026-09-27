//! Bounded registry of kernel-defined logical interrupt sources.

const abi = @import("abi");

pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;
pub const MAX_INTERRUPT_SOURCES: usize = 8;

const SLOT_BITS: u32 = 3;
const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - SLOT_BITS)) - 1;

pub const Error = error{
    OutOfInterruptSources,
    InvalidInterruptSourceHandle,
    InterruptSourceUnavailable,
    InterruptSourceInUse,
    InterruptSourceNotBound,
    InterruptSourceAlreadyAcknowledged,
    InvalidInterruptSourceConfiguration,
};

pub const State = struct {
    kind: abi.notification.InterruptSourceKind,
    notification_handle: ?u32,
    masked: bool,
    parameter: u32,
    acknowledgement_pending: bool,
};

const Slot = struct {
    generation: u32 = 1,
    kind: abi.notification.InterruptSourceKind = .timer,
    notification_handle: ?u32 = null,
    masked: bool = true,
    parameter: u32 = 0,
    acknowledgement_pending: bool = false,
    used: bool = false,
    retired: bool = false,
};

var slots: [MAX_INTERRUPT_SOURCES]Slot = [_]Slot{.{}} ** MAX_INTERRUPT_SOURCES;

pub fn create(kind: abi.notification.InterruptSourceKind, parameter: u32) Error!Handle {
    switch (kind) {
        .timer => if (parameter == 0) return error.InvalidInterruptSourceConfiguration,
        _ => return error.InvalidInterruptSourceConfiguration,
    }
    for (slots) |slot| {
        if (slot.used and slot.kind == kind) return error.InterruptSourceUnavailable;
    }
    for (&slots, 0..) |*slot, index| {
        if (slot.used or slot.retired) continue;
        slot.* = .{
            .generation = slot.generation,
            .kind = kind,
            .parameter = parameter,
            .used = true,
        };
        return makeHandle(index, slot.generation);
    }
    return error.OutOfInterruptSources;
}

pub fn destroy(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.notification_handle != null) return error.InterruptSourceInUse;
    retire(slot);
}

pub fn get(handle: Handle) Error!State {
    const slot = try resolve(handle);
    return .{
        .kind = slot.kind,
        .notification_handle = slot.notification_handle,
        .masked = slot.masked,
        .parameter = slot.parameter,
        .acknowledgement_pending = slot.acknowledgement_pending,
    };
}

pub fn find(kind: abi.notification.InterruptSourceKind) ?Handle {
    for (slots, 0..) |slot, index| {
        if (slot.used and slot.kind == kind) return makeHandle(index, slot.generation);
    }
    return null;
}

pub fn bind(handle: Handle, notification_handle: u32) Error!void {
    const slot = try resolve(handle);
    if (slot.notification_handle != null) return error.InterruptSourceInUse;
    slot.notification_handle = notification_handle;
    slot.masked = true;
}

pub fn unbind(handle: Handle) Error!u32 {
    const slot = try resolve(handle);
    const notification_handle = slot.notification_handle orelse {
        return error.InterruptSourceNotBound;
    };
    slot.notification_handle = null;
    slot.masked = true;
    slot.acknowledgement_pending = false;
    return notification_handle;
}

pub fn arm(handle: Handle) Error!abi.notification.InterruptSourceKind {
    const slot = try resolve(handle);
    if (slot.notification_handle == null) return error.InterruptSourceNotBound;
    if (!slot.masked or slot.acknowledgement_pending) {
        return error.InterruptSourceAlreadyAcknowledged;
    }
    slot.masked = false;
    return slot.kind;
}

pub fn maskForDelivery(handle: Handle) Error!u32 {
    const slot = try resolve(handle);
    const notification_handle = slot.notification_handle orelse {
        return error.InterruptSourceNotBound;
    };
    if (slot.masked) return error.InterruptSourceAlreadyAcknowledged;
    slot.masked = true;
    slot.acknowledgement_pending = true;
    return notification_handle;
}

pub fn acknowledge(handle: Handle) Error!abi.notification.InterruptSourceKind {
    const slot = try resolve(handle);
    if (slot.notification_handle == null) return error.InterruptSourceNotBound;
    if (!slot.masked or !slot.acknowledgement_pending) {
        return error.InterruptSourceAlreadyAcknowledged;
    }
    slot.masked = false;
    slot.acknowledgement_pending = false;
    return slot.kind;
}

pub fn resetForTest() void {
    slots = [_]Slot{.{}} ** MAX_INTERRUPT_SOURCES;
}

fn resolve(handle: Handle) Error!*Slot {
    if (handle == INVALID_HANDLE) return error.InvalidInterruptSourceHandle;
    const generation = handle >> SLOT_BITS;
    const index: usize = @intCast(handle & SLOT_MASK);
    if (generation == 0 or index >= slots.len) return error.InvalidInterruptSourceHandle;
    const slot = &slots[index];
    if (!slot.used or slot.generation != generation) return error.InvalidInterruptSourceHandle;
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
