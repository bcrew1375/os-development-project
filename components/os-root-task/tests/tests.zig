const abi = @import("abi");
const memory_management = @import("memory_management");
const process_management = @import("process_management");
const startup = @import("startup");
const std = @import("std");

const bootstrap_memory = memory_management.bootstrap;
const memory_manager = memory_management.operations;
const Heap = memory_management.Heap;
const PhysicalRangeAllocator = memory_management.PhysicalRangeAllocator;
const TestRootTaskHeap = memory_management.RootTaskHeap(manager);

const Syscall = union(enum) {
    three: struct { number: u32, arguments: [3]usize },
    five: struct { number: u32, arguments: [5]usize },
};

const RecordingEnvironment = struct {
    var syscalls: [12]Syscall = undefined;
    var syscall_count: usize = 0;
    var responses: [12]u32 = undefined;
    var response_count: usize = 0;
    var response_index: usize = 0;
    var diagnostics: [24][]const u8 = undefined;
    var diagnostic_count: usize = 0;
    var managed_memory: [4 * startup.INITIAL_HEAP_EXTENT_SIZE]u8 align(4096) = undefined;

    fn reset(configured_responses: []const u32) void {
        syscall_count = 0;
        response_count = configured_responses.len;
        response_index = 0;
        @memcpy(responses[0..configured_responses.len], configured_responses);
        diagnostic_count = 0;
        @memset(&managed_memory, 0);
    }

    pub fn syscall3(number: u32, argument0: usize, argument1: usize, argument2: usize) callconv(.c) u32 {
        syscalls[syscall_count] = .{ .three = .{
            .number = number,
            .arguments = .{ argument0, argument1, argument2 },
        } };
        syscall_count += 1;
        return nextResponse();
    }

    pub fn syscall5(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
        argument3: usize,
        argument4: usize,
    ) callconv(.c) u32 {
        syscalls[syscall_count] = .{ .five = .{
            .number = number,
            .arguments = .{ argument0, argument1, argument2, argument3, argument4 },
        } };
        syscall_count += 1;
        return nextResponse();
    }

    pub fn debugWrite(message: []const u8) void {
        diagnostics[diagnostic_count] = message;
        diagnostic_count += 1;
    }

    pub fn yield() u32 {
        return syscall3(@intFromEnum(abi.syscall.SyscallNumber.yield), 0, 0, 0);
    }

    pub fn physicalMemoryDescriptors(
        _: *const abi.boot_info.BootInfo,
    ) bootstrap_memory.Error![]const abi.boot_info.PhysicalMemoryInfo {
        return &valid_physical_memory;
    }

    pub fn rootHeapBounds() struct { start: usize, end: usize } {
        return .{ .start = 0x0100_0000, .end = 0x0101_0000 };
    }

    pub fn mappedMemoryAddress(virtual_start: usize, size: usize) ?usize {
        if (virtual_start < 0x0100_0000) return null;
        const offset = virtual_start - 0x0100_0000;
        if (offset > managed_memory.len or size > managed_memory.len - offset) return null;
        return @intFromPtr(&managed_memory) + offset;
    }

    fn nextResponse() u32 {
        if (response_index >= response_count) return abi.syscall.SYSCALL_FAILURE;
        defer response_index += 1;
        return responses[response_index];
    }
};

const manager = memory_manager.MemoryManager(RecordingEnvironment);
const process_manager = process_management.ProcessManager(RecordingEnvironment);

var valid_physical_memory = [_]abi.boot_info.PhysicalMemoryInfo{.{
    .physical_start = 0x1000,
    .size = 0x4000,
    .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
    .capability = abi.capability.makeCapabilityHandle(1, 1),
}};

fn validBootInfo() abi.boot_info.BootInfo {
    return .{
        .magic = abi.boot_info.BOOT_INFO_MAGIC,
        .version = abi.boot_info.BOOT_INFO_VERSION,
        .module_count = 0,
        .modules_address = 0,
        .physical_memory_count = valid_physical_memory.len,
        .physical_memory_address = 0,
    };
}

