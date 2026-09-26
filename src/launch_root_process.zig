const arch = @import("arch");
const kernel_common = @import("kernel_common");
const shared = @import("shared");
const std = @import("std");
const abi = @import("abi");
const builtin = @import("builtin");

const vmm = kernel_common.memory_management.virtual_memory;
const physical_memory_authority = kernel_common.memory_management.physical_memory_authority;
const physical_memory_bootstrap = kernel_common.memory_management.physical_memory_bootstrap;
const physical_ranges = kernel_common.memory_management.physical_ranges;
const elf_loader = shared.executable.elf;

const ROOT_PROCESS_BOOT_MODULE_INDEX = 0;
var root_thread_handle: ?kernel_common.process.thread.Handle = null;

pub const RootProcessLayout = struct {
    pub const boot_info_start: u64 = 0x0010_0000;
    pub const boot_info_size: u64 = 0x1000;
    pub const boot_info_end: u64 = boot_info_start + boot_info_size;

    pub const initial_stack_committed_size: u64 = 0x0001_0000;
    pub const initial_stack_top: u64 = 0x00C0_0000;
    pub const initial_stack_start: u64 = initial_stack_top - initial_stack_committed_size;

    pub const boot_module_window_start: u64 = 0x0400_0000;
    pub const boot_module_window_end: u64 = 0x0800_0000;
};

const RootProcessLaunchError = error{
    RootProcessModuleMissing,
    InvalidBootModuleRange,
    RootAddressSpaceMappingMissing,
    BootModuleWindowExhausted,
} || elf_loader.ElfLoadError || arch.MmuError;

const BootInfoBlob = extern struct {
    header: abi.boot_info.BootInfo,
    modules: [abi.boot_info.MAX_BOOT_MODULES]abi.boot_info.BootModuleInfo,
    physical_memory: [abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS]abi.boot_info.PhysicalMemoryInfo,
};

