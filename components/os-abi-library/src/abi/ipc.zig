//! Fixed-register IPC message types shared across protection domains.

const capability = @import("capability.zig");

/// Number of machine-independent message words transferred by an endpoint operation.
pub const MESSAGE_REGISTER_COUNT: usize = 3;

/// Bounded endpoint message transferred atomically without userspace pointers.
pub const Message = extern struct {
    words: [MESSAGE_REGISTER_COUNT]u32 = .{ 0, 0, 0 },
};

/// Result returned by a non-blocking endpoint receive operation.
pub const ReceiveResult = struct {
    status: u32,
    message: Message = .{},
};

/// Fixed-layout userspace input for an endpoint capability-transfer send.
pub const TransferSendRequest = extern struct {
    source_capability: capability.CapabilityHandle,
    rights_bits: u32,
    message: Message,
};

/// Fixed-layout userspace input for an endpoint capability-transfer receive.
pub const TransferReceiveRequest = extern struct {
    destination_slot: u32,
};

/// Register result returned by a capability-transfer receive operation.
pub const TransferReceiveResult = struct {
    status: u32,
    message: Message = .{},
    capability: capability.CapabilityHandle = capability.INVALID_CAPABILITY,
};
