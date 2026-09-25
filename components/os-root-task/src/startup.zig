const abi = @import("abi");
const memory_management = @import("memory_management");

const bootstrap_memory = memory_management.bootstrap;
const memory_manager = memory_management.operations;
const PhysicalRangeAllocator = memory_management.PhysicalRangeAllocator;
const RootTaskHeap = memory_management.RootTaskHeap;

pub const INITIAL_HEAP_EXTENT_SIZE: usize = 0x0000_1000;

var physical_allocator: PhysicalRangeAllocator = undefined;

extern const __root_heap_start: u8;
extern const __root_heap_end: u8;

pub fn run(comptime Environment: type, boot_info: *const abi.boot_info.BootInfo) u32 {
    const manager = memory_manager.MemoryManager(Environment);
    Environment.debugWrite(abi.system_smoke.USERSPACE_ENTERED);
    Environment.debugWrite("root: started\n");

    if (boot_info.magic != abi.boot_info.BOOT_INFO_MAGIC or
        boot_info.version != abi.boot_info.BOOT_INFO_VERSION)
    {
        Environment.debugWrite("root: invalid boot info\n");
        return abi.syscall.EXIT_FAILURE;
    }
    const physical_memory = physicalMemoryDescriptors(Environment, boot_info) catch {
        Environment.debugWrite("root: invalid physical memory descriptors\n");
        return abi.syscall.EXIT_FAILURE;
    };
    bootstrap_memory.validate(physical_memory) catch {
        Environment.debugWrite("root: invalid physical memory descriptors\n");
        return abi.syscall.EXIT_FAILURE;
    };
    Environment.debugWrite(abi.system_smoke.BOOT_INFO_VALIDATED);
    Environment.debugWrite("root: boot info received\n");

    physical_allocator.initialize(physical_memory) catch {
        Environment.debugWrite("root: failed to initialize physical memory allocator\n");
        return abi.syscall.EXIT_FAILURE;
    };
    const address_space = manager.currentAddressSpace() catch {
        Environment.debugWrite("root: failed to acquire address-space capability\n");
        return abi.syscall.EXIT_FAILURE;
    };
    const heap_bounds = rootHeapBounds(Environment) catch {
        Environment.debugWrite("root: invalid heap bounds\n");
        return abi.syscall.EXIT_FAILURE;
    };
    var heap = RootTaskHeap(manager).initialize(
        &physical_allocator,
        address_space,
        heap_bounds.start,
        heap_bounds.end,
        INITIAL_HEAP_EXTENT_SIZE,
        heapAddressResolver(Environment),
    ) catch {
        Environment.debugWrite("root: failed to initialize userspace heap\n");
        return abi.syscall.EXIT_FAILURE;
    };
    Environment.debugWrite(abi.system_smoke.PHYSICAL_MEMORY_ALLOCATED);
    Environment.debugWrite("root: allocated heap physical memory\n");
    Environment.debugWrite(abi.system_smoke.ADDRESS_SPACE_CAPABILITY_ACQUIRED);
    Environment.debugWrite("root: acquired address-space capability\n");
    Environment.debugWrite(abi.system_smoke.MEMORY_OBJECT_CAPABILITY_ACQUIRED);
    Environment.debugWrite("root: acquired heap memory-object capability\n");
    Environment.debugWrite(abi.system_smoke.MEMORY_OBJECT_MAPPED);
    Environment.debugWrite("root: mapped initial userspace heap extent\n");

    const allocation = heap.allocate(128, 64) catch {
        Environment.debugWrite("root: userspace heap allocation failed\n");
        return abi.syscall.EXIT_FAILURE;
    };
    @memset(allocation, 0xA5);
    if (@intFromPtr(allocation.ptr) % 64 != 0 or
        allocation[0] != 0xA5 or
        allocation[allocation.len - 1] != 0xA5)
    {
        Environment.debugWrite("root: userspace heap verification failed\n");
        return abi.syscall.EXIT_FAILURE;
    }
    heap.free(allocation) catch {
        Environment.debugWrite("root: userspace heap release failed\n");
        return abi.syscall.EXIT_FAILURE;
    };
    const statistics = heap.statistics();
    if (statistics.extent_count != 1 or
        statistics.allocation_count != 0 or
        statistics.allocated_payload_bytes != 0)
    {
        Environment.debugWrite("root: userspace heap accounting failed\n");
        return abi.syscall.EXIT_FAILURE;
    }
    Environment.debugWrite(abi.system_smoke.USERSPACE_HEAP_VERIFIED);
    Environment.debugWrite("root: userspace heap verified\n");
    for (0..3) |_| {
        if (Environment.yield() != abi.syscall.SYSCALL_SUCCESS) {
            Environment.debugWrite("root: cooperative yield failed\n");
            return abi.syscall.EXIT_FAILURE;
        }
    }
    Environment.debugWrite(abi.system_smoke.COOPERATIVE_YIELD_COMPLETED);
    Environment.debugWrite("root: cooperative yield completed\n");
    return abi.syscall.EXIT_SUCCESS;
}

const HeapBounds = struct {
    start: usize,
    end: usize,
};

fn rootHeapBounds(comptime Environment: type) error{InvalidHeapBounds}!HeapBounds {
    const bounds: HeapBounds = if (@hasDecl(Environment, "rootHeapBounds")) blk: {
        const provided = Environment.rootHeapBounds();
        break :blk .{ .start = provided.start, .end = provided.end };
    } else .{
        .start = @intFromPtr(&__root_heap_start),
        .end = @intFromPtr(&__root_heap_end),
    };
    if (bounds.start >= bounds.end or
        bounds.start % memory_management.ROOT_HEAP_PAGE_SIZE != 0 or
        bounds.end % memory_management.ROOT_HEAP_PAGE_SIZE != 0)
    {
        return error.InvalidHeapBounds;
    }
    return bounds;
}

fn heapAddressResolver(comptime Environment: type) *const fn (usize, usize) ?usize {
    return struct {
        fn resolve(virtual_start: usize, size: usize) ?usize {
            if (@hasDecl(Environment, "mappedMemoryAddress")) {
                return Environment.mappedMemoryAddress(virtual_start, size);
            }
            return virtual_start;
        }
    }.resolve;
}

fn physicalMemoryDescriptors(
    comptime Environment: type,
    boot_info: *const abi.boot_info.BootInfo,
) bootstrap_memory.Error![]const abi.boot_info.PhysicalMemoryInfo {
    if (boot_info.physical_memory_count > abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS) {
        return bootstrap_memory.Error.TooManyDescriptors;
    }
    if (@hasDecl(Environment, "physicalMemoryDescriptors")) {
        return Environment.physicalMemoryDescriptors(boot_info);
    }
    return bootstrap_memory.descriptors(boot_info);
}
