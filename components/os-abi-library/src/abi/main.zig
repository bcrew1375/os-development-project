//! Stable user/kernel ABI definitions shared by the kernel and root process.

/// System call numbers and low-level syscall entry helpers.
pub const syscall = @import("syscall.zig");
/// Boot-time data structures passed to the first user process.
pub const boot_info = @import("boot_info.zig");
/// Capability handle, object type, and rights definitions.
pub const capability = @import("capability.zig");
