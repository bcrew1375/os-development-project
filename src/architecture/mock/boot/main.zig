const arch = @import("arch");
const std = @import("std");

var modules: [arch.MAX_MEMORY_MAP_ENTRIES]arch.BootModule = undefined;
var moduleCount: usize = 0;
var bootFinished = false;

pub fn finishBoot() void {
    bootFinished = true;
}

pub fn getBootModuleCount() usize {
    return moduleCount;
}

pub fn getBootModule(index: usize) ?arch.BootModule {
    if (index >= moduleCount) return null;
    return modules[index];
}

pub fn configureModulesForTest(configured_modules: []const arch.BootModule) void {
    if (configured_modules.len > modules.len) {
        @panic("mock boot module capacity exceeded");
    }
    @memcpy(modules[0..configured_modules.len], configured_modules);
    moduleCount = configured_modules.len;
}

pub fn configureModuleBytesForTest(physical_start: usize, bytes: []const u8) !arch.BootModule {
    const physical_end = std.math.add(usize, physical_start, bytes.len) catch {
        return error.InvalidBootModuleRange;
    };
    if (bytes.len == 0 or physical_end > arch.mmu.getDirectMapMaxSize()) {
        return error.InvalidBootModuleRange;
    }

    try arch.mmu.writePhysicalMemoryForTest(physical_start, bytes);
    const module = arch.BootModule{
        .physical_start = physical_start,
        .physical_end = physical_end,
    };
    configureModulesForTest(&.{module});
    return module;
}

pub fn isBootFinishedForTest() bool {
    return bootFinished;
}

pub fn resetForTest() void {
    moduleCount = 0;
    bootFinished = false;
}
