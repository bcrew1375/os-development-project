const arch = @import("arch");
const framework = @import("../framework.zig");

pub fn directMapUsesHigherHalf() !void {
    try framework.expectEqual(@as(u64, 0xC0000000), arch.mmu.getDirectMapVirtualAddress());
    try framework.expect(arch.mmu.getDirectMapMaxSize() > 0);
}

pub fn descriptorTablesInitialize() !void {
    @call(.never_inline, arch.boot.finishBoot, .{});
}
