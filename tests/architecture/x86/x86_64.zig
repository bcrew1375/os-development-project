const arch = @import("arch");
const framework = @import("../framework.zig");

pub const tests = [_]framework.TestCase{
    .{ .name = "x86-64 kernel uses higher half", .function = kernelUsesHigherHalf },
    .{ .name = "x86-64 HHDM is page aligned", .function = hhdmIsPageAligned },
    .{ .name = "x86-64 descriptor tables initialize", .function = descriptorTablesInitialize },
    .{ .name = "x86-64 address-space root can be created", .function = addressSpaceRootCanBeCreated },
    .{ .name = "x86-64 platform console initializes", .function = platformConsoleInitializes },
    .{ .name = "x86-64 platform timer initializes", .function = platformTimerInitializes },
};

fn kernelUsesHigherHalf() !void {
    try framework.expectEqual(@as(u64, 0xFFFFFFFF80000000), arch.mmu.getKernelVirtualAddressStart());
}

fn hhdmIsPageAligned() !void {
    const direct_map_address = arch.mmu.getDirectMapVirtualAddress();
    try framework.expect(direct_map_address != 0);
    try framework.expect(direct_map_address % arch.mmu.getPageSize() == 0);
}

fn descriptorTablesInitialize() !void {
    @call(.never_inline, arch.boot.finishBoot, .{});
}

fn addressSpaceRootCanBeCreated() !void {
    const root = try @call(.never_inline, arch.mmu.createAddressSpaceRoot, .{});
    try framework.expect(root.value != 0);
    try framework.expect(root.value % arch.mmu.getPageSize() == 0);
}

fn platformConsoleInitializes() !void {
    @call(.never_inline, arch.platform.initializeConsole, .{});
    arch.platform.writer().writeAll("QEMU-TEST console smoke output\n") catch
        return framework.TestError.ExpectationFailed;
}

fn platformTimerInitializes() !void {
    arch.interrupts.disableInterrupts();
    @call(.never_inline, arch.platform.initializeTimer, .{100});
    arch.interrupts.disableInterrupts();
}
