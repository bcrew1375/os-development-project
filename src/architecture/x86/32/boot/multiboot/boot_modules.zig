const build_options = @import("build_options");
const boot_text_section = if (build_options.x86_32_multiboot) ".multiboot.text" else ".text";
const boot_data_section = if (build_options.x86_32_multiboot) ".multiboot.data" else ".data";
const multiboot = @import("main.zig");

const arch = @import("arch");

pub const MultibootModule = extern struct {
    mod_start: u32,
    mod_end: u32,
    string: u32,
    reserved: u32,
};

var bootModules: [arch.MAX_BOOT_MODULES]arch.BootModule = undefined;
var bootModuleCount: usize = 0;
var bootModulesCached: bool = false;

pub fn cacheBootModules() linksection(boot_text_section) void {
    if (bootModulesCached) {
        return;
    }

    const available_modules = getAvailableMultibootModuleCount();
    if (available_modules == 0) {
        bootModuleCount = 0;
        bootModulesCached = true;
        return;
    }

    const multiboot_modules = getMultibootModules();

    for (0..available_modules) |module_index| {
        bootModules[module_index] = convertMultibootModule(multiboot_modules[module_index]);
    }

    bootModuleCount = available_modules;
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

pub fn reserveBootModules() linksection(boot_text_section) arch.EarlyAllocError!void {
    const available_modules = getAvailableMultibootModuleCount();
    if (available_modules == 0) {
        return;
    }

    const multiboot_modules = getMultibootModules();

    const multiboot_module_start_address = @intFromPtr(multiboot_modules);
    const multiboot_module_end_address = multiboot_module_start_address + (available_modules * @sizeOf(MultibootModule));

    try arch.early_allocator.reserve(
        multiboot_module_start_address,
        multiboot_module_end_address - multiboot_module_start_address,
        arch.ReservedMapRegionType.BOOTLOADER_DATA,
    );

    for (0..available_modules) |module_index| {
        const boot_module = convertMultibootModule(multiboot_modules[module_index]);
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

fn getAvailableMultibootModuleCount() linksection(boot_text_section) usize {
    if (multiboot.multibootTable.mods_addr == 0) {
        return 0;
    }

    return @min(
        @as(usize, @intCast(multiboot.multibootTable.mods_count)),
        arch.MAX_BOOT_MODULES,
    );
}

fn getMultibootModules() linksection(boot_text_section) [*]const MultibootModule {
    return @ptrFromInt(multiboot.multibootTable.mods_addr);
}

fn convertMultibootModule(multiboot_module: MultibootModule) linksection(boot_text_section) arch.BootModule {
    return .{
        .physical_start = multiboot_module.mod_start,
        .physical_end = multiboot_module.mod_end,
    };
}
