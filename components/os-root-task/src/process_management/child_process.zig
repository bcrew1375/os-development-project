//! Transactional construction and ownership of root-task-created child processes.

const abi = @import("abi");
const builtin = @import("builtin");
const memory_management = @import("memory_management");
const process_management = @import("process_management");
const shared = @import("shared");
const std = @import("std");
const elf = shared.executable.elf;
const load_planning = @import("child_process/load_plan.zig");
const startup_abi = @import("child_process/startup_abi.zig");
const transaction = @import("child_process/Transaction.zig");
const MemoryObject = memory_management.operations.MemoryObject;
const AddressSpace = memory_management.operations.AddressSpace;

pub const PAGE_SIZE: usize = 4096;
pub const MAX_LOAD_SEGMENTS: usize = 8;
pub const LOADER_WINDOW_START: usize = 0x0200_0000;
pub const LOADER_WINDOW_END: usize = 0x0400_0000;
pub const STACK_TOP: usize = 0x00C0_0000;
pub const STACK_SIZE: usize = 0x0001_0000;
pub const STACK_START: usize = STACK_TOP - STACK_SIZE;
pub const MAX_DELEGATED_CAPABILITIES: usize = 4;

pub const Error = elf.ElfLoadError || memory_management.PhysicalRangeAllocator.Error ||
    memory_management.operations.Error || process_management.Error || error{
    WrongElfClass,
    TooManyLoadSegments,
    AddressOutOfRange,
    SegmentRangeOverflow,
    EmptySegmentPermissions,
    EntryPointNotExecutable,
    SegmentOverlapsStack,
    PageAlignedSegmentOverlap,
    InvalidConfiguration,
    LoaderWindowExhausted,
    MappedAddressUnavailable,
    CleanupFailed,
    TooManyDelegatedCapabilities,
};

pub const PlannedSegment = load_planning.PlannedSegment;
pub const LoadPlan = load_planning.LoadPlan(MAX_LOAD_SEGMENTS);
pub const ChildProcess = transaction.Transaction(
    Error,
    MAX_LOAD_SEGMENTS + 1,
    MAX_DELEGATED_CAPABILITIES,
);
const OwnedMapping = ChildProcess.OwnedMapping;

pub fn plan(image: []const u8) Error!LoadPlan {
    return load_planning.plan(
        image,
        PAGE_SIZE,
        MAX_LOAD_SEGMENTS,
        STACK_START,
        STACK_TOP,
    );
}

pub fn createAndStart(
    comptime Environment: type,
    physical_allocator: *memory_management.PhysicalRangeAllocator,
    root_address_space: AddressSpace,
    image: []const u8,
    startup: abi.process.ChildStartup,
    request_endpoint: ?abi.capability.CapabilityHandle,
    reply_endpoint: ?abi.capability.CapabilityHandle,
) Error!ChildProcess {
    return createAndStartManaged(
        Environment,
        physical_allocator,
        root_address_space,
        image,
        startup,
        request_endpoint,
        reply_endpoint,
        null,
        null,
    );
}

pub fn createAndStartManaged(
    comptime Environment: type,
    physical_allocator: *memory_management.PhysicalRangeAllocator,
    root_address_space: AddressSpace,
    image: []const u8,
    startup: abi.process.ChildStartup,
    request_endpoint: ?abi.capability.CapabilityHandle,
    reply_endpoint: ?abi.capability.CapabilityHandle,
    parent_endpoint: ?abi.capability.CapabilityHandle,
    lifecycle_endpoint: ?abi.capability.CapabilityHandle,
) Error!ChildProcess {
    const manager = memory_management.operations.MemoryManager(Environment);
    const process_manager = process_management.ProcessManager(Environment);
    const load_plan = try plan(image);
    var child = ChildProcess{};
    errdefer child.destroy(Environment, physical_allocator, root_address_space) catch {};

    child.capability_space = try process_manager.createCapabilitySpace();
    child.address_space = try manager.createAddressSpace();
    var child_startup = startup;
    if (request_endpoint) |endpoint_capability| {
        const child_capability = try process_manager.installCapability(
            child.capability_space.?,
            endpoint_capability,
            .{ .receive = true },
        );
        try child.trackDelegatedCapability(child_capability);
        child_startup.request_endpoint_capability = child_capability;
    }
    if (reply_endpoint) |endpoint_capability| {
        const child_capability = try process_manager.installCapability(
            child.capability_space.?,
            endpoint_capability,
            .{ .send = true },
        );
        try child.trackDelegatedCapability(child_capability);
        child_startup.reply_endpoint_capability = child_capability;
    }
    if (parent_endpoint) |endpoint_capability| {
        const child_capability = try process_manager.installCapability(
            child.capability_space.?,
            endpoint_capability,
            .{ .send = true, .receive = true },
        );
        try child.trackDelegatedCapability(child_capability);
        child_startup.parent_endpoint_capability = child_capability;
    }

    var loader_cursor = LOADER_WINDOW_START;
    for (load_plan.segments[0..load_plan.segment_count]) |segment| {
        loader_cursor = try addMapping(
            Environment,
            &child,
            physical_allocator,
            root_address_space,
            loader_cursor,
            segment.virtual_start,
            segment.mapping_size,
            segment.permissions,
        );
        const mapping = child.mappings[child.mapping_count - 1];
        const mapped = mappedBytes(Environment, mapping.loader_virtual_start, mapping.size) orelse
            return Error.MappedAddressUnavailable;
        const destination_offset = std.math.cast(usize, segment.source.virtual_address) orelse
            return Error.AddressOutOfRange;
        const offset = destination_offset - segment.virtual_start;
        const file_end = std.math.add(usize, segment.source.file_offset, segment.source.file_size) catch
            return Error.SegmentRangeOverflow;
        @memcpy(mapped[offset..][0..segment.source.file_size], image[segment.source.file_offset..file_end]);
    }

    _ = try addMapping(
        Environment,
        &child,
        physical_allocator,
        root_address_space,
        loader_cursor,
        STACK_START,
        STACK_SIZE,
        memory_management.operations.MAP_READ | memory_management.operations.MAP_WRITE,
    );
    const stack_mapping = child.mappings[child.mapping_count - 1];
    const initial_stack_pointer = try writeInitialStack(Environment, stack_mapping, child_startup);
    try unmapLoaderAliases(Environment, &child, root_address_space);

    if (child_startup.mode == .service_echo) {
        if (child_startup.request_endpoint_capability == abi.capability.INVALID_CAPABILITY or
            child_startup.reply_endpoint_capability == abi.capability.INVALID_CAPABILITY or
            child_startup.parent_endpoint_capability != abi.capability.INVALID_CAPABILITY or
            (lifecycle_endpoint orelse abi.capability.INVALID_CAPABILITY) !=
                abi.capability.INVALID_CAPABILITY or
            child_startup.lifecycle_token != abi.process.INVALID_LIFECYCLE_TOKEN)
        {
            try child.destroy(Environment, physical_allocator, root_address_space);
            return error.InvalidConfiguration;
        }
    }
    child.thread = try process_manager.createThread();
    const configuration = abi.process.ThreadConfiguration{
        .capability_space = child.capability_space.?.capability,
        .address_space = child.address_space.?.capability,
        .entry_point = load_plan.entry_point,
        .stack_pointer = initial_stack_pointer,
        .argument = startup_abi.startupAddress(STACK_TOP),
        .lifecycle_endpoint = lifecycle_endpoint orelse abi.capability.INVALID_CAPABILITY,
        .lifecycle_token = child_startup.lifecycle_token,
    };
    try process_manager.configureThread(child.thread.?, &configuration);
    try process_manager.startThread(child.thread.?);
    child.started = true;
    return child;
}

