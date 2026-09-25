//! Stable userspace process-management ABI structures.

const std = @import("std");
const capability = @import("capability.zig");

/// Fixed-width input used to bind a newly created thread to execution resources.
pub const ThreadConfiguration = extern struct {
    capability_space: capability.CapabilityHandle,
    address_space: capability.CapabilityHandle,
    entry_point: u64,
    stack_pointer: u64,
    argument: u64,
};

comptime {
    std.debug.assert(@sizeOf(ThreadConfiguration) == 32);
    std.debug.assert(@offsetOf(ThreadConfiguration, "capability_space") == 0);
    std.debug.assert(@offsetOf(ThreadConfiguration, "address_space") == 4);
    std.debug.assert(@offsetOf(ThreadConfiguration, "entry_point") == 8);
    std.debug.assert(@offsetOf(ThreadConfiguration, "stack_pointer") == 16);
    std.debug.assert(@offsetOf(ThreadConfiguration, "argument") == 24);
}
