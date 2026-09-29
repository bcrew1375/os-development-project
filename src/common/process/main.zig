//! Minimal process, address-space, and memory-object registry.

const abi = @import("abi");
const arch = @import("arch");
const std = @import("std");
const vmm = @import("../memory_management/vmm.zig");
const physical_memory_authority = @import("../memory_management/physical_memory_authority.zig");
const capability_space = @import("../capability/space.zig");
const address_space_registry = @import("address_space_registry.zig");
const memory_object_registry = @import("memory_object_registry.zig");

/// Errors produced by process and memory-object management operations.
pub const ProcessError = error{
    OutOfAddressSpaces,
    OutOfMemoryObjects,
    InvalidAddressSpaceHandle,
    InvalidMemoryObjectHandle,
    EmptyMemoryRange,
    MemoryRangeOverflow,
    KernelAddressRange,
    ObjectRangeOverflow,
    ObjectRangeOutOfBounds,
    UnalignedMemoryObjectRange,
    InvalidMemoryPermissions,
    AddressSpaceInUse,
    MemoryObjectInUse,
    ThreadOwnerMismatch,
} || thread.Error || capability_space.Error || vmm.VMMError || arch.MmuError || arch.ThreadContextError || physical_memory_authority.Error;

/// Opaque handle for a registered address space.
pub const AddressSpaceHandle = u32;
/// Opaque handle for a registered memory object.
pub const MemoryObjectHandle = u32;
/// Opaque process identifier used for ownership checks.
pub const ProcessHandle = u32;
/// Reserved handle for the initial root process.
pub const ROOT_PROCESS_HANDLE: ProcessHandle = 1;
/// Current execution identity and its uniprocessor accessor.
pub const execution_context = @import("execution_context.zig");
/// Architecture-neutral thread objects and lifecycle policy.
pub const thread = @import("thread.zig");
/// Current-thread termination and user-fault containment policy.
pub const lifecycle = @import("lifecycle.zig");
/// Cooperative FIFO scheduling and current-thread ownership.
pub const scheduler = @import("scheduler/main.zig");
/// Bounded capability-space object identities used by threads.
pub const capability_spaces = capability_space;

const MAP_KNOWN_FLAGS = abi.syscall.MAP_READ | abi.syscall.MAP_WRITE | abi.syscall.MAP_EXECUTE;

/// Creates an address space owned by the root process.
pub fn createAddressSpace() ProcessError!AddressSpaceHandle {
    return createAddressSpaceForOwner(ROOT_PROCESS_HANDLE);
}

/// Creates an address space owned by `owner_process_handle`.
pub fn createAddressSpaceForOwner(owner_process_handle: ProcessHandle) ProcessError!AddressSpaceHandle {
    const hardware_root = try arch.mmu.createAddressSpaceRoot();
    errdefer arch.mmu.destroyAddressSpaceRoot(hardware_root);
    return registerAddressSpaceRootForOwner(owner_process_handle, hardware_root);
}

/// Registers a bootstrap-created hardware root through the normal object path.
pub fn registerAddressSpaceRootForOwner(
    owner_process_handle: ProcessHandle,
    hardware_root: arch.AddressSpaceRoot,
) ProcessError!AddressSpaceHandle {
    return address_space_registry.register(owner_process_handle, hardware_root);
}

/// Returns the address-space object referenced by `handle`.
pub fn getAddressSpace(handle: AddressSpaceHandle) ProcessError!*vmm.AddressSpace {
    return address_space_registry.get(handle);
}

/// Returns the architecture-owned hardware root for an address space.
pub fn getAddressSpaceRoot(handle: AddressSpaceHandle) ProcessError!arch.AddressSpaceRoot {
    return address_space_registry.getRoot(handle);
}

/// Returns the process that owns the address space referenced by `handle`.
pub fn getAddressSpaceOwner(handle: AddressSpaceHandle) ProcessError!ProcessHandle {
    return address_space_registry.getOwner(handle);
}

/// Updates an exact address-space mapping's permissions.
pub fn protectAddressSpace(
    address_space_handle: AddressSpaceHandle,
    virtual_start: u64,
    size_in_bytes: u64,
    permission_flags: u32,
) ProcessError!void {
    const virtual_end = try validateNonEmptyUserVirtualRange(virtual_start, size_in_bytes);
    try address_space_registry.protect(
        address_space_handle,
        virtual_start,
        virtual_end,
        try memoryPermissionsFromFlags(permission_flags),
    );
}

