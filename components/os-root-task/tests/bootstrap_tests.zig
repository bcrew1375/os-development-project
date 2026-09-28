const abi = @import("abi");
const boot_modules = @import("boot_modules");
const memory_management = @import("memory_management");
const std = @import("std");

const valid_boot_modules = @import("support/boot_fixtures.zig").valid_boot_modules;
const bootstrap_memory = memory_management.bootstrap;

test "bootstrap memory validates capabilities ordering overlap and bounds" {
    const valid_capability = abi.capability.makeCapabilityHandle(1, 1);
    const valid = [_]abi.boot_info.PhysicalMemoryInfo{
        .{
            .physical_start = 0x1000,
            .size = 0x2000,
            .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            .capability = valid_capability,
        },
        .{
            .physical_start = 0x4000,
            .size = 0x1000,
            .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            .capability = abi.capability.makeCapabilityHandle(2, 1),
        },
    };
    try bootstrap_memory.validate(&valid);

    var invalid = valid;
    invalid[0].capability = abi.capability.INVALID_CAPABILITY;
    try std.testing.expectError(error.InvalidCapability, bootstrap_memory.validate(&invalid));
    invalid = valid;
    invalid[0].attributes = abi.boot_info.PHYSICAL_MEMORY_DEVICE;
    try std.testing.expectError(error.UnsupportedAttributes, bootstrap_memory.validate(&invalid));
    invalid = valid;
    invalid[1].physical_start = 0x2000;
    try std.testing.expectError(error.OverlappingRange, bootstrap_memory.validate(&invalid));
    invalid = valid;
    invalid[1].physical_start = 0;
    try std.testing.expectError(error.OutOfOrderRange, bootstrap_memory.validate(&invalid));
    invalid = valid;
    invalid[0].size = 1;
    try std.testing.expectError(error.UnalignedRange, bootstrap_memory.validate(&invalid));
}

test "boot module validation rejects missing malformed and overlapping mappings" {
    try boot_modules.validate(&valid_boot_modules);

    try std.testing.expectError(error.MissingRootModule, boot_modules.validate(&.{}));

    var invalid = valid_boot_modules;
    invalid[0].size = 0;
    try std.testing.expectError(error.EmptyModule, boot_modules.validate(&invalid));

    invalid = valid_boot_modules;
    invalid[0].physical_start = std.math.maxInt(u64);
    invalid[0].size = 2;
    try std.testing.expectError(error.PhysicalRangeOverflow, boot_modules.validate(&invalid));

    invalid = valid_boot_modules;
    invalid[1].virtual_start = 0;
    try std.testing.expectError(error.MissingVirtualMapping, boot_modules.validate(&invalid));

    const overlapping = [_]abi.boot_info.BootModuleInfo{
        valid_boot_modules[0],
        valid_boot_modules[1],
        .{
            .physical_start = 0x40_0000,
            .virtual_start = valid_boot_modules[1].virtual_start + 0x800,
            .size = 0x1000,
        },
    };
    try std.testing.expectError(error.OverlappingVirtualRange, boot_modules.validate(&overlapping));
}
