const arch = @import("arch");

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

pub fn isBootFinishedForTest() bool {
    return bootFinished;
}

pub fn resetForTest() void {
    moduleCount = 0;
    bootFinished = false;
}
