//! Checked access to memory owned by the current userspace address space.

const arch = @import("arch");
const std = @import("std");

pub const MAX_COPY_BYTES: usize = 4096;

pub const UserMemoryError = error{
    EmptyRange,
    AddressRangeOverflow,
    KernelAddressRange,
    CopyTooLarge,
    AddressOutOfRange,
    UserAccessDenied,
    WriteAccessDenied,
    UserPageNotMapped,
    PhysicalAddressOverflow,
};

pub const UserAddress = struct {
    value: u64,

    pub fn init(value: u64) UserMemoryError!UserAddress {
        if (value >= arch.mmu.getKernelVirtualAddressStart()) {
            return UserMemoryError.KernelAddressRange;
        }
        return .{ .value = value };
    }
};

pub const UserSlice = struct {
    address: UserAddress,
    length: usize,

    pub fn init(address: u64, length: u64) UserMemoryError!UserSlice {
        if (length == 0) return UserMemoryError.EmptyRange;
        if (length > MAX_COPY_BYTES) return UserMemoryError.CopyTooLarge;

        const end = std.math.add(u64, address, length) catch {
            return UserMemoryError.AddressRangeOverflow;
        };
        const kernel_start = arch.mmu.getKernelVirtualAddressStart();
        if (address >= kernel_start or end > kernel_start) {
            return UserMemoryError.KernelAddressRange;
        }
        if (length > std.math.maxInt(usize)) {
            return UserMemoryError.AddressOutOfRange;
        }

        return .{
            .address = .{ .value = address },
            .length = @intCast(length),
        };
    }
};

pub fn copyFromUser(destination: []u8, address: u64, length: u64) UserMemoryError!void {
    const source = try UserSlice.init(address, length);
    if (destination.len < source.length) return UserMemoryError.CopyTooLarge;

    try validatePages(source, .read);
    try copyFromDirectMap(destination[0..source.length], source);
}

pub fn copyToUser(address: u64, source: []const u8) UserMemoryError!void {
    const destination = try UserSlice.init(address, source.len);

    try validatePages(destination, .write);
    try copyToDirectMap(destination, source);
}

const Access = enum { read, write };

fn validatePages(user_slice: UserSlice, access: Access) UserMemoryError!void {
    const page_size = arch.mmu.getPageSize();
    var copied: usize = 0;
    while (copied < user_slice.length) {
        const virtual_address = std.math.add(usize, @intCast(user_slice.address.value), copied) catch {
            return UserMemoryError.AddressOutOfRange;
        };
        const physical_address = arch.mmu.getPhysicalAddress(virtual_address) orelse {
            return UserMemoryError.UserPageNotMapped;
        };
        _ = physical_address;

        const protection = arch.mmu.getPageProtection(virtual_address) orelse {
            return UserMemoryError.UserPageNotMapped;
        };
        if (!protection.user) return UserMemoryError.UserAccessDenied;
        switch (access) {
            .read => {},
            .write => if (!protection.write) return UserMemoryError.WriteAccessDenied,
        }

        const page_remaining = page_size - (virtual_address & (page_size - 1));
        copied += @min(page_remaining, user_slice.length - copied);
    }
}

fn copyFromDirectMap(destination: []u8, source: UserSlice) UserMemoryError!void {
    const direct_map = arch.mmu.getDirectMapVirtualAddress();
    const page_size = arch.mmu.getPageSize();
    var copied: usize = 0;
    while (copied < source.length) {
        const virtual_address = @as(usize, @intCast(source.address.value)) + copied;
        const physical_address = arch.mmu.getPhysicalAddress(virtual_address) orelse {
            return UserMemoryError.UserPageNotMapped;
        };
        const direct_map_address = std.math.add(usize, @intCast(direct_map), physical_address) catch {
            return UserMemoryError.PhysicalAddressOverflow;
        };
        const page_remaining = page_size - (virtual_address & (page_size - 1));
        const copy_size = @min(page_remaining, source.length - copied);
        const source_bytes: [*]const u8 = @ptrFromInt(direct_map_address);
        @memcpy(destination[copied..][0..copy_size], source_bytes[0..copy_size]);
        copied += copy_size;
    }
}

fn copyToDirectMap(destination: UserSlice, source: []const u8) UserMemoryError!void {
    const direct_map = arch.mmu.getDirectMapVirtualAddress();
    const page_size = arch.mmu.getPageSize();
    var copied: usize = 0;
    while (copied < destination.length) {
        const virtual_address = @as(usize, @intCast(destination.address.value)) + copied;
        const physical_address = arch.mmu.getPhysicalAddress(virtual_address) orelse {
            return UserMemoryError.UserPageNotMapped;
        };
        const direct_map_address = std.math.add(usize, @intCast(direct_map), physical_address) catch {
            return UserMemoryError.PhysicalAddressOverflow;
        };
        const page_remaining = page_size - (virtual_address & (page_size - 1));
        const copy_size = @min(page_remaining, destination.length - copied);
        const destination_bytes: [*]u8 = @ptrFromInt(direct_map_address);
        @memcpy(destination_bytes[0..copy_size], source[copied..][0..copy_size]);
        copied += copy_size;
    }
}