fn expectDiagnostic(index: usize, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, RecordingEnvironment.diagnostics[index]);
}

fn physicalDescriptor(
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

test "physical allocator splits aligned first-fit ranges and preserves accounting" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x8000, 1),
        physicalDescriptor(0x20_000, 0x2000, 2),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);

    const handle = try allocator.allocate(0x2000, 0x4000);
    const range = try allocator.resolve(handle);
    try std.testing.expectEqual(@as(u64, 0x4000), range.physical_start);
    try std.testing.expectEqual(@as(u64, 0x3000), range.offset);
    try std.testing.expectEqual(descriptors[0].capability, range.parent_capability);
    try std.testing.expectEqual(@as(u64, 0x2000), range.size);

    const statistics = allocator.statistics();
    try std.testing.expectEqual(@as(u64, 0xA000), statistics.delegated_bytes);
    try std.testing.expectEqual(@as(u64, 0x8000), statistics.free_bytes);
    try std.testing.expectEqual(@as(u64, 0x2000), statistics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 3), statistics.free_extent_count);
    try std.testing.expectEqual(@as(usize, 1), statistics.allocation_count);
}

test "physical allocator exhausts without returning holes" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x1000, 1),
        physicalDescriptor(0x4000, 0x1000, 2),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);

    const first = try allocator.allocate(0x1000, 0x1000);
    const second = try allocator.allocate(0x1000, 0x1000);
    try std.testing.expectEqual(@as(u64, 0x1000), (try allocator.resolve(first)).physical_start);
    try std.testing.expectEqual(@as(u64, 0x4000), (try allocator.resolve(second)).physical_start);
    try std.testing.expectError(error.Exhausted, allocator.allocate(1, 1));
    try std.testing.expectEqual(@as(u64, 0), allocator.statistics().free_bytes);
}

test "physical allocator rejects invalid requests and overflow transactionally" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x4000, 1),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    const before = allocator.statistics();

    try std.testing.expectError(error.EmptyAllocation, allocator.allocate(0, 0x1000));
    try std.testing.expectError(error.InvalidAlignment, allocator.allocate(1, 0));
    try std.testing.expectError(error.InvalidAlignment, allocator.allocate(1, 3));
    try std.testing.expectError(error.AllocationOverflow, allocator.allocate(std.math.maxInt(u64), 1));
    try std.testing.expectEqualDeep(before, allocator.statistics());
}

test "physical allocator rejects duplicate foreign fabricated and stale handles" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x4000, 1),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    var foreign_allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    try foreign_allocator.initialize(&descriptors);

    const original = try allocator.allocate(0x1000, 0x1000);
    try std.testing.expectError(error.ForeignHandle, foreign_allocator.resolve(original));
    var fabricated = original;
    fabricated.guard ^= 1;
    try std.testing.expectError(error.InvalidHandle, allocator.resolve(fabricated));

    try allocator.free(original);
    try std.testing.expectError(error.DuplicateFree, allocator.free(original));
    const replacement = try allocator.allocate(0x1000, 0x1000);
    try std.testing.expectError(error.StaleHandle, allocator.resolve(original));
    try std.testing.expectEqual(@as(u64, 0x1000), (try allocator.resolve(replacement)).physical_start);
}

test "physical allocator coalesces only adjacent ranges with the same parent" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x3000, 1),
        physicalDescriptor(0x4000, 0x1000, 2),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);

    const first = try allocator.allocate(0x1000, 0x1000);
    const second = try allocator.allocate(0x1000, 0x1000);
    const third = try allocator.allocate(0x1000, 0x1000);
    try allocator.free(second);
    try allocator.free(first);
    try allocator.free(third);

    const statistics = allocator.statistics();
    try std.testing.expectEqual(statistics.delegated_bytes, statistics.free_bytes);
    try std.testing.expectEqual(@as(u64, 0), statistics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 2), statistics.free_extent_count);
    try std.testing.expectEqual(@as(usize, 0), statistics.allocation_count);
}

