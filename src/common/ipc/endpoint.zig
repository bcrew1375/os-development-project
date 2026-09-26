//! Bounded generation-checked synchronous IPC endpoint registry.

const abi = @import("abi");

pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0;
pub const MAX_ENDPOINTS: usize = 32;
pub const MESSAGE_CAPACITY: usize = 8;
pub const WAITER_CAPACITY: usize = 32;

const SLOT_BITS: u32 = 5;
const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - SLOT_BITS)) - 1;

pub const Error = error{
    OutOfEndpoints,
    InvalidEndpointHandle,
    EndpointEmpty,
    EndpointFull,
    EndpointInUse,
    EndpointWaitQueueFull,
    ThreadAlreadyWaiting,
    EndpointWaiterNotFound,
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

pub const SenderWaiter = struct {
    waiter: Waiter,
    message: abi.ipc.Message,
};

pub const CanceledWaiter = union(enum) {
    sender: SenderWaiter,
    receiver: Waiter,
};

const ReceiverQueue = WaitQueue(Waiter);
const SenderQueue = WaitQueue(SenderWaiter);

const Slot = struct {
    generation: u32 = 1,
    messages: [MESSAGE_CAPACITY]abi.ipc.Message = [_]abi.ipc.Message{.{}} ** MESSAGE_CAPACITY,
    head: usize = 0,
    length: usize = 0,
    receivers: ReceiverQueue = .{},
    senders: SenderQueue = .{},
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
        slot.receivers = .{};
        slot.senders = .{};
        return makeHandle(index, slot.generation);
    }
    return error.OutOfEndpoints;
}

/// Destroys an empty endpoint and invalidates its generation-checked handle.
pub fn destroy(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.length != 0 or slot.receivers.length != 0 or slot.senders.length != 0) {
        return error.EndpointInUse;
    }
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

pub fn enqueueReceiver(handle: Handle, waiter: Waiter) Error!void {
    const slot = try resolve(handle);
    if (containsThread(slot, waiter.thread_handle)) return error.ThreadAlreadyWaiting;
    try slot.receivers.push(waiter);
}

pub fn enqueueSender(handle: Handle, waiter: SenderWaiter) Error!void {
    const slot = try resolve(handle);
    if (containsThread(slot, waiter.waiter.thread_handle)) return error.ThreadAlreadyWaiting;
    try slot.senders.push(waiter);
}

pub fn peekReceiver(handle: Handle) Error!?Waiter {
    return (try resolve(handle)).receivers.peek();
}

pub fn peekSender(handle: Handle) Error!?SenderWaiter {
    return (try resolve(handle)).senders.peek();
}

pub fn popReceiver(handle: Handle) Error!Waiter {
    return (try resolve(handle)).receivers.pop() orelse error.EndpointWaiterNotFound;
}

pub fn popSender(handle: Handle) Error!SenderWaiter {
    return (try resolve(handle)).senders.pop() orelse error.EndpointWaiterNotFound;
}

pub fn cancelThread(thread_handle: u32) bool {
    for (&slots) |*slot| {
        if (!slot.used) continue;
        if (slot.receivers.removeThread(thread_handle)) return true;
        if (slot.senders.removeThread(thread_handle)) return true;
    }
    return false;
}

pub fn findByAuthorization(authorization: Authorization) ?struct {
    endpoint_handle: Handle,
    waiter: CanceledWaiter,
} {
    for (&slots, 0..) |*slot, index| {
        if (!slot.used) continue;
        if (slot.receivers.findAuthorization(authorization)) |waiter| {
            return .{
                .endpoint_handle = makeHandle(index, slot.generation),
                .waiter = .{ .receiver = waiter },
            };
        }
        if (slot.senders.findAuthorization(authorization)) |waiter| {
            return .{
                .endpoint_handle = makeHandle(index, slot.generation),
                .waiter = .{ .sender = waiter },
            };
        }
    }
    return null;
}

