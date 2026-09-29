const abi = @import("abi");
const memory_management = @import("memory_management");
const process_management = @import("process_management");

const AddressSpace = memory_management.operations.AddressSpace;
const AllocationHandle = memory_management.PhysicalRangeAllocator.AllocationHandle;
const MemoryObject = memory_management.operations.MemoryObject;

pub fn Transaction(
    comptime Error: type,
    comptime max_mappings: usize,
    comptime max_delegated_capabilities: usize,
) type {
    return struct {
        const Self = @This();

        pub const OwnedMapping = struct {
            child_virtual_start: usize,
            loader_virtual_start: usize,
            size: usize,
            memory_object: MemoryObject,
            allocation: AllocationHandle,
            child_mapped: bool = true,
            loader_mapped: bool = true,
            object_owned: bool = true,
            allocation_owned: bool = true,
        };

        capability_space: ?process_management.CapabilitySpace = null,
        address_space: ?AddressSpace = null,
        thread: ?process_management.Thread = null,
        mappings: [max_mappings]OwnedMapping = undefined,
        mapping_count: usize = 0,
        delegated_capabilities: [max_delegated_capabilities]abi.capability.CapabilityHandle = undefined,
        delegated_capability_count: usize = 0,
        started: bool = false,

        pub fn destroy(
            self: *Self,
            comptime Environment: type,
            physical_allocator: *memory_management.PhysicalRangeAllocator,
            root_address_space: AddressSpace,
        ) Error!void {
            const manager = memory_management.operations.MemoryManager(Environment);
            const process_manager = process_management.ProcessManager(Environment);
            var cleanup_failed = false;

            if (self.thread) |thread| {
                process_manager.destroyThread(thread) catch return error.CleanupFailed;
                self.thread = null;
            }
            var index = self.mapping_count;
            while (index > 0) {
                index -= 1;
                var mapping = &self.mappings[index];
                if (mapping.loader_mapped) {
                    manager.unmapAddressSpace(root_address_space, mapping.loader_virtual_start, mapping.size) catch {
                        cleanup_failed = true;
                        continue;
                    };
                    mapping.loader_mapped = false;
                }
                if (mapping.child_mapped) {
                    manager.unmapAddressSpace(self.address_space.?, mapping.child_virtual_start, mapping.size) catch {
                        cleanup_failed = true;
                        continue;
                    };
                    mapping.child_mapped = false;
                }
                if (mapping.object_owned) {
                    manager.destroyMemoryObject(mapping.memory_object) catch {
                        cleanup_failed = true;
                        continue;
                    };
                    mapping.object_owned = false;
                }
                if (mapping.allocation_owned) {
                    physical_allocator.free(mapping.allocation) catch {
                        cleanup_failed = true;
                        continue;
                    };
                    mapping.allocation_owned = false;
                }
            }
            if (cleanup_failed) return error.CleanupFailed;
            self.mapping_count = 0;

            if (self.address_space) |address_space| {
                manager.destroyAddressSpace(address_space) catch return error.CleanupFailed;
                self.address_space = null;
            }
            if (self.capability_space) |capability_space| {
                var capability_index = self.delegated_capability_count;
                while (capability_index > 0) {
                    capability_index -= 1;
                    process_manager.deleteCapability(
                        capability_space,
                        self.delegated_capabilities[capability_index],
                    ) catch return error.CleanupFailed;
                    self.delegated_capability_count -= 1;
                }
                process_manager.destroyCapabilitySpace(capability_space) catch
                    return error.CleanupFailed;
                self.capability_space = null;
            }
            self.started = false;
        }

        pub fn trackDelegatedCapability(
            self: *Self,
            capability_handle: abi.capability.CapabilityHandle,
        ) Error!void {
            if (self.delegated_capability_count == self.delegated_capabilities.len) {
                return error.TooManyDelegatedCapabilities;
            }
            self.delegated_capabilities[self.delegated_capability_count] = capability_handle;
            self.delegated_capability_count += 1;
        }
    };
}
