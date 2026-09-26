//! Fixed-register IPC message types shared across protection domains.

/// Number of machine-independent message words transferred by an endpoint operation.
pub const MESSAGE_REGISTER_COUNT: usize = 3;

/// Bounded endpoint message transferred atomically without userspace pointers.
pub const Message = struct {
    words: [MESSAGE_REGISTER_COUNT]u32 = .{ 0, 0, 0 },
};

/// Result returned by a non-blocking endpoint receive operation.
pub const ReceiveResult = struct {
    status: u32,
    message: Message = .{},
};
