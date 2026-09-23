//! Validation and access helpers for boot-delegated physical-memory authority.

const abi = @import("abi");
const std = @import("std");

pub const Error = error{
    TooManyDescriptors,
    MissingDescriptorArray,
    MisalignedDescriptorArray,
    DescriptorArrayOverflow,
    EmptyRange,
    RangeOverflow,
    UnalignedRange,
    UnsupportedAttributes,
    InvalidCapability,
    OutOfOrderRange,
    OverlappingRange,
    PhysicalAddressOutOfRange,
};

pub fn descriptors(boot_info: *const abi.boot_info.BootInfo) Error![]const abi.boot_info.PhysicalMemoryInfo {
    const count: usize = @intCast(boot_info.physical_memory_count);
    if (count > abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS) {
        return Error.TooManyDescriptors;
    }
    if (count == 0) return &.{};
    if (boot_info.physical_memory_address == 0) return Error.MissingDescriptorArray;
    if (boot_info.physical_memory_address % @alignOf(abi.boot_info.PhysicalMemoryInfo) != 0) {
        return Error.MisalignedDescriptorArray;
    }

    const byte_count = std.math.mul(
        usize,
        count,
        @sizeOf(abi.boot_info.PhysicalMemoryInfo),
    ) catch return Error.DescriptorArrayOverflow;
    const start: usize = @intCast(boot_info.physical_memory_address);
    _ = std.math.add(usize, start, byte_count) catch return Error.DescriptorArrayOverflow;
    const descriptor_pointer: [*]const abi.boot_info.PhysicalMemoryInfo = @ptrFromInt(start);
    return descriptor_pointer[0..count];
}

pub fn validate(descriptor_slice: []const abi.boot_info.PhysicalMemoryInfo) Error!void {
    if (descriptor_slice.len > abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS) {
        return Error.TooManyDescriptors;
    }

    const page_size: u64 = 4096;
    const maximum_physical_address: u64 = if (@sizeOf(usize) == 4)
        std.math.maxInt(u32)
    else
        (@as(u64, 1) << 52) - 1;
    var previous_start: u64 = 0;
    var previous_end: u64 = 0;
    for (descriptor_slice, 0..) |descriptor, index| {
        if (descriptor.size == 0) return Error.EmptyRange;
        if (descriptor.physical_start % page_size != 0 or descriptor.size % page_size != 0) {
            return Error.UnalignedRange;
        }
        if (descriptor.attributes != abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM) {
            return Error.UnsupportedAttributes;
        }
        if (abi.capability.decodeCapabilityHandle(descriptor.capability) == null) {
            return Error.InvalidCapability;
        }

        const physical_end = std.math.add(
            u64,
            descriptor.physical_start,
            descriptor.size,
        ) catch return Error.RangeOverflow;
        if (physical_end - 1 > maximum_physical_address) {
            return Error.PhysicalAddressOutOfRange;
        }
        if (index != 0) {
            if (descriptor.physical_start < previous_start) return Error.OutOfOrderRange;
            if (descriptor.physical_start < previous_end) return Error.OverlappingRange;
        }
        previous_start = descriptor.physical_start;
        previous_end = physical_end;
    }
}

pub fn validateBootInfo(boot_info: *const abi.boot_info.BootInfo) Error!void {
    try validate(try descriptors(boot_info));
}