pub fn findForEndpoint(handle: Handle) Error!?CanceledWaiter {
    const slot = try resolve(handle);
    if (slot.receivers.peek()) |waiter| return .{ .receiver = waiter };
    if (slot.senders.peek()) |waiter| return .{ .sender = waiter };
    return null;
}

pub fn removeWaiter(handle: Handle, thread_handle: u32) Error!void {
    const slot = try resolve(handle);
    if (slot.receivers.removeThread(thread_handle)) return;
    if (slot.senders.removeThread(thread_handle)) return;
    return error.EndpointWaiterNotFound;
}

pub fn messageCount(handle: Handle) Error!usize {
    return (try resolve(handle)).length;
}

pub fn receiverCount(handle: Handle) Error!usize {
    return (try resolve(handle)).receivers.length;
}

pub fn senderCount(handle: Handle) Error!usize {
    return (try resolve(handle)).senders.length;
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

fn containsThread(slot: *const Slot, thread_handle: u32) bool {
    return slot.receivers.containsThread(thread_handle) or
        slot.senders.containsThread(thread_handle);
}

fn WaitQueue(comptime Entry: type) type {
    return struct {
        entries: [WAITER_CAPACITY]Entry = undefined,
        head: usize = 0,
        length: usize = 0,

        fn push(self: *@This(), entry: Entry) Error!void {
            if (self.length == self.entries.len) return error.EndpointWaitQueueFull;
            self.entries[(self.head + self.length) % self.entries.len] = entry;
            self.length += 1;
        }

        fn peek(self: *const @This()) ?Entry {
            if (self.length == 0) return null;
            return self.entries[self.head];
        }

        fn pop(self: *@This()) ?Entry {
            if (self.length == 0) return null;
            const entry = self.entries[self.head];
            self.head = (self.head + 1) % self.entries.len;
            self.length -= 1;
            return entry;
        }

        fn containsThread(self: *const @This(), thread_handle: u32) bool {
            return self.findThreadOffset(thread_handle) != null;
        }

        fn removeThread(self: *@This(), thread_handle: u32) bool {
            const offset = self.findThreadOffset(thread_handle) orelse return false;
            var current = offset;
            while (current + 1 < self.length) : (current += 1) {
                self.entries[(self.head + current) % self.entries.len] =
                    self.entries[(self.head + current + 1) % self.entries.len];
            }
            self.length -= 1;
            return true;
        }

        fn findAuthorization(self: *const @This(), authorization: Authorization) ?Entry {
            for (0..self.length) |offset| {
                const entry = self.entries[(self.head + offset) % self.entries.len];
                if (equalAuthorization(entryAuthorization(entry), authorization)) return entry;
            }
            return null;
        }

        fn findThreadOffset(self: *const @This(), thread_handle: u32) ?usize {
            for (0..self.length) |offset| {
                const entry = self.entries[(self.head + offset) % self.entries.len];
                if (entryThreadHandle(entry) == thread_handle) return offset;
            }
            return null;
        }
    };
}

fn entryThreadHandle(entry: anytype) u32 {
    return switch (@TypeOf(entry)) {
        Waiter => entry.thread_handle,
        SenderWaiter => entry.waiter.thread_handle,
        else => @compileError("unsupported endpoint waiter entry"),
    };
}

fn entryAuthorization(entry: anytype) Authorization {
    return switch (@TypeOf(entry)) {
        Waiter => entry.authorization,
        SenderWaiter => entry.waiter.authorization,
        else => @compileError("unsupported endpoint waiter entry"),
    };
}

fn equalAuthorization(left: Authorization, right: Authorization) bool {
    return left.capability_space_handle == right.capability_space_handle and
        left.capability_handle == right.capability_handle;
}

comptime {
    if (MAX_ENDPOINTS != @as(usize, 1) << SLOT_BITS) {
        @compileError("endpoint slot bits must exactly cover the endpoint registry");
    }
}
