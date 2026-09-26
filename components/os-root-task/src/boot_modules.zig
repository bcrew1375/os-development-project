//! Validation and access helpers for boot modules delegated to the root task.

const abi = @import("abi");
const std = @import("std");

pub const Error = error{
    TooManyModules,
    MissingModuleArray,
    MisalignedModuleArray,
    ModuleArrayOverflow,
    MissingRootModule,
    EmptyModule,
    PhysicalRangeOverflow,
    MissingVirtualMapping,
    VirtualRangeOverflow,
    OverlappingVirtualRange,
};

pub fn descriptors(
    boot_info: *const abi.boot_info.BootInfo,
) Error![]const abi.boot_info.BootModuleInfo {
    const count: usize = @intCast(boot_info.module_count);
    if (count > abi.boot_info.MAX_BOOT_MODULES) return Error.TooManyModules;
    if (count == 0) return Error.MissingRootModule;
    if (boot_info.modules_address == 0) return Error.MissingModuleArray;
    if (boot_info.modules_address % @alignOf(abi.boot_info.BootModuleInfo) != 0) {
        return Error.MisalignedModuleArray;
    }

    const byte_count = std.math.mul(
        usize,
        count,
        @sizeOf(abi.boot_info.BootModuleInfo),
    ) catch return Error.ModuleArrayOverflow;
    const start: usize = @intCast(boot_info.modules_address);
    _ = std.math.add(usize, start, byte_count) catch return Error.ModuleArrayOverflow;
    const descriptor_pointer: [*]const abi.boot_info.BootModuleInfo = @ptrFromInt(start);
    return descriptor_pointer[0..count];
}

pub fn validate(module_descriptors: []const abi.boot_info.BootModuleInfo) Error!void {
    if (module_descriptors.len > abi.boot_info.MAX_BOOT_MODULES) return Error.TooManyModules;
    if (module_descriptors.len == 0) return Error.MissingRootModule;

    var previous_virtual_end: u64 = 0;
    for (module_descriptors, 0..) |module, index| {
        if (module.size == 0) return Error.EmptyModule;
        _ = std.math.add(u64, module.physical_start, module.size) catch {
            return Error.PhysicalRangeOverflow;
        };

        if (index == 0) {
            if (module.virtual_start != 0) return Error.OverlappingVirtualRange;
            continue;
        }
        if (module.virtual_start == 0) return Error.MissingVirtualMapping;
        const virtual_end = std.math.add(u64, module.virtual_start, module.size) catch {
            return Error.VirtualRangeOverflow;
        };
        if (index > 1 and module.virtual_start < previous_virtual_end) {
            return Error.OverlappingVirtualRange;
        }
        previous_virtual_end = virtual_end;
    }
}

pub fn validateBootInfo(boot_info: *const abi.boot_info.BootInfo) Error!void {
    try validate(try descriptors(boot_info));
}
