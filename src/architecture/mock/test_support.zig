const arch = @import("../architecture.zig");

const boot = @import("boot/main.zig");
const cpu = @import("cpu/main.zig");
const early_allocator = @import("early_allocator/main.zig");
const interrupts = @import("interrupts/main.zig");
const mmu = @import("mmu/main.zig");
const platform = @import("platform/main.zig");
const thread_context = @import("thread_context/main.zig");

pub const interrupt_diagnostics = @import("../x86/common/interrupts/diagnostics.zig");
pub const pic_policy = @import("../x86/common/interrupts/policy.zig");

pub fn initializeDefaultMemoryFixture() !void {
    try mmu.initializeDefaultMemoryFixtureForTest();
    resetState();
}

pub fn initializeMemoryFixture(
    backing_size: usize,
    regions: []const mmu.FixtureRegion,
) !void {
    try mmu.initializeMemoryFixtureForTest(backing_size, regions);
    resetState();
}

pub fn resetState() void {
    arch.page_table_pool.resetForTest();
    early_allocator.resetForTest();
    mmu.resetForTest();
    boot.resetForTest();
    interrupts.resetForTest();
    platform.resetForTest();
    cpu.resetForTest();
    thread_context.resetForTest();
}

pub fn deinitializeMemoryFixture() void {
    resetState();
    mmu.deinitializeMemoryFixtureForTest();
}
