//! Capabilities for address spaces, memory objects, and physical-memory authority.

const abi = @import("abi");
const arch = @import("arch");
const std = @import("std");
const authority = @import("../memory_management/physical_memory_authority.zig");
const process = @import("../process/main.zig");
const derivation = @import("derivation.zig");
const errors = @import("errors.zig");
const space = @import("space.zig");
const storage = @import("storage.zig");

pub const CapabilityError = errors.CapabilityError;

const memory_rights: abi.capability.Rights = .{
    .manage = true,
    .read = true,
    .write = true,
    .execute = true,
    .grant = true,
};

pub fn createAddressSpaceCapability(
    space_handle: space.Handle,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try process.createAddressSpaceForOwner(space_handle);
    errdefer process.destroyAddressSpace(object_handle) catch {};
    return storage.commit(prepared, memory_rights, null, .{
        .address_space = object_handle,
    });
}

pub fn registerAddressSpaceRootCapability(
    space_handle: space.Handle,
    hardware_root: arch.AddressSpaceRoot,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try process.registerAddressSpaceRootForOwner(
        space_handle,
        hardware_root,
    );
    return storage.commit(prepared, memory_rights, null, .{
        .address_space = object_handle,
    });
}

pub fn findAddressSpaceCapability(
    space_handle: space.Handle,
    address_space_handle: process.AddressSpaceHandle,
) CapabilityError!abi.capability.CapabilityHandle {
    return storage.findAddressSpace(space_handle, address_space_handle);
}

pub fn destroyAddressSpaceCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const object_handle = try resolveAddressSpace(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    try process.destroyAddressSpace(object_handle);
    try derivation.deleteCapability(space_handle, capability_handle);
}

pub fn createMemoryObjectCapability(
    space_handle: space.Handle,
    frame_capability: abi.capability.CapabilityHandle,
) CapabilityError!abi.capability.CapabilityHandle {
    const frame = try storage.resolve(
        space_handle,
        frame_capability,
        .{ .manage = true },
    );
    const authority_handle = switch (frame.object) {
        .physical_frame => |handle| handle,
        else => return error.InvalidCapabilityType,
    };
    const metadata = try authority.get(authority_handle);
    const object_handle = try process.createMemoryObjectForOwner(
        space_handle,
        authority_handle,
    );
    arch.mmu.zeroPhysicalRange(metadata.physical_start, metadata.size()) catch |err| {
        process.destroyMemoryObject(object_handle) catch {};
        return err;
    };
    storage.replaceObject(
        frame.reference,
        .{ .manage = true },
        .{ .memory_object = object_handle },
    ) catch unreachable;
    return frame_capability;
}

pub fn destroyMemoryObjectCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const object_handle = try resolveMemoryObject(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    const info = try process.getMemoryObjectInfo(object_handle);
    try process.destroyMemoryObject(object_handle);
    try authority.delete(info.authority_handle);
    try storage.clear(reference);
}

pub fn createUntypedMemoryCapability(
    space_handle: space.Handle,
    physical_start: u64,
    size_in_bytes: u64,
    attributes: u32,
    page_size: u64,
) CapabilityError!abi.capability.CapabilityHandle {
    const prepared = try storage.prepareAvailable(space_handle);
    const object_handle = try authority.createRoot(
        physical_start,
        size_in_bytes,
        attributes,
        page_size,
    );
    errdefer authority.destroyBootstrapRoot(object_handle) catch {};
    return storage.commit(prepared, memory_rights, null, .{
        .untyped_memory = object_handle,
    });
}

