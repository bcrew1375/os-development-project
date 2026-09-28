const abi = @import("abi");

pub const valid_physical_memory = [_]abi.boot_info.PhysicalMemoryInfo{.{
    .physical_start = 0x1000,
    .size = 0x4000,
    .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
    .capability = abi.capability.makeCapabilityHandle(1, 1),
}};

pub const valid_boot_modules = [_]abi.boot_info.BootModuleInfo{
    .{
        .physical_start = 0x20_0000,
        .virtual_start = 0,
        .size = 0x1000,
    },
    .{
        .physical_start = 0x30_0000,
        .virtual_start = 0x0400_0000,
        .size = 0x1000,
    },
    .{
        .physical_start = 0x40_0000,
        .virtual_start = 0x0400_1000,
        .size = 0x1000,
    },
};

pub fn validBootInfo() abi.boot_info.BootInfo {
    return .{
        .magic = abi.boot_info.BOOT_INFO_MAGIC,
        .version = abi.boot_info.BOOT_INFO_VERSION,
        .module_count = valid_boot_modules.len,
        .modules_address = 0,
        .physical_memory_count = valid_physical_memory.len,
        .physical_memory_address = 0,
    };
}

pub fn physicalDescriptor(
    physical_start: u64,
    size: u64,
    capability_slot: u32,
) abi.boot_info.PhysicalMemoryInfo {
    return .{
        .physical_start = physical_start,
        .size = size,
        .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        .capability = abi.capability.makeCapabilityHandle(capability_slot, 1),
    };
}
