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

pub const CHILD_STARTUP_MAGIC: u32 = 0x4348_4C44;
pub const CHILD_STARTUP_VERSION: u32 = 1;

pub const ChildStartupMode = enum(u32) {
    clean_exit = 1,
    invalid_opcode = 2,
};

/// Fixed-layout startup data copied into a new child process's initial stack.
pub const ChildStartup = extern struct {
    magic: u32 = CHILD_STARTUP_MAGIC,
    version: u32 = CHILD_STARTUP_VERSION,
    mode: ChildStartupMode,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ThreadConfiguration) == 32);
    std.debug.assert(@offsetOf(ThreadConfiguration, "capability_space") == 0);
    std.debug.assert(@offsetOf(ThreadConfiguration, "address_space") == 4);
    std.debug.assert(@offsetOf(ThreadConfiguration, "entry_point") == 8);
    std.debug.assert(@offsetOf(ThreadConfiguration, "stack_pointer") == 16);
    std.debug.assert(@offsetOf(ThreadConfiguration, "argument") == 24);
    std.debug.assert(@sizeOf(ChildStartup) == 16);
    std.debug.assert(@alignOf(ChildStartup) == 4);
    std.debug.assert(@offsetOf(ChildStartup, "mode") == 8);
}
