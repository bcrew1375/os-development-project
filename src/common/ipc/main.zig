//! Architecture-independent inter-process communication objects.

/// Bounded synchronous endpoint registry and message queues.
pub const endpoint = @import("endpoint.zig");
/// Blocking buffered endpoint operations and deferred syscall completion.
pub const operations = @import("operations.zig");
