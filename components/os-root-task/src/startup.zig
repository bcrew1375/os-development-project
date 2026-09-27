const abi = @import("abi");
const boot_modules = @import("boot_modules");
const memory_management = @import("memory_management");
const process_management = @import("process_management");
const ipc = @import("ipc");
const std = @import("std");

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
    const modules = bootModuleDescriptors(Environment, boot_info) catch {
        Environment.debugWrite("root: invalid boot modules\n");
        return abi.syscall.EXIT_FAILURE;
    };
    if (modules.len < 2) {
        Environment.debugWrite("root: missing delegated boot module\n");
        return abi.syscall.EXIT_FAILURE;
    }
    boot_modules.validate(modules) catch {
        Environment.debugWrite("root: invalid boot modules\n");
        return abi.syscall.EXIT_FAILURE;
    };
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
    Environment.debugWrite(abi.system_smoke.BOOT_MODULES_VALIDATED);
    Environment.debugWrite("root: boot modules validated\n");

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
    if (comptime @hasDecl(Environment, "enableChildProcesses")) {
        runChildSmoke(Environment, &physical_allocator, address_space, modules[1]) catch {
            Environment.debugWrite("root: child process smoke sequence failed\n");
            return abi.syscall.EXIT_FAILURE;
        };
    }
    return abi.syscall.EXIT_SUCCESS;
}

fn runChildSmoke(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    module: abi.boot_info.BootModuleInfo,
) !void {
    const image = bootModuleBytes(Environment, module) orelse return error.InvalidBootModule;
    const child_process = process_management.child_process;

    const endpoint_manager = ipc.EndpointManager(Environment);
    const request_endpoint = try endpoint_manager.createEndpoint();
    var request_endpoint_owned = true;
    errdefer if (request_endpoint_owned) endpoint_manager.destroyEndpoint(request_endpoint) catch {};
    const reply_endpoint = try endpoint_manager.createEndpoint();
    var reply_endpoint_owned = true;
    errdefer if (reply_endpoint_owned) endpoint_manager.destroyEndpoint(reply_endpoint) catch {};
    var ipc_child = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .ipc_ping_pong },
        request_endpoint.capability,
        reply_endpoint.capability,
    );
    errdefer ipc_child.destroy(Environment, allocator, root_address_space) catch {};
    Environment.debugWrite(abi.system_smoke.IPC_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_IPC_CHILD_BLOCKED);
    try endpoint_manager.send(request_endpoint, abi.system_smoke.IPC_REQUEST);
    Environment.debugWrite(abi.system_smoke.IPC_REQUEST_SENT);
    const reply = try endpoint_manager.receive(reply_endpoint);
    if (!std.meta.eql(reply, abi.system_smoke.IPC_REPLY)) return error.InvalidIpcReply;
    Environment.debugWrite(abi.system_smoke.IPC_REPLY_VERIFIED);
    try ipc_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.IPC_CHILD_DESTROYED);
    try endpoint_manager.destroyEndpoint(reply_endpoint);
    reply_endpoint_owned = false;
    try endpoint_manager.destroyEndpoint(request_endpoint);
    request_endpoint_owned = false;
    Environment.debugWrite(abi.system_smoke.IPC_ENDPOINTS_DESTROYED);

    try runCapabilityTransferSmoke(Environment, allocator, root_address_space, image);

    var fault_child = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .invalid_opcode },
        null,
        null,
    );
    Environment.debugWrite(abi.system_smoke.FAULT_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_FAULT_CHILD_YIELD);
    try yieldSuccessfully(Environment);
    try fault_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.FAULT_CHILD_DESTROYED);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_CHILDREN);
    try runManagedProcessSmoke(Environment, allocator, root_address_space, image);
}

fn runManagedProcessSmoke(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    image: []const u8,
) !void {
    const ManagedProcess = process_management.managed_process.ManagedProcess;

    var exit_child = try ManagedProcess.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        1,
        .exit_success,
    );
    errdefer cleanupManagedProcess(Environment, &exit_child, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_CHILD_STARTED);
    try exit_child.observeStartup(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_STARTUP_OBSERVED);
    try exit_child.transferServiceCapability(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_SERVICE_TRANSFERRED);
    try exit_child.observeServiceReady(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_SERVICE_READY);
    _ = try exit_child.observeTerminal(Environment);
    Environment.debugWrite(abi.system_smoke.CHILD_EXIT_SUCCESS);
    try exit_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_EXIT_CHILD_DESTROYED);

    var fault_child = try ManagedProcess.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        2,
        .fault_invalid_opcode,
    );
    errdefer cleanupManagedProcess(Environment, &fault_child, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_CHILD_STARTED);
    try fault_child.observeStartup(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_STARTUP_OBSERVED);
    try fault_child.transferServiceCapability(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_SERVICE_TRANSFERRED);
    try fault_child.observeServiceReady(Environment);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_SERVICE_READY);
    _ = try fault_child.observeTerminal(Environment);
    Environment.debugWrite(abi.system_smoke.CHILD_FAULT_INVALID_OPCODE);
    try fault_child.destroy(Environment, allocator, root_address_space);
    Environment.debugWrite(abi.system_smoke.MANAGED_FAULT_CHILD_DESTROYED);
}

