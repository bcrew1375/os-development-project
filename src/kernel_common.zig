//! Common kernel subsystems shared by architecture-independent code.

/// Terminal and console helpers.
pub const terminal = @import("common/terminal/main.zig");
/// Common memory-management facilities.
pub const memory_management = @import("common/memory_management/main.zig");

// Compatibility aliases for existing code. New imports should prefer the
// hierarchical module names so call sites communicate their subsystem boundary.
/// Compatibility alias for `memory_management.physical_memory`.
pub const pmm = memory_management.physical_memory;
/// Compatibility alias for `memory_management.virtual_memory`.
pub const vmm = memory_management.virtual_memory;
/// Compatibility alias for `memory_management.kernel_heap`.
pub const kernel_heap = memory_management.kernel_heap;
/// Compatibility alias for `memory_management.heap`.
pub const heap = memory_management.heap;
/// Process and memory-object registries.
pub const process = @import("common/process/main.zig");
/// Kernel capability table implementation.
pub const capability = @import("common/capability/main.zig");
/// Architecture-independent syscall policy dispatcher.
pub const syscall = @import("common/syscall/main.zig");
/// Checked access helpers for userspace memory.
pub const user_memory = @import("common/user_memory.zig");