test "physical allocator reports allocation-slot exhaustion without mutation" {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{
        physicalDescriptor(0x1000, 0x1000 * (PhysicalRangeAllocator.MAX_ALLOCATIONS + 1), 1),
    };
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    var handles: [PhysicalRangeAllocator.MAX_ALLOCATIONS]PhysicalRangeAllocator.AllocationHandle = undefined;
    for (&handles) |*handle| handle.* = try allocator.allocate(0x1000, 0x1000);
    const before = allocator.statistics();

    try std.testing.expectError(error.MetadataExhausted, allocator.allocate(0x1000, 0x1000));
    try std.testing.expectEqualDeep(before, allocator.statistics());
    for (handles) |handle| _ = try allocator.resolve(handle);
}

test "physical allocator reports extent exhaustion without mutation" {
    var descriptors: [PhysicalRangeAllocator.MAX_FREE_EXTENTS]abi.boot_info.PhysicalMemoryInfo = undefined;
    descriptors[0] = physicalDescriptor(0x1000, 0x5000, 1);
    for (descriptors[1..], 1..) |*descriptor, index| {
        descriptor.* = physicalDescriptor(0x10_000 + index * 0x2000, 0x1000, @intCast(index + 1));
    }
    var allocator: PhysicalRangeAllocator = undefined;
    try allocator.initialize(&descriptors);
    const before = allocator.statistics();

    try std.testing.expectError(error.MetadataExhausted, allocator.allocate(0x1000, 0x4000));
    try std.testing.expectEqualDeep(before, allocator.statistics());
}

test "heap validates requests tracks accounting and completely coalesces" {
    var backing: [4096]u8 align(64) = undefined;
    var heap = try Heap.initialize(@intFromPtr(&backing), backing.len);
    try std.testing.expect(heap.isCompletelyFree());
    try std.testing.expectError(error.EmptyAllocation, heap.allocate(0, 8));
    try std.testing.expectError(error.InvalidAlignment, heap.allocate(1, 3));

    const first = try heap.allocate(128, 64);
    const second = try heap.allocate(256, 256);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first.ptr) % 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(second.ptr) % 256);
    try std.testing.expectEqual(@as(usize, 384), heap.statistics().allocated_payload_bytes);
    try std.testing.expectEqual(@as(usize, 2), heap.statistics().allocation_count);

    try heap.free(first);
    try heap.free(second);
    try std.testing.expect(heap.isCompletelyFree());
    try std.testing.expectEqual(@as(usize, 0), heap.statistics().allocated_payload_bytes);
}

test "heap rejects foreign and duplicate frees" {
    var backing: [4096]u8 align(64) = undefined;
    var foreign_backing: [64]u8 align(64) = undefined;
    var heap = try Heap.initialize(@intFromPtr(&backing), backing.len);
    const allocation = try heap.allocate(64, 8);
    try std.testing.expectError(error.InvalidAllocation, heap.free(foreign_backing[0..32]));
    try heap.free(allocation);
    try std.testing.expectError(error.DuplicateFree, heap.free(allocation));
}

fn initializeHeapPhysicalAllocator(allocator: *PhysicalRangeAllocator) !void {
    const descriptors = [_]abi.boot_info.PhysicalMemoryInfo{physicalDescriptor(
        0x1000,
        4 * startup.INITIAL_HEAP_EXTENT_SIZE,
        1,
    )};
    try allocator.initialize(&descriptors);
}

fn rejectMappedAddress(_: usize, _: usize) ?usize {
    return null;
}

