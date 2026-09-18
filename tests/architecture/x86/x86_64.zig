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

pub fn addressSpaceRootCanBeCreated() !void {
    const root = try @call(.never_inline, arch.mmu.createAddressSpaceRoot, .{});
    try framework.expect(root.value != 0);
    try framework.expect(root.value % arch.mmu.getPageSize() == 0);
}

pub fn platformConsoleInitializes() !void {
    @call(.never_inline, arch.platform.initializeConsole, .{});
    arch.platform.writer().writeAll("console smoke output\n") catch
        return framework.TestError.ExpectationFailed;
}

pub fn platformTimerInitializes() !void {
    arch.interrupts.disableInterrupts();
    @call(.never_inline, arch.platform.initializeTimer, .{100});
    arch.interrupts.disableInterrupts();
}
