//! Root-task-owned, capability-backed, multi-extent heap.

const operations = @import("operations.zig");
const Heap = @import("Heap.zig");
const PhysicalRangeAllocator = @import("PhysicalRangeAllocator.zig");
const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const MAX_EXTENTS: usize = 8;

pub const Error = Heap.Error || PhysicalRangeAllocator.Error || operations.Error || error{
    InvalidVirtualRange,
    VirtualRangeExhausted,
    ExtentMetadataExhausted,
    MappedAddressUnavailable,
    CleanupFailed,
    AllocationNotOwned,
    InitialExtentCannotBeReclaimed,
    ExtentNotEmpty,
};

pub const Statistics = struct {
    extent_count: usize,
    mapped_bytes: usize,
    allocated_payload_bytes: usize,
    allocation_count: usize,
};

pub fn RootTaskHeap(comptime Manager: type) type {
    return struct {
        const Self = @This();
        const AddressResolver = *const fn (virtual_start: usize, size: usize) ?usize;

        const Extent = struct {
            virtual_start: usize,
            size: usize,
            physical_allocation: PhysicalRangeAllocator.AllocationHandle,
            memory_object: operations.MemoryObject,
            heap: Heap,
            mapped: bool = true,
            object_alive: bool = true,
        };

        physical_allocator: *PhysicalRangeAllocator,
        address_space: operations.AddressSpace,
        virtual_start: usize,
        virtual_end: usize,
        address_resolver: AddressResolver,
        extents: [MAX_EXTENTS]Extent = undefined,
        extent_count: usize = 0,

        pub fn initialize(
            physical_allocator: *PhysicalRangeAllocator,
            address_space: operations.AddressSpace,
            virtual_start: usize,
            virtual_end: usize,
            initial_extent_size: usize,
            address_resolver: AddressResolver,
        ) Error!Self {
            if (virtual_start >= virtual_end or
                virtual_start % PAGE_SIZE != 0 or
                virtual_end % PAGE_SIZE != 0)
            {
                return Error.InvalidVirtualRange;
            }
            var self = Self{
                .physical_allocator = physical_allocator,
                .address_space = address_space,
                .virtual_start = virtual_start,
                .virtual_end = virtual_end,
                .address_resolver = address_resolver,
            };
            _ = try self.grow(initial_extent_size);
            return self;
        }

        pub fn allocate(
            self: *Self,
            size_in_bytes: usize,
            alignment: usize,
        ) Error![]u8 {
            for (self.extents[0..self.extent_count]) |*extent| {
                if (!extent.mapped or !extent.object_alive) continue;
                return extent.heap.allocate(size_in_bytes, alignment) catch |err| switch (err) {
                    Heap.Error.OutOfMemory => continue,
                    else => return err,
                };
            }

            const required_size = try Heap.requiredRegionSize(size_in_bytes, alignment);
            const extent_index = try self.grow(try alignForward(required_size, PAGE_SIZE));
            return self.extents[extent_index].heap.allocate(size_in_bytes, alignment);
        }

        pub fn free(self: *Self, bytes: []u8) Error!void {
            for (self.extents[0..self.extent_count]) |*extent| {
                if (extent.heap.owns(bytes)) return extent.heap.free(bytes);
            }
            return Error.AllocationNotOwned;
        }

        pub fn reclaimExtent(self: *Self, index: usize) Error!void {
            if (index == 0) return Error.InitialExtentCannotBeReclaimed;
            if (index >= self.extent_count) return Error.AllocationNotOwned;
            var extent = &self.extents[index];
            if (!extent.heap.isCompletelyFree()) return Error.ExtentNotEmpty;

            if (extent.mapped) {
                Manager.unmapAddressSpace(
                    self.address_space,
                    extent.virtual_start,
                    extent.size,
                ) catch return Error.CleanupFailed;
                extent.mapped = false;
            }
            if (extent.object_alive) {
                Manager.destroyMemoryObject(extent.memory_object) catch
                    return Error.CleanupFailed;
                extent.object_alive = false;
            }
            self.physical_allocator.free(extent.physical_allocation) catch
                return Error.CleanupFailed;
            self.removeExtent(index);
        }

        pub fn reclaimEmptyExtents(self: *Self) Error!usize {
            var reclaimed: usize = 0;
            var index = self.extent_count;
            while (index > 1) {
                index -= 1;
                if (!self.extents[index].heap.isCompletelyFree()) continue;
                try self.reclaimExtent(index);
                reclaimed += 1;
            }
            return reclaimed;
        }

        pub fn statistics(self: *const Self) Statistics {
            var result = Statistics{
                .extent_count = self.extent_count,
                .mapped_bytes = 0,
                .allocated_payload_bytes = 0,
                .allocation_count = 0,
            };
            for (self.extents[0..self.extent_count]) |extent| {
                if (extent.mapped) result.mapped_bytes += extent.size;
                const heap_statistics = extent.heap.statistics();
                result.allocated_payload_bytes += heap_statistics.allocated_payload_bytes;
                result.allocation_count += heap_statistics.allocation_count;
            }
            return result;
        }

        fn grow(self: *Self, requested_size: usize) Error!usize {
            if (self.extent_count == MAX_EXTENTS) return Error.ExtentMetadataExhausted;
            const extent_size = try alignForward(requested_size, PAGE_SIZE);
            const extent_virtual_start = try self.findVirtualRange(extent_size);
            const allocation = try self.physical_allocator.allocate(extent_size, PAGE_SIZE);
            const range = try self.physical_allocator.resolve(allocation);
            const page_count: u32 = std.math.cast(u32, extent_size / PAGE_SIZE) orelse {
                self.physical_allocator.free(allocation) catch {};
                return Error.VirtualRangeExhausted;
            };
            const frame = Manager.retypePhysicalFrames(
                .{ .capability = range.parent_capability },
                range.offset,
                page_count,
                .{ .manage = true, .read = true, .write = true },
            ) catch |err| {
                self.physical_allocator.free(allocation) catch return Error.CleanupFailed;
                return err;
            };
            const memory_object = Manager.createMemoryObject(frame) catch |err| {
                Manager.deletePhysicalMemory(frame) catch return Error.CleanupFailed;
                self.physical_allocator.free(allocation) catch return Error.CleanupFailed;
                return err;
            };
            Manager.mapMemoryObject(
                self.address_space,
                memory_object,
                extent_virtual_start,
                extent_size,
                operations.MAP_READ | operations.MAP_WRITE,
            ) catch |err| {
                Manager.destroyMemoryObject(memory_object) catch return Error.CleanupFailed;
                self.physical_allocator.free(allocation) catch return Error.CleanupFailed;
                return err;
            };
            const storage_start = self.address_resolver(
                extent_virtual_start,
                extent_size,
            ) orelse {
                Manager.unmapAddressSpace(
                    self.address_space,
                    extent_virtual_start,
                    extent_size,
                ) catch return Error.CleanupFailed;
                Manager.destroyMemoryObject(memory_object) catch return Error.CleanupFailed;
                self.physical_allocator.free(allocation) catch return Error.CleanupFailed;
                return Error.MappedAddressUnavailable;
            };
            const extent_heap = Heap.initialize(storage_start, extent_size) catch |err| {
                Manager.unmapAddressSpace(
                    self.address_space,
                    extent_virtual_start,
                    extent_size,
                ) catch return Error.CleanupFailed;
                Manager.destroyMemoryObject(memory_object) catch return Error.CleanupFailed;
                self.physical_allocator.free(allocation) catch return Error.CleanupFailed;
                return err;
            };

            return self.insertExtent(.{
                .virtual_start = extent_virtual_start,
                .size = extent_size,
                .physical_allocation = allocation,
                .memory_object = memory_object,
                .heap = extent_heap,
            });
        }

        fn findVirtualRange(self: *const Self, extent_size: usize) Error!usize {
            var candidate = self.virtual_start;
            for (self.extents[0..self.extent_count]) |extent| {
                const candidate_end = std.math.add(usize, candidate, extent_size) catch
                    return Error.VirtualRangeExhausted;
                if (candidate_end <= extent.virtual_start) return candidate;
                candidate = std.math.add(usize, extent.virtual_start, extent.size) catch
                    return Error.VirtualRangeExhausted;
            }
            const candidate_end = std.math.add(usize, candidate, extent_size) catch
                return Error.VirtualRangeExhausted;
            if (candidate_end > self.virtual_end) return Error.VirtualRangeExhausted;
            return candidate;
        }

        fn insertExtent(self: *Self, extent: Extent) usize {
            var index: usize = 0;
            while (index < self.extent_count and
                self.extents[index].virtual_start < extent.virtual_start) : (index += 1)
            {}
            var move_index = self.extent_count;
            while (move_index > index) : (move_index -= 1) {
                self.extents[move_index] = self.extents[move_index - 1];
            }
            self.extents[index] = extent;
            self.extent_count += 1;
            return index;
        }

        fn removeExtent(self: *Self, index: usize) void {
            var move_index = index;
            while (move_index + 1 < self.extent_count) : (move_index += 1) {
                self.extents[move_index] = self.extents[move_index + 1];
            }
            self.extent_count -= 1;
        }

        fn alignForward(value: usize, alignment: usize) Error!usize {
            const with_mask = std.math.add(usize, value, alignment - 1) catch
                return Error.VirtualRangeExhausted;
            return with_mask & ~(alignment - 1);
        }
    };
}