test "root task heap grows deterministically and reclaims empty later extents" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.SYSCALL_SUCCESS,
        22,
        32,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });
    var heap = try TestRootTaskHeap.initialize(
        &allocator,
        .{ .capability = 11 },
        0x0100_0000,
        0x0100_4000,
        startup.INITIAL_HEAP_EXTENT_SIZE,
        RecordingEnvironment.mappedMemoryAddress,
    );
    const first = try heap.allocate(128, 64);
    const second = try heap.allocate(4000, 64);
    try std.testing.expectEqual(@as(usize, 2), heap.statistics().extent_count);
    try std.testing.expect(@intFromPtr(second.ptr) > @intFromPtr(first.ptr));

    try heap.free(second);
    try std.testing.expectEqual(@as(usize, 1), try heap.reclaimEmptyExtents());
    try std.testing.expectEqual(@as(usize, 1), heap.statistics().extent_count);
    try std.testing.expectEqual(@as(usize, 1), allocator.statistics().allocation_count);
    try heap.free(first);
    try std.testing.expectError(error.InitialExtentCannotBeReclaimed, heap.reclaimExtent(0));
}

test "root task heap initialization rolls back each unpublished stage" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);

    RecordingEnvironment.reset(&.{abi.syscall.errorResult(.out_of_resources)});
    try std.testing.expectError(
        error.OutOfResources,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);

    RecordingEnvironment.reset(&.{
        21,
        abi.syscall.errorResult(.out_of_resources),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectError(
        error.OutOfResources,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);

    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectError(
        error.InvalidPermissions,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);
}

test "root task heap retains physical ownership when cleanup fails" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.errorResult(.internal_failure),
    });
    try std.testing.expectError(
        error.CleanupFailed,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            RecordingEnvironment.mappedMemoryAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), allocator.statistics().allocation_count);
}

test "root task heap resolver failure unwinds mapping object and physical range" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectError(
        error.MappedAddressUnavailable,
        TestRootTaskHeap.initialize(
            &allocator,
            .{ .capability = 11 },
            0x0100_0000,
            0x0100_4000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            rejectMappedAddress,
        ),
    );
    try std.testing.expectEqual(@as(usize, 5), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.unmap_address_space),
        RecordingEnvironment.syscalls[3].three.number,
    );
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_memory_object),
        RecordingEnvironment.syscalls[4].three.number,
    );
    try std.testing.expectEqual(@as(usize, 0), allocator.statistics().allocation_count);
}

test "root task heap reclamation retries partial cleanup and reuses virtual holes" {
    var allocator: PhysicalRangeAllocator = undefined;
    try initializeHeapPhysicalAllocator(&allocator);
    RecordingEnvironment.reset(&.{
        21,
        31,
        abi.syscall.SYSCALL_SUCCESS,
        22,
        32,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.errorResult(.internal_failure),
        abi.syscall.SYSCALL_SUCCESS,
        23,
        33,
        abi.syscall.SYSCALL_SUCCESS,
    });
    var heap = try TestRootTaskHeap.initialize(
        &allocator,
        .{ .capability = 11 },
        0x0100_0000,
        0x0100_4000,
        startup.INITIAL_HEAP_EXTENT_SIZE,
        RecordingEnvironment.mappedMemoryAddress,
    );
    const initial_allocation = try heap.allocate(128, 64);
    const allocation = try heap.allocate(4000, 64);
    const reclaimed_address = @intFromPtr(allocation.ptr);
    try heap.free(allocation);

    try std.testing.expectError(error.CleanupFailed, heap.reclaimExtent(1));
    try std.testing.expectEqual(@as(usize, 2), heap.statistics().extent_count);
    try heap.reclaimExtent(1);
    try std.testing.expectEqual(@as(usize, 1), heap.statistics().extent_count);

    const replacement = try heap.allocate(4000, 64);
    try std.testing.expectEqual(reclaimed_address, @intFromPtr(replacement.ptr));
    try heap.free(replacement);
    try heap.free(initial_allocation);
}

