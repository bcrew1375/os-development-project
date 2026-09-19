// Compatibility module so code can `@import("arch")`.
pub const architecture = @import("architecture/architecture.zig");

pub const early_allocator = architecture.early_allocator;
pub const boot = architecture.boot;
pub const cpu = architecture.cpu;
pub const interrupts = architecture.interrupts;
pub const mmu = architecture.mmu;
pub const platform = architecture.platform;
pub const TextColor = architecture.TextColor;
pub const ReservedMapRegionType = architecture.ReservedMapRegionType;
pub const MAX_BOOT_MODULES = architecture.MAX_BOOT_MODULES;
