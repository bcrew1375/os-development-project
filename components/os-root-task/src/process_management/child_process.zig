//! Transactional construction and ownership of root-task-created child processes.

const abi = @import("abi");
const builtin = @import("builtin");
const memory_management = @import("memory_management");
const process_management = @import("process_management");
const shared = @import("shared");
const std = @import("std");

const elf = shared.executable.elf;
const MemoryObject = memory_management.operations.MemoryObject;
const AddressSpace = memory_management.operations.AddressSpace;
const AllocationHandle = memory_management.PhysicalRangeAllocator.AllocationHandle;

pub const PAGE_SIZE: usize = 4096;
pub const MAX_LOAD_SEGMENTS: usize = 8;
pub const LOADER_WINDOW_START: usize = 0x0200_0000;
pub const LOADER_WINDOW_END: usize = 0x0400_0000;
pub const STACK_TOP: usize = 0x00C0_0000;
pub const STACK_SIZE: usize = 0x0001_0000;
pub const STACK_START: usize = STACK_TOP - STACK_SIZE;

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
    LoaderWindowExhausted,
    MappedAddressUnavailable,
    CleanupFailed,
};

pub const PlannedSegment = struct {
    source: elf.LoadableSegment,
    virtual_start: usize,
    mapping_size: usize,
    permissions: u32,
};

pub const LoadPlan = struct {
    entry_point: usize,
    segments: [MAX_LOAD_SEGMENTS]PlannedSegment = undefined,
    segment_count: usize = 0,
};

const OwnedMapping = struct {
    child_virtual_start: usize,
    loader_virtual_start: usize,
    size: usize,
    memory_object: MemoryObject,
    allocation: AllocationHandle,
    child_mapped: bool = true,
    loader_mapped: bool = true,
    object_owned: bool = true,
    allocation_owned: bool = true,
};

pub const ChildProcess = struct {
    capability_space: ?process_management.CapabilitySpace = null,
    address_space: ?AddressSpace = null,
    thread: ?process_management.Thread = null,
    mappings: [MAX_LOAD_SEGMENTS + 1]OwnedMapping = undefined,
    mapping_count: usize = 0,
    started: bool = false,

    pub fn destroy(
        self: *ChildProcess,
        comptime Environment: type,
        physical_allocator: *memory_management.PhysicalRangeAllocator,
        root_address_space: AddressSpace,
    ) Error!void {
        const manager = memory_management.operations.MemoryManager(Environment);
        const process_manager = process_management.ProcessManager(Environment);
        var cleanup_failed = false;

        if (self.thread) |thread| {
            process_manager.destroyThread(thread) catch {
                cleanup_failed = true;
                return Error.CleanupFailed;
            };
            self.thread = null;
        }

        var index = self.mapping_count;
        while (index > 0) {
            index -= 1;
            var mapping = &self.mappings[index];
            if (mapping.loader_mapped) {
                manager.unmapAddressSpace(
                    root_address_space,
                    mapping.loader_virtual_start,
                    mapping.size,
                ) catch {
                    cleanup_failed = true;
                    continue;
                };
                mapping.loader_mapped = false;
            }
            if (mapping.child_mapped) {
                manager.unmapAddressSpace(
                    self.address_space.?,
                    mapping.child_virtual_start,
                    mapping.size,
                ) catch {
                    cleanup_failed = true;
                    continue;
                };
                mapping.child_mapped = false;
            }
            if (mapping.object_owned) {
                manager.destroyMemoryObject(mapping.memory_object) catch {
                    cleanup_failed = true;
                    continue;
                };
                mapping.object_owned = false;
            }
            if (mapping.allocation_owned) {
                physical_allocator.free(mapping.allocation) catch {
                    cleanup_failed = true;
                    continue;
                };
                mapping.allocation_owned = false;
            }
        }
        if (cleanup_failed) return Error.CleanupFailed;
        self.mapping_count = 0;

        if (self.address_space) |address_space| {
            manager.destroyAddressSpace(address_space) catch return Error.CleanupFailed;
            self.address_space = null;
        }
        if (self.capability_space) |capability_space| {
            process_manager.destroyCapabilitySpace(capability_space) catch return Error.CleanupFailed;
            self.capability_space = null;
        }
        self.started = false;
    }
};