test "memory manager emits address-space and region syscalls" {
    RecordingEnvironment.reset(&.{ 42, abi.syscall.SYSCALL_SUCCESS });
    const address_space = try manager.createAddressSpace();
    try std.testing.expectEqual(@as(u32, 42), address_space.capability);
    try manager.mapRegion(address_space, 0x2000, 0x3000);

    const create_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.create_address_space), create_call.number);
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, create_call.arguments);
    const map_call = RecordingEnvironment.syscalls[1].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.map_memory), map_call.number);
    try std.testing.expectEqual([_]usize{ 42, 0x2000, 0x3000 }, map_call.arguments);

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectError(error.InternalFailure, manager.createAddressSpace());

    RecordingEnvironment.reset(&.{abi.syscall.errorResult(.invalid_range)});
    try std.testing.expectError(error.InvalidRange, manager.mapRegion(address_space, 0x2000, 0x3000));
}

test "process manager emits creation configuration lifecycle and delegation syscalls" {
    RecordingEnvironment.reset(&.{
        41,
        42,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        43,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });
    const capability_space = try process_manager.createCapabilitySpace();
    const thread = try process_manager.createThread();
    const configuration = abi.process.ThreadConfiguration{
        .capability_space = capability_space.capability,
        .address_space = 17,
        .entry_point = 0x0040_0000,
        .stack_pointer = 0x0080_0000,
        .argument = 0x1234,
    };
    try process_manager.configureThread(thread, &configuration);
    try process_manager.startThread(thread);
    try process_manager.suspendThread(thread);
    try process_manager.resumeThread(thread);
    try process_manager.terminateThread(thread, 23);
    const installed = try process_manager.installCapability(
        capability_space,
        thread.capability,
        .{ .terminate = true },
    );
    try std.testing.expectEqual(@as(u32, 43), installed);
    try process_manager.deleteCapability(capability_space, installed);
    try process_manager.destroyThread(thread);
    try process_manager.destroyCapabilitySpace(capability_space);

    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.configure_thread),
        RecordingEnvironment.syscalls[2].three.number,
    );
    try std.testing.expectEqual(thread.capability, RecordingEnvironment.syscalls[2].three.arguments[0]);
    try std.testing.expectEqual(@intFromPtr(&configuration), RecordingEnvironment.syscalls[2].three.arguments[1]);
    try std.testing.expectEqual(
        [_]usize{ capability_space.capability, thread.capability, abi.capability.rightsBits(.{ .terminate = true }) },
        RecordingEnvironment.syscalls[7].three.arguments,
    );
}

test "process manager decodes process-management errors" {
    const expected = [_]struct { code: abi.syscall.ErrorCode, err: process_management.Error }{
        .{ .code = .invalid_state, .err = error.InvalidState },
        .{ .code = .object_in_use, .err = error.ObjectInUse },
        .{ .code = .invalid_user_memory, .err = error.InvalidUserMemory },
    };
    for (expected) |case| {
        RecordingEnvironment.reset(&.{abi.syscall.errorResult(case.code)});
        try std.testing.expectError(case.err, process_manager.createThread());
    }
}

test "memory manager emits memory-object mapping syscall and flags" {
    RecordingEnvironment.reset(&.{ 71, abi.syscall.SYSCALL_SUCCESS });
    const memory_object = try manager.createMemoryObject(.{ .capability = 0x5000 });
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const permissions = memory_manager.MAP_READ | memory_manager.MAP_WRITE | memory_manager.MAP_EXECUTE;
    try manager.mapMemoryObject(address_space, memory_object, 0x8000, 0x5000, permissions);

    const create_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.create_memory_object), create_call.number);
    try std.testing.expectEqual([_]usize{ 0x5000, 0, 0 }, create_call.arguments);
    const map_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.map_memory_object), map_call.number);
    try std.testing.expectEqual([_]usize{ 19, 71, 0x8000, 0x5000, permissions }, map_call.arguments);

    RecordingEnvironment.reset(&.{ 71, abi.syscall.errorResult(.invalid_permissions) });
    const failed_object = try manager.createMemoryObject(.{ .capability = 0x1000 });
    try std.testing.expectError(
        error.InvalidPermissions,
        manager.mapMemoryObject(address_space, failed_object, 0, 0x1000, 0),
    );

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectError(
        error.InternalFailure,
        manager.createMemoryObject(.{ .capability = 0x1000 }),
    );
}

