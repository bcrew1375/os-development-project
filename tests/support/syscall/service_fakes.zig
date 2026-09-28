const abi = @import("abi");
const kernel = @import("kernel_common");

pub const RecordingServices = struct {
    const State = struct {
        call_count: usize = 0,
        caller_process_handle: u32 = 0,
        address_space_capability: u32 = 0,
        memory_object_capability: u32 = 0,
        address_space_rights: abi.capability.Rights = .{},
        memory_object_rights: abi.capability.Rights = .{},
        object_size_in_bytes: u64 = 0,
        virtual_start: u64 = 0,
        object_offset: u64 = 0,
        size_in_bytes: u64 = 0,
        permission_flags: u32 = 0,
        physical_memory_capability: u32 = 0,
        physical_offset: u64 = 0,
        page_count: u32 = 0,
        target_type: abi.capability.ObjectType = .null,
        physical_memory_rights: abi.capability.Rights = .{},
    };

    pub var state: State = .{};

    pub fn reset() void {
        state = .{};
    }

    pub fn currentAddressSpaceHandle() !u32 {
        state.call_count += 1;
        return 107;
    }

    pub fn findAddressSpaceCapability(caller_process_handle: u32, address_space_handle: u32) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.address_space_capability = address_space_handle;
        return 77;
    }

    pub fn createAddressSpaceCapability(caller_process_handle: u32) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        return 77;
    }

    pub fn resolveAddressSpace(caller_process_handle: u32, handle: u32, rights: abi.capability.Rights) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.address_space_capability = handle;
        state.address_space_rights = rights;
        return 107;
    }

    pub fn mapMemory(_: u32, virtual_start: u64, size_in_bytes: u64) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
    }

    pub fn createMemoryObjectCapability(caller_process_handle: u32, size_in_bytes: u64) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.object_size_in_bytes = size_in_bytes;
        return 88;
    }

    pub fn resolveMemoryObject(caller_process_handle: u32, handle: u32, rights: abi.capability.Rights) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.memory_object_capability = handle;
        state.memory_object_rights = rights;
        return 109;
    }

    pub fn mapMemoryObject(
        _: u32,
        _: u32,
        virtual_start: u64,
        object_offset: u64,
        size_in_bytes: u64,
        permission_flags: u32,
    ) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.object_offset = object_offset;
        state.size_in_bytes = size_in_bytes;
        state.permission_flags = permission_flags;
    }

    pub fn protectAddressSpace(_: u32, virtual_start: u64, size_in_bytes: u64, permission_flags: u32) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
        state.permission_flags = permission_flags;
    }

    pub fn queryAddressSpace(_: u32, virtual_start: u64, size_in_bytes: u64) !u32 {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
        return abi.syscall.MAP_READ | abi.syscall.MAP_WRITE;
    }

    pub fn unmapAddressSpace(_: u32, virtual_start: u64, size_in_bytes: u64) !void {
        state.call_count += 1;
        state.virtual_start = virtual_start;
        state.size_in_bytes = size_in_bytes;
    }

    pub fn destroyAddressSpaceCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.address_space_capability = handle;
    }

    pub fn destroyMemoryObjectCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.memory_object_capability = handle;
    }

    pub fn retypeUntypedMemoryCapability(
        caller_process_handle: u32,
        source_capability: u32,
        offset: u64,
        page_count: u32,
        target_type: abi.capability.ObjectType,
        rights: abi.capability.Rights,
    ) !u32 {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.physical_memory_capability = source_capability;
        state.physical_offset = offset;
        state.page_count = page_count;
        state.target_type = target_type;
        state.physical_memory_rights = rights;
        return 99;
    }

    pub fn deletePhysicalMemoryCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.physical_memory_capability = handle;
    }

    pub fn revokePhysicalMemoryCapability(caller_process_handle: u32, handle: u32) !void {
        state.call_count += 1;
        state.caller_process_handle = caller_process_handle;
        state.physical_memory_capability = handle;
    }
};

pub const FailingServices = struct {
    pub var failure_operation: kernel.syscall.Operation = .create_address_space;

    pub fn currentAddressSpaceHandle() !u32 {
        if (failure_operation == .current_address_space) return error.ExecutionContextUninitialized;
        return 1;
    }

    pub fn findAddressSpaceCapability(_: u32, _: u32) !u32 {
        if (failure_operation == .current_address_space) return error.InvalidCapability;
        return 1;
    }

    pub fn createAddressSpaceCapability(_: u32) !u32 {
        if (failure_operation == .create_address_space) return error.OutOfAddressSpaces;
        return 1;
    }

    pub fn resolveAddressSpace(_: u32, _: u32, _: abi.capability.Rights) !u32 {
        if (failure_operation == .resolve_address_space) return error.InvalidCapability;
        return 1;
    }

    pub fn mapMemory(_: u32, _: u64, _: u64) !void {
        if (failure_operation == .map_memory) return error.MemoryRangeOverflow;
    }

    pub fn createMemoryObjectCapability(_: u32, _: u64) !u32 {
        if (failure_operation == .create_memory_object) return error.OutOfMemoryObjects;
        return 2;
    }

    pub fn resolveMemoryObject(_: u32, _: u32, _: abi.capability.Rights) !u32 {
        if (failure_operation == .resolve_memory_object) return error.InsufficientCapabilityRights;
        return 2;
    }

    pub fn mapMemoryObject(_: u32, _: u32, _: u64, _: u64, _: u64, _: u32) !void {
        if (failure_operation == .map_memory_object) return error.ObjectRangeOutOfBounds;
    }

    pub fn protectAddressSpace(_: u32, _: u64, _: u64, _: u32) !void {
        if (failure_operation == .protect_address_space) return error.InvalidMemoryPermissions;
    }

    pub fn queryAddressSpace(_: u32, _: u64, _: u64) !u32 {
        if (failure_operation == .query_address_space) return error.UndefinedVirtualMemoryArea;
        return abi.syscall.MAP_READ;
    }

    pub fn unmapAddressSpace(_: u32, _: u64, _: u64) !void {
        if (failure_operation == .unmap_address_space) return error.UndefinedVirtualMemoryArea;
    }

    pub fn destroyAddressSpaceCapability(_: u32, _: u32) !void {
        if (failure_operation == .destroy_address_space) return error.AddressSpaceInUse;
    }

    pub fn destroyMemoryObjectCapability(_: u32, _: u32) !void {
        if (failure_operation == .destroy_memory_object) return error.MemoryObjectInUse;
    }

    pub fn retypeUntypedMemoryCapability(
        _: u32,
        _: u32,
        _: u64,
        _: u32,
        _: abi.capability.ObjectType,
        _: abi.capability.Rights,
    ) !u32 {
        if (failure_operation == .retype_untyped_memory) return error.OverlappingAuthority;
        return 3;
    }

    pub fn deletePhysicalMemoryCapability(_: u32, _: u32) !void {
        if (failure_operation == .delete_physical_memory) return error.CapabilityHasDescendants;
    }

    pub fn revokePhysicalMemoryCapability(_: u32, _: u32) !void {
        if (failure_operation == .revoke_physical_memory) return error.InvalidCapability;
    }
};