pub fn plan(image: []const u8) Error!LoadPlan {
    const parsed = try elf.parseLoadableImage(image, PAGE_SIZE);
    const expected_class: elf.ElfClass = switch (builtin.cpu.arch) {
        .x86 => .elf32,
        .x86_64 => .elf64,
        else => @compileError("unsupported child ELF architecture"),
    };
    if (parsed.class != expected_class) return Error.WrongElfClass;
    if (parsed.segment_count > MAX_LOAD_SEGMENTS) return Error.TooManyLoadSegments;
    const entry_point = std.math.cast(usize, parsed.entry_point) orelse return Error.AddressOutOfRange;

    var result = LoadPlan{ .entry_point = entry_point };
    for (0..parsed.segment_count) |index| {
        const segment = try elf.getLoadableSegment(image, index);
        const virtual_address = std.math.cast(usize, segment.virtual_address) orelse
            return Error.AddressOutOfRange;
        const memory_size = std.math.cast(usize, segment.memory_size) orelse
            return Error.AddressOutOfRange;
        const virtual_end = std.math.add(usize, virtual_address, memory_size) catch
            return Error.SegmentRangeOverflow;
        const virtual_start = std.mem.alignBackward(usize, virtual_address, PAGE_SIZE);
        const mapping_end = std.mem.alignForward(usize, virtual_end, PAGE_SIZE);
        if (mapping_end <= virtual_start) return Error.SegmentRangeOverflow;
        if (rangesOverlap(virtual_start, mapping_end, STACK_START, STACK_TOP)) {
            return Error.SegmentOverlapsStack;
        }
        const permissions = permissionFlags(segment.permissions);
        if (permissions == 0) return Error.EmptySegmentPermissions;
        for (result.segments[0..result.segment_count]) |existing| {
            if (rangesOverlap(
                virtual_start,
                mapping_end,
                existing.virtual_start,
                existing.virtual_start + existing.mapping_size,
            )) return Error.PageAlignedSegmentOverlap;
        }
        result.segments[result.segment_count] = .{
            .source = segment,
            .virtual_start = virtual_start,
            .mapping_size = mapping_end - virtual_start,
            .permissions = permissions,
        };
        result.segment_count += 1;
    }

    var entry_is_executable = false;
    for (result.segments[0..result.segment_count]) |segment| {
        const segment_end = segment.source.virtual_address + segment.source.memory_size;
        if (parsed.entry_point >= segment.source.virtual_address and
            parsed.entry_point < segment_end and segment.source.permissions.executable)
        {
            entry_is_executable = true;
        }
    }
    if (!entry_is_executable) return Error.EntryPointNotExecutable;
    return result;
}

pub fn createAndStart(
    comptime Environment: type,
    physical_allocator: *memory_management.PhysicalRangeAllocator,
    root_address_space: AddressSpace,
    image: []const u8,
    startup: abi.process.ChildStartup,
) Error!ChildProcess {
    const manager = memory_management.operations.MemoryManager(Environment);
    const process_manager = process_management.ProcessManager(Environment);
    const load_plan = try plan(image);
    var child = ChildProcess{};
    errdefer child.destroy(Environment, physical_allocator, root_address_space) catch {};

    child.capability_space = try process_manager.createCapabilitySpace();
    child.address_space = try manager.createAddressSpace();

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
    const initial_stack_pointer = try writeInitialStack(Environment, stack_mapping, startup);
    try unmapLoaderAliases(Environment, &child, root_address_space);

    child.thread = try process_manager.createThread();
    const configuration = abi.process.ThreadConfiguration{
        .capability_space = child.capability_space.?.capability,
        .address_space = child.address_space.?.capability,
        .entry_point = load_plan.entry_point,
        .stack_pointer = initial_stack_pointer,
        .argument = startupAddress(),
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
    const startup_offset = STACK_SIZE - @sizeOf(abi.process.ChildStartup);
    @memcpy(bytes[startup_offset..][0..@sizeOf(abi.process.ChildStartup)], std.mem.asBytes(&startup));
    var stack_pointer = STACK_START + startup_offset;
    switch (builtin.cpu.arch) {
        .x86 => {
            stack_pointer = std.mem.alignBackward(
                usize,
                stack_pointer - 2 * @sizeOf(u32),
                16,
            ) - @sizeOf(u32);
            const argument: u32 = @intCast(startupAddress());
            @memcpy(
                bytes[stack_pointer + @sizeOf(u32) - STACK_START ..][0..4],
                std.mem.asBytes(&argument),
            );
            const fake_return: u32 = 0;
            @memcpy(bytes[stack_pointer - STACK_START ..][0..4], std.mem.asBytes(&fake_return));
        },
        .x86_64 => {
            stack_pointer = std.mem.alignBackward(usize, stack_pointer, 16);
            stack_pointer -= @sizeOf(u64);
            const fake_return: u64 = 0;
            @memcpy(bytes[stack_pointer - STACK_START ..][0..8], std.mem.asBytes(&fake_return));
        },
        else => @compileError("unsupported child startup ABI"),
    }
    return stack_pointer;
}

fn startupAddress() usize {
    return STACK_TOP - @sizeOf(abi.process.ChildStartup);
}

fn mappedBytes(comptime Environment: type, virtual_start: usize, size: usize) ?[]u8 {
    const address = if (@hasDecl(Environment, "mappedMemoryAddress"))
        Environment.mappedMemoryAddress(virtual_start, size) orelse return null
    else
        virtual_start;
    const pointer: [*]u8 = @ptrFromInt(address);
    return pointer[0..size];
}

fn permissionFlags(permissions: elf.SegmentPermissions) u32 {
    var flags: u32 = 0;
    if (permissions.readable) flags |= memory_management.operations.MAP_READ;
    if (permissions.writeable) flags |= memory_management.operations.MAP_WRITE;
    if (permissions.executable) flags |= memory_management.operations.MAP_EXECUTE;
    return flags;
}

fn rangesOverlap(first_start: usize, first_end: usize, second_start: usize, second_end: usize) bool {
    return first_start < second_end and second_start < first_end;
}
