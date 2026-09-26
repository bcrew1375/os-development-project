//! Bounded generation-checked synchronous IPC endpoint registry.

const abi = @import("abi");

pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;
pub const MAX_ENDPOINTS: usize = 32;
pub const MESSAGE_CAPACITY: usize = 8;

const SLOT_BITS: u32 = 5;
const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - SLOT_BITS)) - 1;

pub const Error = error{
    OutOfEndpoints,
    InvalidEndpointHandle,
    EndpointEmpty,
    EndpointFull,
    EndpointInUse,
};

const Slot = struct {
    generation: u32 = 1,
    messages: [MESSAGE_CAPACITY]abi.ipc.Message = [_]abi.ipc.Message{.{}} ** MESSAGE_CAPACITY,
    head: usize = 0,
    length: usize = 0,
    used: bool = false,
    retired: bool = false,
};

var slots: [MAX_ENDPOINTS]Slot = [_]Slot{.{}} ** MAX_ENDPOINTS;

/// Creates an empty endpoint from the fixed kernel registry.
pub fn create() Error!Handle {
    for (&slots, 0..) |*slot, index| {
        if (slot.used or slot.retired) continue;
        slot.used = true;
        slot.head = 0;
        slot.length = 0;
        return makeHandle(index, slot.generation);
    }
    return error.OutOfEndpoints;
}

/// Destroys an empty endpoint and invalidates its generation-checked handle.
pub fn destroy(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.length != 0) return error.EndpointInUse;
    const generation = slot.generation;
    const retired = generation == MAX_GENERATION;
    slot.* = .{
        .generation = if (retired) generation else generation + 1,
        .retired = retired,
    };
}

/// Atomically appends one message or reports that the bounded queue is full.
pub fn send(handle: Handle, message: abi.ipc.Message) Error!void {
    const slot = try resolve(handle);
    if (slot.length == MESSAGE_CAPACITY) return error.EndpointFull;
    const tail = (slot.head + slot.length) % MESSAGE_CAPACITY;
    slot.messages[tail] = message;
    slot.length += 1;
}

/// Atomically removes the oldest message or reports that the queue is empty.
pub fn receive(handle: Handle) Error!abi.ipc.Message {
    const slot = try resolve(handle);
    if (slot.length == 0) return error.EndpointEmpty;
    const message = slot.messages[slot.head];
    slot.messages[slot.head] = .{};
    slot.head = (slot.head + 1) % MESSAGE_CAPACITY;
    slot.length -= 1;
    return message;
}

pub fn availableCount() usize {
    var count: usize = 0;
    for (slots) |slot| if (!slot.used and !slot.retired) {
        count += 1;
    };
    return count;
}

pub fn resetForTest() void {
    slots = [_]Slot{.{}} ** MAX_ENDPOINTS;
}

fn resolve(handle: Handle) Error!*Slot {
    if (handle == INVALID_HANDLE) return error.InvalidEndpointHandle;
    const index: usize = @intCast(handle & SLOT_MASK);
    const generation = handle >> SLOT_BITS;
    if (index >= slots.len or generation == 0) return error.InvalidEndpointHandle;
    const slot = &slots[index];
    if (!slot.used or slot.generation != generation) return error.InvalidEndpointHandle;
    return slot;
}

fn makeHandle(index: usize, generation: u32) Handle {
    return (generation << SLOT_BITS) | @as(u32, @intCast(index));
}

comptime {
    if (MAX_ENDPOINTS != @as(usize, 1) << SLOT_BITS) {
        @compileError("endpoint slot bits must exactly cover the endpoint registry");
    }
}
