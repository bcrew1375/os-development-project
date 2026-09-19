const arch = @import("arch");
const framework = @import("../framework.zig");

pub fn kernelUsesHigherHalf() !void {
    try framework.expectEqual(@as(u64, 0xFFFFFFFF80000000), arch.mmu.getKernelVirtualAddressStart());
}

pub fn hhdmIsPageAligned() !void {
    const direct_map_address = arch.mmu.getDirectMapVirtualAddress();
    try framework.expect(direct_map_address != 0);
    try framework.expect(direct_map_address % arch.mmu.getPageSize() == 0);
}

pub fn descriptorTablesInitialize() !void {
    @call(.never_inline, arch.boot.finishBoot, .{});
}

pub fn platformConsoleInitializes() !void {
    @call(.never_inline, arch.platform.initializeConsole, .{});
    arch.platform.writer().writeAll("console smoke output\n") catch
        return framework.TestError.ExpectationFailed;
}
