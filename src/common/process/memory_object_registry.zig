//! Fixed-capacity frame-backed memory-object storage and reference accounting.

const abi = @import("abi");
const std = @import("std");
const physical_memory_authority = @import("../memory_management/physical_memory_authority.zig");

pub const Handle = u32;
pub const ProcessHandle = u32;

pub const Error = error{
    OutOfMemoryObjects,
    InvalidMemoryObjectHandle,
    MemoryObjectInUse,
};

pub const Info = struct {
    physical_start: u64,
    size_in_bytes: u64,
    attributes: u32,
    authority_handle: physical_memory_authority.Handle,
    mapping_count: usize,
};

const MAX_MEMORY_OBJECTS = 64;

const Slot = struct {
    handle: Handle = abi.syscall.INVALID_HANDLE,
    owner_process_handle: ProcessHandle = 0,
    size_in_bytes: u64 = 0,
    physical_start: u64 = 0,
    attributes: u32 = 0,
    authority_handle: physical_memory_authority.Handle = physical_memory_authority.INVALID_HANDLE,
    mapping_count: usize = 0,
    used: bool = false,
};

var next_handle: Handle = 1;
var slots: [MAX_MEMORY_OBJECTS]Slot = [_]Slot{.{}} ** MAX_MEMORY_OBJECTS;

pub fn create(
    owner_process_handle: ProcessHandle,
    authority_handle: physical_memory_authority.Handle,
) (Error || physical_memory_authority.Error)!Handle {
    const slot = findFreeSlot() orelse return error.OutOfMemoryObjects;
    const authority = try physical_memory_authority.get(authority_handle);
    if (authority.kind != .physical_frame) {
        return physical_memory_authority.Error.InvalidAuthorityKind;
    }
    const handle = next_handle;
    next_handle += 1;
    slot.* = .{
        .handle = handle,
        .owner_process_handle = owner_process_handle,
        .size_in_bytes = authority.size(),
        .physical_start = authority.physical_start,
        .attributes = authority.attributes,
        .authority_handle = authority_handle,
        .used = true,
    };
    return handle;
}

pub fn getInfo(handle: Handle) Error!Info {
    const slot = try resolve(handle);
    return .{
        .physical_start = slot.physical_start,
        .size_in_bytes = slot.size_in_bytes,
        .attributes = slot.attributes,
        .authority_handle = slot.authority_handle,
        .mapping_count = slot.mapping_count,
    };
}

pub fn getOwner(handle: Handle) Error!ProcessHandle {
    return (try resolve(handle)).owner_process_handle;
}

pub fn incrementMapping(handle: Handle) Error!void {
    (try resolve(handle)).mapping_count += 1;
}

pub fn decrementMapping(handle: Handle) void {
    if (handle == abi.syscall.INVALID_HANDLE) return;
    const slot = resolve(handle) catch return;
    std.debug.assert(slot.mapping_count > 0);
    slot.mapping_count -= 1;
}

pub fn destroy(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.mapping_count != 0) return error.MemoryObjectInUse;
    slot.* = .{};
}

pub fn destroyAfterRevocation(handle: Handle) Error!void {
    const slot = try resolve(handle);
    if (slot.mapping_count != 0) return error.MemoryObjectInUse;
    slot.* = .{};
}

pub fn resetForTest() void {
    next_handle = 1;
    for (&slots) |*slot| slot.* = .{};
}

fn resolve(handle: Handle) Error!*Slot {
    if (handle == abi.syscall.INVALID_HANDLE) return error.InvalidMemoryObjectHandle;
    for (&slots) |*slot| {
        if (slot.used and slot.handle == handle) return slot;
    }
    return error.InvalidMemoryObjectHandle;
}

fn findFreeSlot() ?*Slot {
    for (&slots) |*slot| {
        if (!slot.used) return slot;
    }
    return null;
}

comptime {
    _ = abi.syscall.INVALID_HANDLE;
}
