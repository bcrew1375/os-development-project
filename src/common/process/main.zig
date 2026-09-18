//! Minimal process, address-space, and memory-object registry.

const abi = @import("abi");
const arch = @import("arch");
const std = @import("std");
const vmm = @import("../memory_management/vmm.zig");

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
} || vmm.VMMError;

/// Opaque handle for a registered address space.
pub const AddressSpaceHandle = u32;
/// Opaque handle for a registered memory object.
pub const MemoryObjectHandle = u32;
/// Opaque process identifier used for ownership checks.
pub const ProcessHandle = u32;
/// Reserved handle for the initial root process.
pub const ROOT_PROCESS_HANDLE: ProcessHandle = 1;

const MAX_ADDRESS_SPACES = 16;
const MAX_MEMORY_OBJECTS = 64;
const MAX_VMAS_PER_ADDRESS_SPACE = 32;
const MAP_KNOWN_FLAGS = abi.syscall.MAP_READ | abi.syscall.MAP_WRITE | abi.syscall.MAP_EXECUTE;

const AddressSpaceSlot = struct {
    handle: AddressSpaceHandle = abi.syscall.INVALID_HANDLE,
    owner_process_handle: ProcessHandle = 0,
    address_space: vmm.AddressSpace = .{},
    vma_backing: [MAX_VMAS_PER_ADDRESS_SPACE]vmm.VirtualMemoryArea = undefined,
    used: bool = false,
};

const MemoryObjectSlot = struct {
    handle: MemoryObjectHandle = abi.syscall.INVALID_HANDLE,
    owner_process_handle: ProcessHandle = 0,
    size_in_bytes: u64 = 0,
    used: bool = false,
};

var nextAddressSpaceHandle: AddressSpaceHandle = 1;
var nextMemoryObjectHandle: MemoryObjectHandle = 1;
var addressSpaceSlots: [MAX_ADDRESS_SPACES]AddressSpaceSlot = [_]AddressSpaceSlot{.{}} ** MAX_ADDRESS_SPACES;
var memoryObjectSlots: [MAX_MEMORY_OBJECTS]MemoryObjectSlot = [_]MemoryObjectSlot{.{}} ** MAX_MEMORY_OBJECTS;

/// Creates an address space owned by the root process.
pub fn createAddressSpace() ProcessError!AddressSpaceHandle {
    return createAddressSpaceForOwner(ROOT_PROCESS_HANDLE);
}

/// Creates an address space owned by `owner_process_handle`.
pub fn createAddressSpaceForOwner(owner_process_handle: ProcessHandle) ProcessError!AddressSpaceHandle {
    const slot = findFreeAddressSpaceSlot() orelse return ProcessError.OutOfAddressSpaces;

    const handle = nextAddressSpaceHandle;
    nextAddressSpaceHandle += 1;

    slot.handle = handle;
    slot.owner_process_handle = owner_process_handle;
    slot.address_space = .{
        .virtual_memory_areas = &slot.vma_backing,
        .length = 0,
    };
    slot.used = true;

    return handle;
}

/// Returns the address-space object referenced by `handle`.
pub fn getAddressSpace(handle: AddressSpaceHandle) ProcessError!*vmm.AddressSpace {
    const slot = findAddressSpaceSlot(handle) orelse return ProcessError.InvalidAddressSpaceHandle;
    return &slot.address_space;
}

/// Returns the process that owns the address space referenced by `handle`.
pub fn getAddressSpaceOwner(handle: AddressSpaceHandle) ProcessError!ProcessHandle {
    const slot = findAddressSpaceSlot(handle) orelse {
        return ProcessError.InvalidAddressSpaceHandle;
    };
    return slot.owner_process_handle;
}

/// Creates a page-aligned memory object owned by the root process.
pub fn createMemoryObject(size_in_bytes: u64) ProcessError!MemoryObjectHandle {
    return createMemoryObjectForOwner(ROOT_PROCESS_HANDLE, size_in_bytes);
}