test "memory manager forwards every permission flag combination" {
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const memory_object = memory_manager.MemoryObject{ .capability = 71 };

    for (0..8) |permission_flags| {
        RecordingEnvironment.reset(&.{abi.syscall.SYSCALL_SUCCESS});
        try manager.mapMemoryObject(
            address_space,
            memory_object,
            0x8000,
            0x1000,
            @intCast(permission_flags),
        );
        try std.testing.expectEqual(
            permission_flags,
            RecordingEnvironment.syscalls[0].five.arguments[4],
        );
    }
}

test "memory manager emits typed physical-memory lifecycle syscalls" {
    RecordingEnvironment.reset(&.{ 81, 82, abi.syscall.SYSCALL_SUCCESS, abi.syscall.SYSCALL_SUCCESS });
    const source = memory_manager.UntypedMemory{ .capability = 17 };
    const offset: u64 = 0x1234_5678_9abc_d000;
    const child_rights = abi.capability.Rights{ .read = true, .manage = true };
    const frame_rights = abi.capability.Rights{ .read = true, .write = true };

    const child = try manager.retypeUntypedMemory(source, offset, 3, child_rights);
    try std.testing.expectEqual(@as(u32, 81), child.capability);
    const frame = try manager.retypePhysicalFrames(child, 0x2000, 2, frame_rights);
    try std.testing.expectEqual(@as(u32, 82), frame.capability);
    try manager.deletePhysicalMemory(frame);
    try manager.revokePhysicalMemory(child);

    const child_call = RecordingEnvironment.syscalls[0].five;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.retype_untyped_memory),
        child_call.number,
    );
    try std.testing.expectEqual([_]usize{
        17,
        abi.syscall.lowU32(offset),
        abi.syscall.highU32(offset),
        3,
        abi.syscall.packRetypeTarget(.untyped_memory, child_rights),
    }, child_call.arguments);

    const frame_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual([_]usize{
        81,
        0x2000,
        0,
        2,
        abi.syscall.packRetypeTarget(.physical_frame, frame_rights),
    }, frame_call.arguments);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.delete_physical_memory),
        RecordingEnvironment.syscalls[2].three.number,
    );
    try std.testing.expectEqual(
        [_]usize{ 82, 0, 0 },
        RecordingEnvironment.syscalls[2].three.arguments,
    );
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.revoke_physical_memory),
        RecordingEnvironment.syscalls[3].three.number,
    );
    try std.testing.expectEqual(
        [_]usize{ 81, 0, 0 },
        RecordingEnvironment.syscalls[3].three.arguments,
    );
}

test "memory manager emits complete address-space lifecycle syscalls" {
    const permissions = memory_manager.MAP_READ | memory_manager.MAP_EXECUTE;
    RecordingEnvironment.reset(&.{ 31, abi.syscall.SYSCALL_SUCCESS, permissions, abi.syscall.SYSCALL_SUCCESS, abi.syscall.SYSCALL_SUCCESS });

    const address_space = try manager.currentAddressSpace();
    try std.testing.expectEqual(@as(u32, 31), address_space.capability);
    try manager.protectAddressSpace(address_space, 0x4000, 0x2000, permissions);
    try std.testing.expectEqual(
        permissions,
        try manager.queryAddressSpace(address_space, 0x4000, 0x2000),
    );
    try manager.unmapAddressSpace(address_space, 0x4000, 0x2000);
    try manager.destroyAddressSpace(address_space);

    const current_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.current_address_space),
        current_call.number,
    );
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, current_call.arguments);

    const protect_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.protect_address_space),
        protect_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0x4000, 0x2000, permissions, 0 }, protect_call.arguments);

    const query_call = RecordingEnvironment.syscalls[2].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.query_address_space),
        query_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0x4000, 0x2000 }, query_call.arguments);

    const unmap_call = RecordingEnvironment.syscalls[3].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.unmap_address_space),
        unmap_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0x4000, 0x2000 }, unmap_call.arguments);

    const destroy_call = RecordingEnvironment.syscalls[4].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_address_space),
        destroy_call.number,
    );
    try std.testing.expectEqual([_]usize{ 31, 0, 0 }, destroy_call.arguments);
}

