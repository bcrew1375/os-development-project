//! Notification and logical interrupt-source ABI definitions.

/// Kernel-defined interrupt sources that userspace may acquire by policy.
pub const InterruptSourceKind = enum(u32) {
    timer = 1,
    _,
};

/// Result returned by a notification wait operation.
pub const WaitResult = struct {
    status: u32,
    pending_count: u32,
    overflowed: bool,
};
