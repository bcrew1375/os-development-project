//! Common memory-management subsystems.

/// Physical range normalization and retained-range accounting.
pub const physical_ranges = @import("physical_ranges.zig");
/// Boot-map and reservation adapters for normalized physical memory.
pub const physical_memory_bootstrap = @import("physical_memory_bootstrap.zig");
/// Bounded authority objects for immutable physical-memory ranges.
pub const physical_memory_authority = @import("physical_memory_authority.zig");
/// Virtual memory area and mapping manager.
pub const virtual_memory = @import("vmm.zig");
