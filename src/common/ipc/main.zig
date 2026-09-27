//! Architecture-independent inter-process communication objects.

/// Bounded synchronous endpoint registry and message queues.
pub const endpoint = @import("endpoint.zig");
/// Blocking buffered endpoint operations and deferred syscall completion.
pub const operations = @import("operations.zig");
/// One-way delivery of trusted kernel-generated endpoint messages.
pub const kernel_delivery = @import("kernel_delivery.zig");
/// Direct-rendezvous capability transfer with transactional exact-slot installation.
pub const transfer_operations = @import("transfer_operations.zig");