test "memory manager translates every structured ABI error" {
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const cases = [_]struct {
        code: abi.syscall.ErrorCode,
        expected: anyerror,
    }{
        .{ .code = .invalid_capability, .expected = error.InvalidCapability },
        .{ .code = .insufficient_rights, .expected = error.InsufficientRights },
        .{ .code = .out_of_resources, .expected = error.OutOfResources },
        .{ .code = .invalid_range, .expected = error.InvalidRange },
        .{ .code = .invalid_permissions, .expected = error.InvalidPermissions },
        .{ .code = .mapping_not_found, .expected = error.MappingNotFound },
        .{ .code = .address_space_in_use, .expected = error.AddressSpaceInUse },
        .{ .code = .unsupported, .expected = error.Unsupported },
        .{ .code = .internal_failure, .expected = error.InternalFailure },
    };

    for (cases) |case| {
        RecordingEnvironment.reset(&.{abi.syscall.errorResult(case.code)});
        try std.testing.expectError(
            case.expected,
            manager.mapRegion(address_space, 0x2000, 0x1000),
        );
    }

    RecordingEnvironment.reset(&.{abi.syscall.SYSCALL_FAILURE});
    try std.testing.expectError(
        error.InternalFailure,
        manager.mapRegion(address_space, 0x2000, 0x1000),
    );
}

test "startup rejects invalid boot information before capability syscalls" {
    var boot_info = validBootInfo();
    boot_info.magic = 0;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(@as(usize, 3), RecordingEnvironment.diagnostic_count);
    try expectDiagnostic(0, abi.system_smoke.USERSPACE_ENTERED);
    try expectDiagnostic(1, "root: started\n");
    try expectDiagnostic(2, "root: invalid boot info\n");

    boot_info = validBootInfo();
    boot_info.version += 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);

    boot_info = validBootInfo();
    boot_info.physical_memory_count = abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS + 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try expectDiagnostic(2, "root: invalid physical memory descriptors\n");
}

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

test "startup stops after each capability or mapping failure" {
    const boot_info = validBootInfo();

    RecordingEnvironment.reset(&.{abi.syscall.errorResult(.out_of_resources)});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 1), RecordingEnvironment.syscall_count);
    try expectDiagnostic(4, "root: failed to acquire address-space capability\n");

    RecordingEnvironment.reset(&.{ 11, abi.syscall.errorResult(.out_of_resources) });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 2), RecordingEnvironment.syscall_count);
    try expectDiagnostic(4, "root: failed to initialize userspace heap\n");

    RecordingEnvironment.reset(&.{
        11,
        21,
        abi.syscall.errorResult(.out_of_resources),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 4), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.delete_physical_memory),
        RecordingEnvironment.syscalls[3].three.number,
    );
    try std.testing.expectEqual([_]usize{ 21, 0, 0 }, RecordingEnvironment.syscalls[3].three.arguments);
    try expectDiagnostic(4, "root: failed to initialize userspace heap\n");

    RecordingEnvironment.reset(&.{
        11,
        21,
        21,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 5), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_memory_object),
        RecordingEnvironment.syscalls[4].three.number,
    );
    try std.testing.expectEqual([_]usize{ 21, 0, 0 }, RecordingEnvironment.syscalls[4].three.arguments);
    try expectDiagnostic(4, "root: failed to initialize userspace heap\n");
}

