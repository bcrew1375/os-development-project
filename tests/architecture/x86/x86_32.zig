const arch = @import("arch");
const framework = @import("../framework.zig");

pub const tests = [_]framework.TestCase{
    .{ .name = "x86-32 direct map uses higher half", .function = directMapUsesHigherHalf },
};

fn directMapUsesHigherHalf() !void {
    try framework.expectEqual(@as(u64, 0xC0000000), arch.mmu.getDirectMapVirtualAddress());
    try framework.expect(arch.mmu.getDirectMapMaxSize() > 0);
}