/// Removes an exact mapping from an address space.
pub fn unmapAddressSpace(
    address_space_handle: AddressSpaceHandle,
    virtual_start: u64,
    size_in_bytes: u64,
) ProcessError!void {
    const virtual_end = try validateNonEmptyUserVirtualRange(virtual_start, size_in_bytes);
    const area = try address_space_registry.query(
        address_space_handle,
        virtual_start,
        virtual_end,
    );
    try address_space_registry.unmap(address_space_handle, virtual_start, virtual_end);
    decrementMemoryObjectMapping(area.memory_object_handle);
}

/// Returns requested permission flags for an exact mapping.
pub fn queryAddressSpace(
    address_space_handle: AddressSpaceHandle,
    virtual_start: u64,
    size_in_bytes: u64,
) ProcessError!u32 {
    const virtual_end = try validateNonEmptyUserVirtualRange(virtual_start, size_in_bytes);
    const address_space = try getAddressSpace(address_space_handle);
    const area = try vmm.query(address_space, virtual_start, virtual_end);
    return memoryPermissionFlags(area.permissions);
}

/// Destroys an inactive address space and returns its bounded object slot.
pub fn destroyAddressSpace(address_space_handle: AddressSpaceHandle) ProcessError!void {
    if (thread.referencesAddressSpace(address_space_handle)) {
        return ProcessError.AddressSpaceInUse;
    }
    if (execution_context.current()) |context| {
        if (context.address_space_handle == address_space_handle) {
            return ProcessError.AddressSpaceInUse;
        }
    } else |_| {}

    while (try address_space_registry.lastMapping(address_space_handle)) |mapping| {
        try address_space_registry.unmap(
            address_space_handle,
            mapping.start_address,
            mapping.end_address,
        );
        decrementMemoryObjectMapping(mapping.memory_object_handle);
    }
    try address_space_registry.destroy(address_space_handle);
}

/// Creates an unconfigured thread object owned by `owner_process_handle`.
pub fn createThread(owner_process_handle: ProcessHandle) ProcessError!thread.Handle {
    return thread.create(owner_process_handle);
}

/// Binds a new thread to an existing address space and capability space.
pub fn configureThread(
    thread_handle: thread.Handle,
    configuration: thread.Configuration,
) ProcessError!void {
    const thread_object = try thread.get(thread_handle);
    try capability_space.validate(configuration.capability_space_handle);
    const address_space_owner = try getAddressSpaceOwner(configuration.address_space_handle);
    if (address_space_owner != thread_object.owner_process_handle) {
        return ProcessError.ThreadOwnerMismatch;
    }
    const address_space_root = try getAddressSpaceRoot(configuration.address_space_handle);
    const architecture_context_handle = try arch.thread_context.create(.{
        .address_space_root = address_space_root,
        .entry_point = @intCast(configuration.entry_point),
        .stack_pointer = @intCast(configuration.stack_pointer),
        .argument = @intCast(configuration.argument),
    });
    errdefer arch.thread_context.destroy(architecture_context_handle) catch {};
    try thread.configure(thread_handle, configuration, architecture_context_handle);
}

/// Creates an immutable memory object from generation-checked typed frames.
pub fn createMemoryObjectForOwner(
    owner_process_handle: ProcessHandle,
    authority_handle: physical_memory_authority.Handle,
) ProcessError!MemoryObjectHandle {
    return memory_object_registry.create(owner_process_handle, authority_handle);
}

pub const MemoryObjectInfo = struct {
    physical_start: u64,
    size_in_bytes: u64,
    attributes: u32,
    authority_handle: physical_memory_authority.Handle,
    mapping_count: usize,
};

/// Returns immutable backing identity and current mapping references.
pub fn getMemoryObjectInfo(handle: MemoryObjectHandle) ProcessError!MemoryObjectInfo {
    const info = try memory_object_registry.getInfo(handle);
    return .{
        .physical_start = info.physical_start,
        .size_in_bytes = info.size_in_bytes,
        .attributes = info.attributes,
        .authority_handle = info.authority_handle,
        .mapping_count = info.mapping_count,
    };
}

/// Removes an unmapped memory object from the registry.
pub fn destroyMemoryObject(handle: MemoryObjectHandle) ProcessError!void {
    try memory_object_registry.destroy(handle);
}

/// Forcibly removes every mapping of an object before revocation.
pub fn revokeMemoryObject(handle: MemoryObjectHandle) ProcessError!void {
    _ = try memory_object_registry.getInfo(handle);
    while (address_space_registry.findMappingForMemoryObject(handle)) |mapping| {
        try address_space_registry.unmap(
            mapping.address_space_handle,
            mapping.start_address,
            mapping.end_address,
        );
        memory_object_registry.decrementMapping(handle);
    }
    try memory_object_registry.destroyAfterRevocation(handle);
}

