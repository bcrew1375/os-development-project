const abi = @import("abi");

pub const AddressSpace = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const MemoryObject = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const UntypedMemory = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const PhysicalFrame = struct {
    capability: abi.capability.CapabilityHandle,
};

pub const Error = error{
    InvalidCapability,
    InsufficientRights,
    OutOfResources,
    InvalidRange,
    InvalidPermissions,
    MappingNotFound,
    AddressSpaceInUse,
    Unsupported,
    InternalFailure,
};

pub const MAP_READ = abi.syscall.MAP_READ;
pub const MAP_WRITE = abi.syscall.MAP_WRITE;
pub const MAP_EXECUTE = abi.syscall.MAP_EXECUTE;

pub fn MemoryManager(comptime Transport: type) type {
    return struct {
        pub fn currentAddressSpace() Error!AddressSpace {
            return addressSpaceResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.current_address_space),
                0,
                0,
                0,
            ));
        }

        pub fn createAddressSpace() Error!AddressSpace {
            return addressSpaceResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_address_space),
                0,
                0,
                0,
            ));
        }

        pub fn mapRegion(
            address_space: AddressSpace,
            virtual_start: usize,
            size_in_bytes: usize,
        ) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.map_memory),
                address_space.capability,
                virtual_start,
                size_in_bytes,
            ));
        }

        pub fn protectAddressSpace(
            address_space: AddressSpace,
            virtual_start: usize,
            size_in_bytes: usize,
            permission_flags: u32,
        ) Error!void {
            try voidResult(Transport.syscall5(
                @intFromEnum(abi.syscall.SyscallNumber.protect_address_space),
                address_space.capability,
                virtual_start,
                size_in_bytes,
                permission_flags,
                0,
            ));
        }

        pub fn queryAddressSpace(
            address_space: AddressSpace,
            virtual_start: usize,
            size_in_bytes: usize,
        ) Error!u32 {
            const result = Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.query_address_space),
                address_space.capability,
                virtual_start,
                size_in_bytes,
            );
            try checkError(result);
            if (result == 0) return Error.InternalFailure;
            return result;
        }

        pub fn unmapAddressSpace(
            address_space: AddressSpace,
            virtual_start: usize,
            size_in_bytes: usize,
        ) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.unmap_address_space),
                address_space.capability,
                virtual_start,
                size_in_bytes,
            ));
        }

        pub fn destroyAddressSpace(address_space: AddressSpace) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.destroy_address_space),
                address_space.capability,
                0,
                0,
            ));
        }

        pub fn createMemoryObject(frame: PhysicalFrame) Error!MemoryObject {
            const result = Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.create_memory_object),
                frame.capability,
                0,
                0,
            );
            try checkError(result);
            if (result == abi.capability.INVALID_CAPABILITY) return Error.InternalFailure;
            return .{ .capability = result };
        }

        pub fn destroyMemoryObject(memory_object: MemoryObject) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.destroy_memory_object),
                memory_object.capability,
                0,
                0,
            ));
        }

        pub fn mapMemoryObject(
            address_space: AddressSpace,
            memory_object: MemoryObject,
            virtual_start: usize,
            size_in_bytes: usize,
            permission_flags: u32,
        ) Error!void {
            try voidResult(Transport.syscall5(
                @intFromEnum(abi.syscall.SyscallNumber.map_memory_object),
                address_space.capability,
                memory_object.capability,
                virtual_start,
                size_in_bytes,
                permission_flags,
            ));
        }

        pub fn retypeUntypedMemory(
            source: UntypedMemory,
            offset: u64,
            page_count: u32,
            rights: abi.capability.Rights,
        ) Error!UntypedMemory {
            return .{ .capability = try retypePhysicalMemory(
                source,
                offset,
                page_count,
                .untyped_memory,
                rights,
            ) };
        }

        pub fn retypePhysicalFrames(
            source: UntypedMemory,
            offset: u64,
            page_count: u32,
            rights: abi.capability.Rights,
        ) Error!PhysicalFrame {
            return .{ .capability = try retypePhysicalMemory(
                source,
                offset,
                page_count,
                .physical_frame,
                rights,
            ) };
        }

        pub fn deletePhysicalMemory(memory: anytype) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.delete_physical_memory),
                physicalMemoryCapability(memory),
                0,
                0,
            ));
        }

        pub fn revokePhysicalMemory(memory: anytype) Error!void {
            try voidResult(Transport.syscall3(
                @intFromEnum(abi.syscall.SyscallNumber.revoke_physical_memory),
                physicalMemoryCapability(memory),
                0,
                0,
            ));
        }

        fn retypePhysicalMemory(
            source: UntypedMemory,
            offset: u64,
            page_count: u32,
            target_type: abi.capability.ObjectType,
            rights: abi.capability.Rights,
        ) Error!abi.capability.CapabilityHandle {
            const result = Transport.syscall5(
                @intFromEnum(abi.syscall.SyscallNumber.retype_untyped_memory),
                source.capability,
                abi.syscall.lowU32(offset),
                abi.syscall.highU32(offset),
                page_count,
                abi.syscall.packRetypeTarget(target_type, rights),
            );
            try checkError(result);
            if (result == abi.capability.INVALID_CAPABILITY) return Error.InternalFailure;
            return result;
        }

        fn physicalMemoryCapability(memory: anytype) abi.capability.CapabilityHandle {
            const Memory = @TypeOf(memory);
            if (Memory != UntypedMemory and Memory != PhysicalFrame) {
                @compileError("physical-memory operation requires UntypedMemory or PhysicalFrame");
            }
            return memory.capability;
        }

        fn addressSpaceResult(result: u32) Error!AddressSpace {
            try checkError(result);
            if (result == abi.capability.INVALID_CAPABILITY) return Error.InternalFailure;
            return .{ .capability = result };
        }

        fn voidResult(result: u32) Error!void {
            try checkError(result);
            if (result != abi.syscall.SYSCALL_SUCCESS) return Error.InternalFailure;
        }

        fn checkError(result: u32) Error!void {
            const code = abi.syscall.decodeError(result) orelse return;
            return switch (code) {
                .invalid_capability => Error.InvalidCapability,
                .insufficient_rights => Error.InsufficientRights,
                .out_of_resources => Error.OutOfResources,
                .invalid_range => Error.InvalidRange,
                .invalid_permissions => Error.InvalidPermissions,
                .mapping_not_found => Error.MappingNotFound,
                .address_space_in_use => Error.AddressSpaceInUse,
                .unsupported => Error.Unsupported,
                .internal_failure => Error.InternalFailure,
            };
        }
    };
}

const NativeTransport = struct {
    pub const syscall3 = abi.syscall.syscall3;
    pub const syscall5 = abi.syscall.syscall5;
};

const native = MemoryManager(NativeTransport);

pub const currentAddressSpace = native.currentAddressSpace;
pub const createAddressSpace = native.createAddressSpace;
pub const mapRegion = native.mapRegion;
pub const protectAddressSpace = native.protectAddressSpace;
pub const queryAddressSpace = native.queryAddressSpace;
pub const unmapAddressSpace = native.unmapAddressSpace;
pub const destroyAddressSpace = native.destroyAddressSpace;
pub const createMemoryObject = native.createMemoryObject;
pub const mapMemoryObject = native.mapMemoryObject;
pub const destroyMemoryObject = native.destroyMemoryObject;
pub const retypeUntypedMemory = native.retypeUntypedMemory;
pub const retypePhysicalFrames = native.retypePhysicalFrames;
pub const deletePhysicalMemory = native.deletePhysicalMemory;
pub const revokePhysicalMemory = native.revokePhysicalMemory;
