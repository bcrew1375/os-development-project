const Architecture = @import("../common/arch.zig").makeArchitecture(.{
    .early_allocator = @import("early_allocator/main.zig"),
    .boot = @import("boot/main.zig"),
    .cpu = @import("cpu/main.zig"),
    .interrupts = @import("interrupts/main.zig"),
    .mmu = @import("mmu/main.zig"),
    .platform = @import("platform/main.zig"),
    .thread_context = @import("thread_context/main.zig"),
});

pub const early_allocator = Architecture.early_allocator;
pub const boot = Architecture.boot;
pub const cpu = Architecture.cpu;
pub const interrupts = Architecture.interrupts;
pub const mmu = Architecture.mmu;
pub const platform = Architecture.platform;
pub const thread_context = Architecture.thread_context;
