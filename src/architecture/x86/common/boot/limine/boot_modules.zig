const arch = @import("arch");
const limine_protocol = @import("protocol.zig");
const limine_requests = @import("requests.zig");

var bootModules: [arch.MAX_BOOT_MODULES]arch.BootModule = undefined;
var bootModuleCount: usize = 0;
var bootModulesCached = false;

pub fn cacheBootModules() void {
    if (bootModulesCached) {
        return;
    }

    const module_count = getAvailableLimineModuleCount();
    const modules = getLimineModules() orelse {
        bootModuleCount = 0;
        bootModulesCached = true;
        return;
    };

    for (0..module_count) |module_index| {
        bootModules[module_index] = convertLimineModule(modules[module_index]);
    }

    bootModuleCount = module_count;
    bootModulesCached = true;
}

pub fn getBootModule(index: usize) ?arch.BootModule {
    ensureBootModulesCached();
    if (index >= bootModuleCount) {
        return null;
    }
    return bootModules[index];
}

pub fn getBootModuleCount() usize {
    ensureBootModulesCached();
    return bootModuleCount;
}

fn ensureBootModulesCached() void {
    if (!bootModulesCached) {
        @panic("Boot modules were not cached before runtime access");
    }
}

pub fn reserveBootModules() arch.EarlyAllocError!void {
    const module_count = getAvailableLimineModuleCount();
    const modules = getLimineModules() orelse return;

    for (0..module_count) |module_index| {
        const boot_module = convertLimineModule(modules[module_index]);
        if (boot_module.physical_start >= boot_module.physical_end) {
            continue;
        }

        try arch.early_allocator.reserve(
            boot_module.physical_start,
            boot_module.physical_end - boot_module.physical_start,
            arch.ReservedMapRegionType.BOOTLOADER_DATA,
        );
    }
}

fn getAvailableLimineModuleCount() usize {
    const response = limine_requests.moduleResponse() orelse return 0;
    return @min(@as(usize, @intCast(response.module_count)), arch.MAX_BOOT_MODULES);
}

fn getLimineModules() ?[*]const *const limine_protocol.File {
    const response = limine_requests.moduleResponse() orelse return null;
    return response.modules;
}

fn convertLimineModule(file: *const limine_protocol.File) arch.BootModule {
    const virtual_start = @intFromPtr(file.address);
    const physical_start = physicalAddressFromLiminePointer(virtual_start);
    return .{
        .physical_start = physical_start,
        .physical_end = physical_start + @as(usize, @intCast(file.size)),
    };
}

fn physicalAddressFromLiminePointer(address: usize) usize {
    const hhdm_offset = limine_requests.hhdmOffset();
    if (hhdm_offset != 0 and address >= hhdm_offset) {
        return address - hhdm_offset;
    }

    return address;
}