fn cleanupManagedProcess(
    comptime Environment: type,
    managed: *process_management.managed_process.ManagedProcess,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
) void {
    if (managed.state == .terminal_observed) {
        managed.destroy(Environment, allocator, root_address_space) catch {};
    }
}

fn runCapabilityTransferSmoke(
    comptime Environment: type,
    allocator: *PhysicalRangeAllocator,
    root_address_space: memory_manager.AddressSpace,
    image: []const u8,
) !void {
    const child_process = process_management.child_process;
    const endpoint_manager = ipc.EndpointManager(Environment);
    const process_manager = process_management.ProcessManager(Environment);

    const transfer_endpoint = try endpoint_manager.createEndpoint();
    var transfer_endpoint_owned = true;
    errdefer if (transfer_endpoint_owned) endpoint_manager.destroyEndpoint(transfer_endpoint) catch {};
    const acknowledgment_endpoint = try endpoint_manager.createEndpoint();
    var acknowledgment_endpoint_owned = true;
    errdefer if (acknowledgment_endpoint_owned) endpoint_manager.destroyEndpoint(acknowledgment_endpoint) catch {};
    var child = try child_process.createAndStart(
        Environment,
        allocator,
        root_address_space,
        image,
        .{ .mode = .capability_transfer },
        transfer_endpoint.capability,
        null,
    );
    var child_owned = true;
    errdefer if (child_owned) child.destroy(Environment, allocator, root_address_space) catch {};
    const child_space = child.capability_space orelse return error.MissingChildCapabilitySpace;
    // A newly created capability space starts every slot at generation 1. This
    // mode installs only the receive endpoint in slot 0 before transferring into
    // the otherwise untouched exact destination slot below.
    const transferred_capability = abi.capability.makeCapabilityHandle(
        abi.system_smoke.CAPABILITY_TRANSFER_DESTINATION_SLOT,
        1,
    );
    var transferred_capability_owned = false;
    errdefer if (transferred_capability_owned) {
        process_manager.deleteCapability(child_space, transferred_capability) catch {};
    };

    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_CHILD_STARTED);
    try yieldSuccessfully(Environment);
    Environment.debugWrite(abi.system_smoke.ROOT_RESUMED_AFTER_TRANSFER_CHILD_BLOCKED);
    try endpoint_manager.sendCapability(
        transfer_endpoint,
        acknowledgment_endpoint.capability,
        .{ .send = true },
        abi.system_smoke.CAPABILITY_TRANSFER_MESSAGE,
    );
    transferred_capability_owned = true;
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_SENT);
    const acknowledgment = try endpoint_manager.receive(acknowledgment_endpoint);
    if (acknowledgment.words[0] != abi.system_smoke.CAPABILITY_TRANSFER_ACK.words[0] or
        acknowledgment.words[1] != transferred_capability or
        acknowledgment.words[2] != abi.system_smoke.CAPABILITY_TRANSFER_ACK.words[2])
    {
        return error.InvalidCapabilityTransferAcknowledgment;
    }
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_ACK_VERIFIED);

    try process_manager.deleteCapability(child_space, transferred_capability);
    transferred_capability_owned = false;
    try child.destroy(Environment, allocator, root_address_space);
    child_owned = false;
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_CHILD_DESTROYED);
    try endpoint_manager.destroyEndpoint(acknowledgment_endpoint);
    acknowledgment_endpoint_owned = false;
    try endpoint_manager.destroyEndpoint(transfer_endpoint);
    transfer_endpoint_owned = false;
    Environment.debugWrite(abi.system_smoke.CAPABILITY_TRANSFER_ENDPOINTS_DESTROYED);
}

fn yieldSuccessfully(comptime Environment: type) !void {
    if (Environment.yield() != abi.syscall.SYSCALL_SUCCESS) return error.YieldFailed;
}

fn bootModuleBytes(
    comptime Environment: type,
    module: abi.boot_info.BootModuleInfo,
) ?[]const u8 {
    const size = std.math.cast(usize, module.size) orelse return null;
    const virtual_start = std.math.cast(usize, module.virtual_start) orelse return null;
    const address = if (@hasDecl(Environment, "mappedMemoryAddress"))
        Environment.mappedMemoryAddress(virtual_start, size) orelse return null
    else
        virtual_start;
    const pointer: [*]const u8 = @ptrFromInt(address);
    return pointer[0..size];
}

fn bootModuleDescriptors(
    comptime Environment: type,
    boot_info: *const abi.boot_info.BootInfo,
) boot_modules.Error![]const abi.boot_info.BootModuleInfo {
    if (boot_info.module_count > abi.boot_info.MAX_BOOT_MODULES) {
        return boot_modules.Error.TooManyModules;
    }
    if (@hasDecl(Environment, "bootModuleDescriptors")) {
        return Environment.bootModuleDescriptors(boot_info);
    }
    return boot_modules.descriptors(boot_info);
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