/// Returns the process that owns the memory object referenced by `handle`.
pub fn getMemoryObjectOwner(handle: MemoryObjectHandle) ProcessError!ProcessHandle {
    return memory_object_registry.getOwner(handle);
}

/// Maps a range of a memory object into an address space.
pub fn mapMemoryObject(
    address_space_handle: AddressSpaceHandle,
    memory_object_handle: MemoryObjectHandle,
    virtual_start: u64,
    object_offset: u64,
    size_in_bytes: u64,
    permission_flags: u32,
) ProcessError!void {
    if (size_in_bytes == 0) {
        return ProcessError.EmptyMemoryRange;
    }

    const memory_object = try memory_object_registry.getInfo(memory_object_handle);
    const virtual_end = try validateUserVirtualRange(virtual_start, size_in_bytes);
    try validateObjectRange(memory_object, object_offset, size_in_bytes);

    const physical_start = std.math.add(u64, memory_object.physical_start, object_offset) catch {
        return ProcessError.ObjectRangeOverflow;
    };
    try address_space_registry.mapBackedObject(
        address_space_handle,
        virtual_start,
        virtual_end,
        try memoryPermissionsFromFlags(permission_flags),
        memory_object_handle,
        object_offset,
        physical_start,
    );
    try memory_object_registry.incrementMapping(memory_object_handle);
}

/// Reserves anonymous user memory in an address space.
pub fn mapMemory(address_space_handle: AddressSpaceHandle, virtual_start: u64, size_in_bytes: u64) ProcessError!void {
    const virtual_end = try validateNonEmptyUserVirtualRange(virtual_start, size_in_bytes);

    try address_space_registry.mapAnonymous(address_space_handle, virtual_start, virtual_end, .{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = true,
    });
}

fn validateNonEmptyUserVirtualRange(virtual_start: u64, size_in_bytes: u64) ProcessError!u64 {
    if (size_in_bytes == 0) return ProcessError.EmptyMemoryRange;
    return validateUserVirtualRange(virtual_start, size_in_bytes);
}

fn validateUserVirtualRange(virtual_start: u64, size_in_bytes: u64) ProcessError!u64 {
    const virtual_end = std.math.add(u64, virtual_start, size_in_bytes) catch return ProcessError.MemoryRangeOverflow;
    const kernel_virtual_start = arch.mmu.getKernelVirtualAddressStart();
    if (virtual_start >= kernel_virtual_start or virtual_end > kernel_virtual_start) {
        return ProcessError.KernelAddressRange;
    }
    return virtual_end;
}

fn validateObjectRange(
    memory_object: memory_object_registry.Info,
    object_offset: u64,
    size_in_bytes: u64,
) ProcessError!void {
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    if ((object_offset % page_size != 0) or (size_in_bytes % page_size != 0)) {
        return ProcessError.UnalignedMemoryObjectRange;
    }

    const object_end = std.math.add(u64, object_offset, size_in_bytes) catch return ProcessError.ObjectRangeOverflow;
    if (object_end > memory_object.size_in_bytes) {
        return ProcessError.ObjectRangeOutOfBounds;
    }
}

fn memoryPermissionsFromFlags(permission_flags: u32) ProcessError!vmm.MemoryPermissions {
    if (permission_flags == 0 or (permission_flags & ~MAP_KNOWN_FLAGS) != 0) {
        return ProcessError.InvalidMemoryPermissions;
    }

    return .{
        .readable = (permission_flags & abi.syscall.MAP_READ) != 0,
        .writeable = (permission_flags & abi.syscall.MAP_WRITE) != 0,
        .executable = (permission_flags & abi.syscall.MAP_EXECUTE) != 0,
        .user_accessible = true,
    };
}

fn memoryPermissionFlags(permissions: vmm.MemoryPermissions) u32 {
    var flags: u32 = 0;
    if (permissions.readable) flags |= abi.syscall.MAP_READ;
    if (permissions.writeable) flags |= abi.syscall.MAP_WRITE;
    if (permissions.executable) flags |= abi.syscall.MAP_EXECUTE;
    return flags;
}

fn decrementMemoryObjectMapping(handle: MemoryObjectHandle) void {
    memory_object_registry.decrementMapping(handle);
}

/// Resets all process registry state for unit tests.
pub fn resetForTest() void {
    scheduler.resetForTest();
    capability_space.resetForTest();
    address_space_registry.resetForTest();
    memory_object_registry.resetForTest();
    thread.resetForTest();
}

comptime {
    _ = abi.syscall.INVALID_HANDLE;
}