/// Creates a page-aligned memory object owned by `owner_process_handle`.
pub fn createMemoryObjectForOwner(owner_process_handle: ProcessHandle, size_in_bytes: u64) ProcessError!MemoryObjectHandle {
    if (size_in_bytes == 0) {
        return ProcessError.EmptyMemoryRange;
    }

    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    if (size_in_bytes % page_size != 0) {
        return ProcessError.UnalignedMemoryObjectRange;
    }

    const slot = findFreeMemoryObjectSlot() orelse return ProcessError.OutOfMemoryObjects;

    const handle = nextMemoryObjectHandle;
    nextMemoryObjectHandle += 1;

    slot.* = .{
        .handle = handle,
        .owner_process_handle = owner_process_handle,
        .size_in_bytes = size_in_bytes,
        .used = true,
    };

    return handle;
}

/// Returns the process that owns the memory object referenced by `handle`.
pub fn getMemoryObjectOwner(handle: MemoryObjectHandle) ProcessError!ProcessHandle {
    const slot = findMemoryObjectSlot(handle) orelse {
        return ProcessError.InvalidMemoryObjectHandle;
    };
    return slot.owner_process_handle;
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

    const memory_object = findMemoryObjectSlot(memory_object_handle) orelse return ProcessError.InvalidMemoryObjectHandle;
    const virtual_end = try validateUserVirtualRange(virtual_start, size_in_bytes);
    try validateObjectRange(memory_object, object_offset, size_in_bytes);

    const address_space = try getAddressSpace(address_space_handle);
    try vmm.mapObject(
        address_space,
        virtual_start,
        virtual_end,
        try memoryPermissionsFromFlags(permission_flags),
        memory_object_handle,
        object_offset,
    );
}

/// Reserves anonymous user memory in an address space.
pub fn mapMemory(address_space_handle: AddressSpaceHandle, virtual_start: u64, size_in_bytes: u64) ProcessError!void {
    if (size_in_bytes == 0) {
        return ProcessError.EmptyMemoryRange;
    }

    const virtual_end = try validateUserVirtualRange(virtual_start, size_in_bytes);

    const address_space = try getAddressSpace(address_space_handle);
    try vmm.map(address_space, virtual_start, virtual_end, .{
        .readable = true,
        .writeable = true,
        .executable = false,
        .user_accessible = true,
    });
}

fn validateUserVirtualRange(virtual_start: u64, size_in_bytes: u64) ProcessError!u64 {
    const virtual_end = std.math.add(u64, virtual_start, size_in_bytes) catch return ProcessError.MemoryRangeOverflow;
    const kernel_virtual_start = arch.mmu.getKernelVirtualAddressStart();
    if (virtual_start >= kernel_virtual_start or virtual_end > kernel_virtual_start) {
        return ProcessError.KernelAddressRange;
    }
    return virtual_end;
}

fn validateObjectRange(memory_object: *const MemoryObjectSlot, object_offset: u64, size_in_bytes: u64) ProcessError!void {
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

fn findFreeAddressSpaceSlot() ?*AddressSpaceSlot {
    for (&addressSpaceSlots) |*slot| {
        if (!slot.used) return slot;
    }
    return null;
}

fn findAddressSpaceSlot(handle: AddressSpaceHandle) ?*AddressSpaceSlot {
    if (handle == abi.syscall.INVALID_HANDLE) return null;

    for (&addressSpaceSlots) |*slot| {
        if (slot.used and slot.handle == handle) return slot;
    }
    return null;
}

fn findFreeMemoryObjectSlot() ?*MemoryObjectSlot {
    for (&memoryObjectSlots) |*slot| {
        if (!slot.used) return slot;
    }
    return null;
}

fn findMemoryObjectSlot(handle: MemoryObjectHandle) ?*MemoryObjectSlot {
    if (handle == abi.syscall.INVALID_HANDLE) return null;

    for (&memoryObjectSlots) |*slot| {
        if (slot.used and slot.handle == handle) return slot;
    }
    return null;
}

/// Resets all process registry state for unit tests.
pub fn resetForTest() void {
    nextAddressSpaceHandle = 1;
    nextMemoryObjectHandle = 1;
    for (&addressSpaceSlots) |*slot| {
        slot.* = .{};
    }
    for (&memoryObjectSlots) |*slot| {
        slot.* = .{};
    }
}

comptime {
    _ = abi.syscall.INVALID_HANDLE;
}