const DelegatedBootInfo = struct {
    capabilities: [abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS]abi.capability.CapabilityHandle =
        [_]abi.capability.CapabilityHandle{abi.capability.INVALID_CAPABILITY} **
        abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS,
    capability_count: usize = 0,
};
const MappedBootModules = struct {
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

pub const PreparedRootProcess = struct {
    address_space_handle: kernel_common.process.AddressSpaceHandle,
    address_space_capability: abi.capability.CapabilityHandle,
    address_space_root: arch.AddressSpaceRoot,
    entry_point: usize,
    initial_stack_pointer: usize,
    thread_handle: kernel_common.process.thread.Handle,
};

pub fn launchRootProcess() !noreturn {
    const prepared_root_process = try prepareRootProcess();
    enterPreparedRootProcess(prepared_root_process);
}

pub fn prepareRootProcess() !PreparedRootProcess {
    const page_table_root = try arch.mmu.createAddressSpaceRoot();
    const address_space_capability = try kernel_common.capability.registerAddressSpaceRootCapability(
        kernel_common.process.ROOT_PROCESS_HANDLE,
        page_table_root,
    );
    errdefer kernel_common.capability.destroyAddressSpaceCapability(
        kernel_common.process.ROOT_PROCESS_HANDLE,
        address_space_capability,
    ) catch {};
    const address_space_handle = try kernel_common.capability.resolveAddressSpace(
        kernel_common.process.ROOT_PROCESS_HANDLE,
        address_space_capability,
        .{ .manage = true },
    );
    const address_space = try kernel_common.process.getAddressSpace(address_space_handle);
    activateAsCurrentBootstrapAddressSpace(address_space);

    const root_module = try getRootProcessModule();
    const entry_point = try loadRootProcessElf(page_table_root, address_space, root_module);

    try mapInitialUserStack(page_table_root, address_space);
    const mapped_modules = try mapNonRootBootModules(page_table_root, address_space);
    errdefer rollbackMappedBootModules(page_table_root, address_space, mapped_modules);
    const delegated_boot_info = try mapAndWriteBootInfoPage(
        page_table_root,
        address_space,
        mapped_modules,
    );
    errdefer rollbackDelegatedBootInfo(delegated_boot_info);
    const initial_stack_pointer = try writeInitialCallFrame(
        page_table_root,
        RootProcessLayout.initial_stack_top,
        RootProcessLayout.boot_info_start,
    );
    const thread_handle = try kernel_common.process.createThread(
        kernel_common.process.ROOT_PROCESS_HANDLE,
    );
    errdefer kernel_common.process.thread.destroy(thread_handle) catch {};
    try kernel_common.process.configureThread(thread_handle, .{
        .capability_space_handle = kernel_common.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space_handle,
        .entry_point = entry_point,
        .stack_pointer = initial_stack_pointer,
        .argument = RootProcessLayout.boot_info_start,
    });

    return .{
        .address_space_handle = address_space_handle,
        .address_space_capability = address_space_capability,
        .address_space_root = page_table_root,
        .entry_point = entry_point,
        .initial_stack_pointer = initial_stack_pointer,
        .thread_handle = thread_handle,
    };
}

pub fn enterPreparedRootProcess(prepared_root_process: PreparedRootProcess) noreturn {
    root_thread_handle = prepared_root_process.thread_handle;
    kernel_common.process.scheduler.initialize(prepared_root_process.address_space_root) catch {
        @panic("failed to initialize scheduler");
    };
    kernel_common.process.scheduler.makeReady(prepared_root_process.thread_handle) catch {
        @panic("failed to enqueue prepared root thread");
    };
    kernel_common.process.scheduler.start();
}

pub fn isRootThreadForSmoke() bool {
    const expected = root_thread_handle orelse return false;
    const current = kernel_common.process.execution_context.current() catch return false;
    return current.thread_handle == expected;
}

/// `vmm`'s bootstrap-mapping calls (mapBootstrapContiguousInAddressSpace,
/// protectInAddressSpace, ...) act on whichever address space was last
/// activated here, rather than taking it as an explicit parameter.
fn activateAsCurrentBootstrapAddressSpace(address_space: *vmm.AddressSpace) void {
    vmm.setAddressSpace(address_space);
}

// --- boot-info page ---------------------------------------------------

fn mapAndWriteBootInfoPage(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    mapped_modules: MappedBootModules,
) !DelegatedBootInfo {
    try vmm.mapBootstrapContiguousInAddressSpace(
        page_table_root,
        address_space,
        RootProcessLayout.boot_info_start,
        RootProcessLayout.boot_info_end,
        readWriteUserPagePermissions,
    );

    var delegated_boot_info = DelegatedBootInfo{};
    errdefer rollbackDelegatedBootInfo(delegated_boot_info);
    const blob = try collectBootInfoBlob(&delegated_boot_info, mapped_modules);
    try copyIntoUserSpace(page_table_root, RootProcessLayout.boot_info_start, std.mem.asBytes(&blob));
    return delegated_boot_info;
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

fn rollbackDelegatedBootInfo(delegated_boot_info: DelegatedBootInfo) void {
    var capability_count = delegated_boot_info.capability_count;
    while (capability_count > 0) {
        capability_count -= 1;
        kernel_common.capability.destroyUntypedMemoryCapability(
            kernel_common.process.ROOT_PROCESS_HANDLE,
            delegated_boot_info.capabilities[capability_count],
        ) catch {};
    }
}

// --- initial user stack -------------------------------------------------

fn mapInitialUserStack(page_table_root: arch.AddressSpaceRoot, address_space: *vmm.AddressSpace) !void {
    try vmm.mapBootstrapContiguousInAddressSpace(
        page_table_root,
        address_space,
        RootProcessLayout.initial_stack_start,
        RootProcessLayout.initial_stack_top,
        readWriteUserPagePermissions,
    );
}

/// Constructs the target C ABI's function-entry stack shape. x86-32 carries
/// the boot-info pointer on the stack; x86-64 carries it in RDI.
fn writeInitialCallFrame(
    page_table_root: arch.AddressSpaceRoot,
    stack_top: u64,
    boot_info_address: u64,
) !usize {
    var stack_pointer = @as(usize, @intCast(stack_top));

    switch (builtin.cpu.arch) {
        .x86 => {
            stack_pointer -= 3 * @sizeOf(u32);
            stack_pointer -= @sizeOf(u32);
            const boot_info_argument: u32 = @intCast(boot_info_address);
            try copyIntoUserSpace(
                page_table_root,
                stack_pointer,
                std.mem.asBytes(&boot_info_argument),
            );

            stack_pointer -= @sizeOf(u32);
            const fake_return_address: u32 = 0;
            try copyIntoUserSpace(
                page_table_root,
                stack_pointer,
                std.mem.asBytes(&fake_return_address),
            );
        },
        .x86_64 => {
            stack_pointer -= @sizeOf(u64);
            const fake_return_address: u64 = 0;
            try copyIntoUserSpace(
                page_table_root,
                stack_pointer,
                std.mem.asBytes(&fake_return_address),
            );
        },
        else => @compileError("unsupported root-process entry ABI"),
    }

    return stack_pointer;
}

// --- ELF loading ----------------------------------------------------------

fn loadRootProcessElf(page_table_root: arch.AddressSpaceRoot, address_space: *vmm.AddressSpace, root_module: arch.BootModule) !usize {
    const image = try getBootModuleBytes(root_module);
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const loadable_image = try elf_loader.parseLoadableImage(image, page_size);

    for (0..loadable_image.segment_count) |segment_index| {
        try loadRootProcessSegment(page_table_root, address_space, image, try elf_loader.getLoadableSegment(image, segment_index));
    }

    return @intCast(loadable_image.entry_point);
}

fn loadRootProcessSegment(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    image: []const u8,
    segment: elf_loader.LoadableSegment,
) !void {
    const mapping_range = pageAlignedSegmentRange(segment);

    try mapSegmentWriteableForLoading(page_table_root, address_space, mapping_range, segment);
    try writeSegmentContents(page_table_root, image, segment);
    try restoreSegmentPermissions(page_table_root, address_space, mapping_range, finalUserSegmentPermissions(segment));
}

const AddressRange = struct { start: u64, end: u64 };

fn pageAlignedSegmentRange(segment: elf_loader.LoadableSegment) AddressRange {
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const virtual_end = segment.virtual_address + segment.memory_size;
    return .{
        .start = std.mem.alignBackward(u64, segment.virtual_address, page_size),
        .end = std.mem.alignForward(u64, virtual_end, page_size),
    };
}

fn finalUserSegmentPermissions(segment: elf_loader.LoadableSegment) vmm.MemoryPermissions {
    return .{
        .readable = segment.permissions.readable,
        .writeable = segment.permissions.writeable,
        .executable = segment.permissions.executable,
        .user_accessible = true,
    };
}

/// Maps the segment writeable regardless of its final permissions, since
/// `writeSegmentContents` needs write access to populate it. Permissions are
/// locked down to their real values afterward by `restoreSegmentPermissions`.
fn mapSegmentWriteableForLoading(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    range: AddressRange,
    segment: elf_loader.LoadableSegment,
) !void {
    try vmm.mapBootstrapContiguousInAddressSpace(page_table_root, address_space, range.start, range.end, .{
        .readable = segment.permissions.readable,
        .writeable = true,
        .executable = segment.permissions.executable,
        .user_accessible = true,
    });
}

fn writeSegmentContents(page_table_root: arch.AddressSpaceRoot, image: []const u8, segment: elf_loader.LoadableSegment) !void {
    const file_end = try std.math.add(usize, segment.file_offset, segment.file_size);
    try copyIntoUserSpace(page_table_root, segment.virtual_address, image[segment.file_offset..file_end]);

    const bss_start = segment.virtual_address + segment.file_size;
    const bss_size = segment.memory_size - segment.file_size;
    try zeroUserSpace(page_table_root, bss_start, bss_size);
}

fn restoreSegmentPermissions(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    range: AddressRange,
    permissions: vmm.MemoryPermissions,
) !void {
    try vmm.protectInAddressSpace(page_table_root, address_space, range.start, range.end, permissions);
}

// --- copying bytes into the new address space ------------------------------

const readWriteUserPagePermissions = vmm.MemoryPermissions{
    .readable = true,
    .writeable = true,
    .executable = false,
    .user_accessible = true,
};

fn copyIntoUserSpace(page_table_root: arch.AddressSpaceRoot, virtual_address: u64, source: []const u8) !void {
    var address = virtual_address;
    var remaining = source;
    while (remaining.len > 0) {
        const destination = try userSpacePageSlice(page_table_root, address, remaining.len);
        @memcpy(destination, remaining[0..destination.len]);
        address += destination.len;
        remaining = remaining[destination.len..];
    }
}

fn zeroUserSpace(page_table_root: arch.AddressSpaceRoot, virtual_address: u64, byte_count: u64) !void {
    var address = virtual_address;
    var remaining_len: usize = @intCast(byte_count);
    while (remaining_len > 0) {
        const destination = try userSpacePageSlice(page_table_root, address, remaining_len);
        @memset(destination, 0);
        address += destination.len;
        remaining_len -= destination.len;
    }
}

/// The direct-mapped bytes of `virtual_address`'s physical page, truncated
/// to `max_len` and to the end of that page (a direct-map pointer is only
/// valid within a single physical page).
fn userSpacePageSlice(page_table_root: arch.AddressSpaceRoot, virtual_address: u64, max_len: usize) ![]u8 {
    const page_size = arch.mmu.getPageSize();
    const address: usize = @intCast(virtual_address);
    const page_offset = address & (page_size - 1);
    const page_remaining = page_size - page_offset;

    const page = try directMapPagePointer(page_table_root, address);
    return page[0..@min(page_remaining, max_len)];
}

fn directMapPagePointer(page_table_root: arch.AddressSpaceRoot, virtual_address: usize) ![*]u8 {
    const physical_address = arch.mmu.getPhysicalAddressInAddressSpace(page_table_root, virtual_address) orelse {
        return RootProcessLaunchError.RootAddressSpaceMappingMissing;
    };
    const direct_map_base: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    return @ptrFromInt(direct_map_base + physical_address);
}

// --- boot modules -----------------------------------------------------

fn getRootProcessModule() RootProcessLaunchError!arch.BootModule {
    return arch.boot.getBootModule(ROOT_PROCESS_BOOT_MODULE_INDEX) orelse RootProcessLaunchError.RootProcessModuleMissing;
}

fn validateBootModuleRange(boot_module: arch.BootModule) RootProcessLaunchError!void {
    if (boot_module.physical_start >= boot_module.physical_end) {
        return RootProcessLaunchError.InvalidBootModuleRange;
    }

    const direct_map_size = arch.mmu.getDirectMapMaxSize();
    if (boot_module.physical_start >= direct_map_size or
        boot_module.physical_end > direct_map_size)
    {
        return RootProcessLaunchError.InvalidBootModuleRange;
    }

    const direct_map_base: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    _ = std.math.add(usize, direct_map_base, boot_module.physical_start) catch {
        return RootProcessLaunchError.InvalidBootModuleRange;
    };
    _ = std.math.add(usize, direct_map_base, boot_module.physical_end - 1) catch {
        return RootProcessLaunchError.InvalidBootModuleRange;
    };
}

fn getBootModuleBytes(root_module: arch.BootModule) RootProcessLaunchError![]const u8 {
    try validateBootModuleRange(root_module);

    const module_size = root_module.physical_end - root_module.physical_start;
    const direct_map_base: usize = @intCast(arch.mmu.getDirectMapVirtualAddress());
    const module_virtual_start = direct_map_base + root_module.physical_start;
    return @as([*]const u8, @ptrFromInt(module_virtual_start))[0..module_size];
}

const readOnlyUserPagePermissions = vmm.MemoryPermissions{
    .readable = true,
    .writeable = false,
    .executable = false,
    .user_accessible = true,
};

fn mapNonRootBootModules(
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
            return RootProcessLaunchError.BootModuleWindowExhausted;
        };
        if (mapping_end > RootProcessLayout.boot_module_window_end) {
            return RootProcessLaunchError.BootModuleWindowExhausted;
        }

        try vmm.mapBackedObjectInAddressSpace(
            page_table_root,
            address_space,
            mapping_start,
            mapping_end,
            readOnlyUserPagePermissions,
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
fn rollbackMappedBootModules(
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
