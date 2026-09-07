const abi = @import("abi");

pub const AddressSpace = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const MemoryObject = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const MAP_READ = abi.syscall.MAP_READ;
pub const MAP_WRITE = abi.syscall.MAP_WRITE;
pub const MAP_EXECUTE = abi.syscall.MAP_EXECUTE;

pub fn createAddressSpace() ?AddressSpace {
    const capability = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_address_space),
        0,
        0,
        0,
    );

    if (capability == abi.capability.INVALID_CAPABILITY) {
        return null;
    }

    return .{ .capability = capability };
}

pub fn mapRegion(address_space: AddressSpace, virtual_start: usize, size_in_bytes: usize) bool {
    const result = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.map_memory),
        address_space.capability,
        virtual_start,
        size_in_bytes,
    );

    return result == abi.syscall.SYSCALL_SUCCESS;
}

pub fn createMemoryObject(size_in_bytes: usize) ?MemoryObject {
    const capability = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.create_memory_object),
        size_in_bytes,
        0,
        0,
    );

    if (capability == abi.capability.INVALID_CAPABILITY) {
        return null;
    }

    return .{ .capability = capability };
}

pub fn mapMemoryObject(
    address_space: AddressSpace,
    memory_object: MemoryObject,
    virtual_start: usize,
    size_in_bytes: usize,
    permission_flags: u32,
) bool {
    const result = abi.syscall.syscall5(
        @intFromEnum(abi.syscall.SyscallNumber.map_memory_object),
        address_space.capability,
        memory_object.capability,
        virtual_start,
        size_in_bytes,
        permission_flags,
    );

    return result == abi.syscall.SYSCALL_SUCCESS;
}