pub fn retypeUntypedMemoryCapability(
    space_handle: space.Handle,
    source_capability: abi.capability.CapabilityHandle,
    offset: u64,
    page_count: u32,
    target_type: abi.capability.ObjectType,
    rights: abi.capability.Rights,
) CapabilityError!abi.capability.CapabilityHandle {
    const source = try storage.resolve(
        space_handle,
        source_capability,
        .{ .manage = true },
    );
    if (!source.rights.contains(rights)) return error.InvalidCapabilityRights;
    const source_authority = switch (source.object) {
        .untyped_memory => |handle| handle,
        else => return error.InvalidCapabilityType,
    };
    const kind: authority.Kind = switch (target_type) {
        .untyped_memory => .untyped_memory,
        .physical_frame => .physical_frame,
        else => return error.InvalidCapabilityType,
    };
    const prepared = try storage.prepareAvailable(space_handle);
    if (authority.availableCount() == 0) return error.OutOfAuthorities;
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const size = std.math.mul(u64, page_count, page_size) catch {
        return authority.Error.RangeOverflow;
    };
    const object_handle = try authority.derive(
        source_authority,
        offset,
        size,
        kind,
        page_size,
    );
    errdefer authority.delete(object_handle) catch {};
    const object: storage.CapabilityObject = switch (kind) {
        .untyped_memory => .{ .untyped_memory = object_handle },
        .physical_frame => .{ .physical_frame = object_handle },
    };
    return storage.commit(prepared, rights, source.reference, object);
}

pub fn resolveAddressSpace(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!process.AddressSpaceHandle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .address_space => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveMemoryObject(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!process.MemoryObjectHandle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .memory_object => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolveUntypedMemory(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!authority.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .untyped_memory => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn resolvePhysicalFrame(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
    required: abi.capability.Rights,
) CapabilityError!authority.Handle {
    return switch ((try storage.resolve(space_handle, capability_handle, required)).object) {
        .physical_frame => |handle| handle,
        else => error.InvalidCapabilityType,
    };
}

pub fn destroyUntypedMemoryCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    try authority.destroyBootstrapRoot(try resolveUntypedMemory(
        space_handle,
        capability_handle,
        .{ .manage = true },
    ));
    try storage.clear(storage.ref(space_handle, capability_handle));
}

pub fn deletePhysicalMemoryCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const reference = storage.ref(space_handle, capability_handle);
    const slot = try storage.resolve(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    const object_handle = authorityHandle(slot.object) orelse {
        return error.InvalidCapabilityType;
    };
    if (derivation.hasChild(reference)) return error.CapabilityHasDescendants;
    try authority.delete(object_handle);
    try storage.clear(reference);
}

pub fn revokePhysicalMemoryCapability(
    space_handle: space.Handle,
    capability_handle: abi.capability.CapabilityHandle,
) CapabilityError!void {
    const ancestor = storage.ref(space_handle, capability_handle);
    const slot = try storage.resolve(
        space_handle,
        capability_handle,
        .{ .manage = true },
    );
    if (authorityHandle(slot.object) == null) return error.InvalidCapabilityType;
    while (derivation.leafDescendant(ancestor)) |descendant| {
        const descendant_slot = try storage.resolve(
            descendant.space_handle,
            descendant.capability_handle,
            .{},
        );
        const object_handle = switch (descendant_slot.object) {
            .memory_object => |memory_object| blk: {
                const info = try process.getMemoryObjectInfo(memory_object);
                try process.revokeMemoryObject(memory_object);
                break :blk info.authority_handle;
            },
            else => authorityHandle(descendant_slot.object) orelse {
                return error.InvalidCapabilityType;
            },
        };
        if (countAuthorityReferences(object_handle) == 1) {
            try authority.delete(object_handle);
        }
        try storage.clear(descendant);
    }
}

fn countAuthorityReferences(target_authority: authority.Handle) usize {
    var count: usize = 0;
    for (0..space.MAX_CAPABILITY_SPACES) |table_index| {
        for (0..storage.MAX_CAPABILITIES) |slot_index| {
            const object = storage.activeObjectAt(table_index, slot_index) orelse continue;
            switch (object) {
                .untyped_memory, .physical_frame => |handle| {
                    if (handle == target_authority) count += 1;
                },
                .memory_object => |memory_object| {
                    if (process.getMemoryObjectInfo(memory_object)) |info| {
                        if (info.authority_handle == target_authority) count += 1;
                    } else |_| {}
                },
                else => {},
            }
        }
    }
    return count;
}

fn authorityHandle(object: storage.CapabilityObject) ?authority.Handle {
    return switch (object) {
        .untyped_memory => |handle| handle,
        .physical_frame => |handle| handle,
        else => null,
    };
}
