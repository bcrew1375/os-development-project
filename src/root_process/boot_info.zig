//! Boot-info serialization and physical-memory capability delegation.
//!
//! Creating the delegated capabilities transfers ownership to the root process:
//! once `collectBootInfoBlob` installs one in the capability table it is owned by
//! that table, and only uncommitted capabilities are destroyed on rollback.

const arch = @import("arch");
const abi = @import("abi");
const kernel_common = @import("kernel_common");
const std = @import("std");

const boot_modules = @import("boot_modules.zig");
const layout = @import("layout.zig");
const user_memory = @import("user_memory.zig");

const MappedBootModules = boot_modules.MappedBootModules;
const RootProcessLayout = layout.RootProcessLayout;
const physical_memory_authority = kernel_common.memory_management.physical_memory_authority;
const physical_memory_bootstrap = kernel_common.memory_management.physical_memory_bootstrap;
const physical_ranges = kernel_common.memory_management.physical_ranges;
const vmm = kernel_common.memory_management.virtual_memory;

const BootInfoBlob = extern struct {
    header: abi.boot_info.BootInfo,
    modules: [abi.boot_info.MAX_BOOT_MODULES]abi.boot_info.BootModuleInfo,
    physical_memory: [abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS]abi.boot_info.PhysicalMemoryInfo,
};

pub const DelegatedBootInfo = struct {
    capabilities: [abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS]abi.capability.CapabilityHandle =
        [_]abi.capability.CapabilityHandle{abi.capability.INVALID_CAPABILITY} **
        abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS,
    capability_count: usize = 0,
};

pub fn mapAndWriteBootInfoPage(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    mapped_modules: MappedBootModules,
) !DelegatedBootInfo {
    try vmm.mapBootstrapContiguousInAddressSpace(
        page_table_root,
        address_space,
        RootProcessLayout.boot_info_start,
        RootProcessLayout.boot_info_end,
        user_memory.readWriteUserPagePermissions,
    );

    var delegated_boot_info = DelegatedBootInfo{};
    errdefer rollbackDelegatedBootInfo(delegated_boot_info);
    const blob = try collectBootInfoBlob(&delegated_boot_info, mapped_modules);
    try user_memory.copyIntoUserSpace(page_table_root, RootProcessLayout.boot_info_start, std.mem.asBytes(&blob));
    return delegated_boot_info;
}

pub fn rollbackDelegatedBootInfo(delegated_boot_info: DelegatedBootInfo) void {
    var capability_count = delegated_boot_info.capability_count;
    while (capability_count > 0) {
        capability_count -= 1;
        kernel_common.capability.destroyUntypedMemoryCapability(
            kernel_common.process.ROOT_PROCESS_HANDLE,
            delegated_boot_info.capabilities[capability_count],
        ) catch {};
    }
}

fn collectBootInfoBlob(
    delegated_boot_info: *DelegatedBootInfo,
    mapped_modules: MappedBootModules,
) !BootInfoBlob {
    var blob = BootInfoBlob{
        .header = .{
            .magic = abi.boot_info.BOOT_INFO_MAGIC,
            .version = abi.boot_info.BOOT_INFO_VERSION,
            .module_count = @intCast(mapped_modules.descriptor_count),
            .modules_address = RootProcessLayout.boot_info_start + @offsetOf(BootInfoBlob, "modules"),
            .physical_memory_count = 0,
            .physical_memory_address = RootProcessLayout.boot_info_start + @offsetOf(BootInfoBlob, "physical_memory"),
        },
        .modules = mapped_modules.descriptors,
        .physical_memory = [_]abi.boot_info.PhysicalMemoryInfo{.{
            .physical_start = 0,
            .size = 0,
            .attributes = 0,
            .capability = abi.capability.INVALID_CAPABILITY,
        }} ** abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS,
    };

    const normalized = try physical_memory_bootstrap.normalizeArchitectureMemory();
    if (normalized.allocatable.len > abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS) {
        return physical_ranges.Error.OutputTooSmall;
    }
    if (normalized.allocatable.len > kernel_common.capability.availableCount()) {
        return kernel_common.capability.CapabilityError.OutOfCapabilities;
    }
    if (normalized.allocatable.len > physical_memory_authority.availableCount()) {
        return physical_memory_authority.Error.OutOfAuthorities;
    }

    for (normalized.allocatable, 0..) |range, range_index| {
        const capability = try kernel_common.capability.createUntypedMemoryCapability(
            kernel_common.process.ROOT_PROCESS_HANDLE,
            range.start,
            range.size(),
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            @intCast(arch.mmu.getPageSize()),
        );
        delegated_boot_info.capabilities[delegated_boot_info.capability_count] = capability;
        delegated_boot_info.capability_count += 1;
        blob.physical_memory[range_index] = .{
            .physical_start = range.start,
            .size = range.size(),
            .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            .capability = capability,
        };
    }
    blob.header.physical_memory_count = @intCast(normalized.allocatable.len);

    return blob;
}
