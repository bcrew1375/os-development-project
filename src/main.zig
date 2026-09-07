//! Shared implementation modules usable by both kernel and userspace components.

/// Executable image parsing helpers.
pub const executable = @import("executable/main.zig");