test "startup retains allocator ownership when kernel cleanup fails" {
    const boot_info = validBootInfo();

    RecordingEnvironment.reset(&.{
        11,
        21,
        abi.syscall.errorResult(.out_of_resources),
        abi.syscall.errorResult(.internal_failure),
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 4), RecordingEnvironment.syscall_count);
    try expectDiagnostic(4, "root: failed to initialize userspace heap\n");

    RecordingEnvironment.reset(&.{
        11,
        21,
        21,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.errorResult(.internal_failure),
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 5), RecordingEnvironment.syscall_count);
    try expectDiagnostic(4, "root: failed to initialize userspace heap\n");
}

test "startup completes capability-based memory setup in order" {
    const boot_info = validBootInfo();
    RecordingEnvironment.reset(&.{
        11,
        21,
        21,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });

    try std.testing.expectEqual(abi.syscall.EXIT_SUCCESS, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 7), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(@as(usize, 16), RecordingEnvironment.diagnostic_count);
    try expectDiagnostic(0, abi.system_smoke.USERSPACE_ENTERED);
    try expectDiagnostic(1, "root: started\n");
    try expectDiagnostic(2, abi.system_smoke.BOOT_INFO_VALIDATED);
    try expectDiagnostic(3, "root: boot info received\n");
    try expectDiagnostic(4, abi.system_smoke.PHYSICAL_MEMORY_ALLOCATED);
    try expectDiagnostic(5, "root: allocated heap physical memory\n");
    try expectDiagnostic(6, abi.system_smoke.ADDRESS_SPACE_CAPABILITY_ACQUIRED);
    try expectDiagnostic(7, "root: acquired address-space capability\n");
    try expectDiagnostic(8, abi.system_smoke.MEMORY_OBJECT_CAPABILITY_ACQUIRED);
    try expectDiagnostic(9, "root: acquired heap memory-object capability\n");
    try expectDiagnostic(10, abi.system_smoke.MEMORY_OBJECT_MAPPED);
    try expectDiagnostic(11, "root: mapped initial userspace heap extent\n");
    try expectDiagnostic(12, abi.system_smoke.USERSPACE_HEAP_VERIFIED);
    try expectDiagnostic(13, "root: userspace heap verified\n");
    try expectDiagnostic(14, abi.system_smoke.COOPERATIVE_YIELD_COMPLETED);
    try expectDiagnostic(15, "root: cooperative yield completed\n");

    const current_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.current_address_space),
        current_call.number,
    );
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, current_call.arguments);

    const retype_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.retype_untyped_memory),
        retype_call.number,
    );
    try std.testing.expectEqual(valid_physical_memory[0].capability, retype_call.arguments[0]);
    try std.testing.expectEqual(@as(usize, 0), retype_call.arguments[1]);
    try std.testing.expectEqual(@as(usize, 0), retype_call.arguments[2]);

    const create_call = RecordingEnvironment.syscalls[2].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.create_memory_object),
        create_call.number,
    );
    try std.testing.expectEqual([_]usize{ 21, 0, 0 }, create_call.arguments);

    const map_call = RecordingEnvironment.syscalls[3].five;
    try std.testing.expectEqual(
        [_]usize{
            11,
            21,
            0x0100_0000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            memory_manager.MAP_READ | memory_manager.MAP_WRITE,
        },
        map_call.arguments,
    );
    for (RecordingEnvironment.syscalls[4..7]) |yield_call| {
        try std.testing.expectEqual(
            @intFromEnum(abi.syscall.SyscallNumber.yield),
            yield_call.three.number,
        );
        try std.testing.expectEqual([_]usize{ 0, 0, 0 }, yield_call.three.arguments);
    }
}
