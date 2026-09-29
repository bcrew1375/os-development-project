//! Fixed-capacity address-space object storage and local mapping mechanisms.

const abi = @import("abi");
const arch = @import("arch");
const vmm = @import("../memory_management/vmm.zig");

pub const Handle = u32;
pub const ProcessHandle = u32;

pub const Error = error{
    OutOfAddressSpaces,
    InvalidAddressSpaceHandle,
};

pub const Mapping = struct {
    address_space_handle: Handle,
    start_address: u64,
    end_address: u64,
    memory_object_handle: u32,
};

const MAX_ADDRESS_SPACES = 16;
const MAX_VMAS_PER_ADDRESS_SPACE = 32;

const Slot = struct {
    handle: Handle = abi.syscall.INVALID_HANDLE,
    owner_process_handle: ProcessHandle = 0,
    address_space: vmm.AddressSpace = .{},
    hardware_root: arch.AddressSpaceRoot = .{ .value = 0 },
    vma_backing: [MAX_VMAS_PER_ADDRESS_SPACE]vmm.VirtualMemoryArea = undefined,
    used: bool = false,
};

var next_handle: Handle = 1;
var slots: [MAX_ADDRESS_SPACES]Slot = [_]Slot{.{}} ** MAX_ADDRESS_SPACES;

pub fn register(
    owner_process_handle: ProcessHandle,
    hardware_root: arch.AddressSpaceRoot,
) Error!Handle {
    const slot = findFreeSlot() orelse return error.OutOfAddressSpaces;
    const handle = next_handle;
    next_handle += 1;

    slot.* = .{
        .handle = handle,
        .owner_process_handle = owner_process_handle,
        .address_space = .{
            .virtual_memory_areas = &slot.vma_backing,
            .length = 0,
        },
        .hardware_root = hardware_root,
        .used = true,
    };
    return handle;
}

pub fn get(handle: Handle) Error!*vmm.AddressSpace {
    return &(try resolve(handle)).address_space;
}

pub fn getRoot(handle: Handle) Error!arch.AddressSpaceRoot {
    return (try resolve(handle)).hardware_root;
}

pub fn getOwner(handle: Handle) Error!ProcessHandle {
    return (try resolve(handle)).owner_process_handle;
}

pub fn protect(
    handle: Handle,
    virtual_start: u64,
    virtual_end: u64,
    permissions: vmm.MemoryPermissions,
) (Error || vmm.VMMError || arch.MmuError)!void {
    const slot = try resolve(handle);
    try vmm.protectInAddressSpace(
        slot.hardware_root,
        &slot.address_space,
        virtual_start,
        virtual_end,
        permissions,
    );
}

pub fn query(handle: Handle, virtual_start: u64, virtual_end: u64) (Error || vmm.VMMError)!vmm.VirtualMemoryArea {
    const slot = try resolve(handle);
    return vmm.query(&slot.address_space, virtual_start, virtual_end);
}

pub fn mapBackedObject(
    handle: Handle,
    virtual_start: u64,
    virtual_end: u64,
    permissions: vmm.MemoryPermissions,
    memory_object_handle: u32,
    object_offset: u64,
    physical_start: u64,
) (Error || vmm.VMMError || arch.MmuError)!void {
    const slot = try resolve(handle);
    try vmm.mapBackedObjectInAddressSpace(
        slot.hardware_root,
        &slot.address_space,
        virtual_start,
        virtual_end,
        permissions,
        memory_object_handle,
        object_offset,
        physical_start,
    );
}

pub fn mapAnonymous(
    handle: Handle,
    virtual_start: u64,
    virtual_end: u64,
    permissions: vmm.MemoryPermissions,
) (Error || vmm.VMMError)!void {
    const slot = try resolve(handle);
    try vmm.map(&slot.address_space, virtual_start, virtual_end, permissions);
}

pub fn unmap(
    handle: Handle,
    virtual_start: u64,
    virtual_end: u64,
) (Error || vmm.VMMError || arch.MmuError)!void {
    const slot = try resolve(handle);
    try vmm.unmapInAddressSpace(
        slot.hardware_root,
        &slot.address_space,
        virtual_start,
        virtual_end,
    );
}

pub fn lastMapping(handle: Handle) Error!?Mapping {
    const slot = try resolve(handle);
    if (slot.address_space.length == 0) return null;
    const area = slot.address_space.virtual_memory_areas[slot.address_space.length - 1];
    return mappingFromArea(slot.handle, area);
}

pub fn findMappingForMemoryObject(memory_object_handle: u32) ?Mapping {
    for (&slots) |*slot| {
        if (!slot.used) continue;
        for (slot.address_space.virtual_memory_areas[0..slot.address_space.length]) |area| {
            if (area.memory_object_handle == memory_object_handle) {
                return mappingFromArea(slot.handle, area);
            }
        }
    }
    return null;
}

pub fn destroy(handle: Handle) (Error || arch.MmuError)!void {
    const slot = try resolve(handle);
    arch.mmu.destroyAddressSpaceRoot(slot.hardware_root);
    slot.* = .{};
}

pub fn resetForTest() void {
    next_handle = 1;
    for (&slots) |*slot| slot.* = .{};
}

fn resolve(handle: Handle) Error!*Slot {
    if (handle == abi.syscall.INVALID_HANDLE) return error.InvalidAddressSpaceHandle;
    for (&slots) |*slot| {
        if (slot.used and slot.handle == handle) return slot;
    }
    return error.InvalidAddressSpaceHandle;
}

fn findFreeSlot() ?*Slot {
    for (&slots) |*slot| {
        if (!slot.used) return slot;
    }
    return null;
}

fn mappingFromArea(address_space_handle: Handle, area: vmm.VirtualMemoryArea) Mapping {
    return .{
        .address_space_handle = address_space_handle,
        .start_address = area.start_address,
        .end_address = area.end_address,
        .memory_object_handle = area.memory_object_handle,
    };
}

comptime {
    _ = abi.syscall.INVALID_HANDLE;
}
