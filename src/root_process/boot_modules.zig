//! Boot-module lookup and user-space mapping for the root process.

const arch = @import("arch");
const abi = @import("abi");
const kernel_common = @import("kernel_common");
const std = @import("std");

const errors = @import("errors.zig");
const layout = @import("layout.zig");
const user_memory = @import("user_memory.zig");

const RootProcessLayout = layout.RootProcessLayout;
const vmm = kernel_common.memory_management.virtual_memory;

const ROOT_PROCESS_BOOT_MODULE_INDEX = 0;

pub const MappedBootModules = struct {
    descriptors: [abi.boot_info.MAX_BOOT_MODULES]abi.boot_info.BootModuleInfo =
        [_]abi.boot_info.BootModuleInfo{.{
            .physical_start = 0,
            .virtual_start = 0,
            .size = 0,
        }} ** abi.boot_info.MAX_BOOT_MODULES,
    mapping_starts: [abi.boot_info.MAX_BOOT_MODULES]u64 =
        [_]u64{0} ** abi.boot_info.MAX_BOOT_MODULES,
    mapping_ends: [abi.boot_info.MAX_BOOT_MODULES]u64 =
        [_]u64{0} ** abi.boot_info.MAX_BOOT_MODULES,
    descriptor_count: usize = 0,
    mapping_count: usize = 0,
};

pub fn getRootProcessModule() errors.RootProcessLaunchError!arch.BootModule {
    return arch.boot.getBootModule(ROOT_PROCESS_BOOT_MODULE_INDEX) orelse errors.RootProcessLaunchError.RootProcessModuleMissing;
}

pub fn getBootModuleBytes(root_module: arch.BootModule) errors.RootProcessLaunchError![]const u8 {
    try validateBootModuleRange(root_module);

    const module_size = root_module.physical_end - root_module.physical_start;
    const direct_map_base: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    const module_virtual_start = direct_map_base + root_module.physical_start;
    return @as([*]const u8, @ptrFromInt(module_virtual_start))[0..module_size];
}

pub fn mapNonRootBootModules(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
) !MappedBootModules {
    var mapped = MappedBootModules{};
    errdefer rollbackMappedBootModules(page_table_root, address_space, mapped);

    const module_count = @min(arch.boot.getBootModuleCount(), abi.boot_info.MAX_BOOT_MODULES);
    mapped.descriptor_count = module_count;
    if (module_count == 0) return mapped;

    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    var next_virtual = RootProcessLayout.boot_module_window_start;

    for (0..module_count) |module_index| {
        const module = arch.boot.getBootModule(module_index).?;
        try validateBootModuleRange(module);

        const physical_start: u64 = @intCast(module.physical_start);
        const physical_end: u64 = @intCast(module.physical_end);
        const module_size = physical_end - physical_start;

        if (module_index == ROOT_PROCESS_BOOT_MODULE_INDEX) {
            mapped.descriptors[module_index] = .{
                .physical_start = physical_start,
                .virtual_start = 0,
                .size = module_size,
            };
            continue;
        }

        const page_offset = physical_start % page_size;
        const aligned_physical_start = physical_start - page_offset;
        const aligned_physical_end = std.mem.alignForward(u64, physical_end, page_size);
        const aligned_size = aligned_physical_end - aligned_physical_start;

        const mapping_start = next_virtual;
        const mapping_end = std.math.add(u64, mapping_start, aligned_size) catch {
            return errors.RootProcessLaunchError.BootModuleWindowExhausted;
        };
        if (mapping_end > RootProcessLayout.boot_module_window_end) {
            return errors.RootProcessLaunchError.BootModuleWindowExhausted;
        }

        try vmm.mapBackedObjectInAddressSpace(
            page_table_root,
            address_space,
            mapping_start,
            mapping_end,
            user_memory.readOnlyUserPagePermissions,
            abi.syscall.INVALID_HANDLE,
            0,
            aligned_physical_start,
        );

        mapped.mapping_starts[mapped.mapping_count] = mapping_start;
        mapped.mapping_ends[mapped.mapping_count] = mapping_end;
        mapped.mapping_count += 1;

        mapped.descriptors[module_index] = .{
            .physical_start = physical_start,
            .virtual_start = mapping_start + page_offset,
            .size = module_size,
        };
        next_virtual = mapping_end;
    }

    return mapped;
}

pub fn rollbackMappedBootModules(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    mapped: MappedBootModules,
) void {
    var count = mapped.mapping_count;
    while (count > 0) {
        count -= 1;
        vmm.unmapInAddressSpace(
            page_table_root,
            address_space,
            mapped.mapping_starts[count],
            mapped.mapping_ends[count],
        ) catch {};
    }
}

fn validateBootModuleRange(boot_module: arch.BootModule) errors.RootProcessLaunchError!void {
    if (boot_module.physical_start >= boot_module.physical_end) {
        return errors.RootProcessLaunchError.InvalidBootModuleRange;
    }

    const direct_map_size = arch.mmu.getDirectMapMaxSize();
    if (boot_module.physical_start >= direct_map_size or
        boot_module.physical_end > direct_map_size)
    {
        return errors.RootProcessLaunchError.InvalidBootModuleRange;
    }

    const direct_map_base: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    _ = std.math.add(usize, direct_map_base, boot_module.physical_start) catch {
        return errors.RootProcessLaunchError.InvalidBootModuleRange;
    };
    _ = std.math.add(usize, direct_map_base, boot_module.physical_end - 1) catch {
        return errors.RootProcessLaunchError.InvalidBootModuleRange;
    };
}