fn unmapLoaderAliases(
    comptime Environment: type,
    child: *ChildProcess,
    root_address_space: AddressSpace,
) Error!void {
    const manager = memory_management.operations.MemoryManager(Environment);
    var index = child.mapping_count;
    while (index > 0) {
        index -= 1;
        var mapping = &child.mappings[index];
        try manager.unmapAddressSpace(
            root_address_space,
            mapping.loader_virtual_start,
            mapping.size,
        );
        mapping.loader_mapped = false;
    }
}

fn addMapping(
    comptime Environment: type,
    child: *ChildProcess,
    physical_allocator: *memory_management.PhysicalRangeAllocator,
    root_address_space: AddressSpace,
    loader_virtual_start: usize,
    child_virtual_start: usize,
    size: usize,
    child_permissions: u32,
) Error!usize {
    const loader_end = std.math.add(usize, loader_virtual_start, size) catch
        return Error.LoaderWindowExhausted;
    if (loader_end > LOADER_WINDOW_END) return Error.LoaderWindowExhausted;
    const allocation = try physical_allocator.allocate(size, PAGE_SIZE);
    errdefer physical_allocator.free(allocation) catch {};
    const range = try physical_allocator.resolve(allocation);
    const page_count = std.math.cast(u32, size / PAGE_SIZE) orelse return Error.AddressOutOfRange;
    const manager = memory_management.operations.MemoryManager(Environment);
    const frame = try manager.retypePhysicalFrames(
        .{ .capability = range.parent_capability },
        range.offset,
        page_count,
        .{ .manage = true, .read = true, .write = true, .execute = true },
    );
    const memory_object = manager.createMemoryObject(frame) catch |err| {
        manager.deletePhysicalMemory(frame) catch return Error.CleanupFailed;
        return err;
    };
    errdefer manager.destroyMemoryObject(memory_object) catch {};
    try manager.mapMemoryObject(child.address_space.?, memory_object, child_virtual_start, size, child_permissions);
    errdefer manager.unmapAddressSpace(child.address_space.?, child_virtual_start, size) catch {};
    try manager.mapMemoryObject(
        root_address_space,
        memory_object,
        loader_virtual_start,
        size,
        memory_management.operations.MAP_READ | memory_management.operations.MAP_WRITE,
    );
    child.mappings[child.mapping_count] = .{
        .child_virtual_start = child_virtual_start,
        .loader_virtual_start = loader_virtual_start,
        .size = size,
        .memory_object = memory_object,
        .allocation = allocation,
    };
    child.mapping_count += 1;
    return loader_end;
}

fn writeInitialStack(
    comptime Environment: type,
    mapping: OwnedMapping,
    startup: abi.process.ChildStartup,
) Error!usize {
    const bytes = mappedBytes(Environment, mapping.loader_virtual_start, mapping.size) orelse
        return Error.MappedAddressUnavailable;
    return startup_abi.writeInitialStack(bytes, startup, STACK_START, STACK_TOP);
}

fn mappedBytes(comptime Environment: type, virtual_start: usize, size: usize) ?[]u8 {
    const address = if (@hasDecl(Environment, "mappedMemoryAddress"))
        Environment.mappedMemoryAddress(virtual_start, size) orelse return null
    else
        virtual_start;
    const pointer: [*]u8 = @ptrFromInt(address);
    return pointer[0..size];
}
