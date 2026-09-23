//! Common memory-management subsystems.

/// Physical frame allocator.
pub const physical_memory = @import("pmm.zig");
/// Physical range normalization and retained-range accounting.
pub const physical_ranges = @import("physical_ranges.zig");
/// Boot-map and reservation adapters for normalized physical memory.
pub const physical_memory_bootstrap = @import("physical_memory_bootstrap.zig");
/// Bounded authority objects for immutable physical-memory ranges.
pub const physical_memory_authority = @import("physical_memory_authority.zig");
/// Virtual memory area and mapping manager.
pub const virtual_memory = @import("vmm.zig");
/// Boundary-tag heap allocator implementation.
pub const heap = @import("heap.zig");
/// Kernel global heap wrapper.
pub const kernel_heap = @import("kernel_heap.zig");
