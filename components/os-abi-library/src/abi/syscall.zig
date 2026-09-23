//! User/kernel syscall ABI numbers and low-level trap helpers.

const capability = @import("capability.zig");

/// Numeric syscall identifiers placed in the syscall number register.
pub const SyscallNumber = enum(u32) {
    debug_write = 0,
    exit = 1,
    current_address_space = 9,
    create_address_space = 10,
    map_memory = 11,
    create_memory_object = 12,
    map_memory_object = 13,
    protect_address_space = 14,
    unmap_address_space = 15,
    destroy_address_space = 16,
    query_address_space = 17,
    retype_untyped_memory = 18,
    delete_physical_memory = 19,
    revoke_physical_memory = 20,
    _,
};

/// Conventional successful process exit status.
pub const EXIT_SUCCESS: u32 = 0;
/// Conventional failed process exit status.
pub const EXIT_FAILURE: u32 = 1;
/// Reserved invalid handle value for ABI handles.
pub const INVALID_HANDLE: u32 = 0;
/// Generic successful syscall return code.
pub const SYSCALL_SUCCESS: u32 = 0;
/// Generic failed syscall return code.
pub const SYSCALL_FAILURE: u32 = 1;
/// High bit distinguishing structured syscall errors from successful values.
pub const ERROR_BIT: u32 = 1 << 31;

/// Recoverable errors returned across the syscall ABI.
pub const ErrorCode = enum(u32) {
    invalid_capability = 1,
    insufficient_rights = 2,
    out_of_resources = 3,
    invalid_range = 4,
    invalid_permissions = 5,
    mapping_not_found = 6,
    address_space_in_use = 7,
    unsupported = 8,
    internal_failure = 9,
};

/// Encodes a recoverable ABI error in a syscall return value.
pub fn errorResult(code: ErrorCode) u32 {
    return ERROR_BIT | @intFromEnum(code);
}

/// Decodes a structured syscall error, or returns null for a successful value.
pub fn decodeError(value: u32) ?ErrorCode {
    if ((value & ERROR_BIT) == 0) return null;
    return switch (value & ~ERROR_BIT) {
        @intFromEnum(ErrorCode.invalid_capability) => .invalid_capability,
        @intFromEnum(ErrorCode.insufficient_rights) => .insufficient_rights,
        @intFromEnum(ErrorCode.out_of_resources) => .out_of_resources,
        @intFromEnum(ErrorCode.invalid_range) => .invalid_range,
        @intFromEnum(ErrorCode.invalid_permissions) => .invalid_permissions,
        @intFromEnum(ErrorCode.mapping_not_found) => .mapping_not_found,
        @intFromEnum(ErrorCode.address_space_in_use) => .address_space_in_use,
        @intFromEnum(ErrorCode.unsupported) => .unsupported,
        @intFromEnum(ErrorCode.internal_failure) => .internal_failure,
        else => .internal_failure,
    };
}
/// Request a readable memory mapping.
pub const MAP_READ: u32 = 1 << 0;
/// Request a writable memory mapping.
pub const MAP_WRITE: u32 = 1 << 1;
/// Request an executable memory mapping.
pub const MAP_EXECUTE: u32 = 1 << 2;

/// Low bits occupied by the target object type in a retype request.
pub const RETYPE_OBJECT_TYPE_BITS: u32 = 8;
/// Mask selecting the packed retype target object type.
pub const RETYPE_OBJECT_TYPE_MASK: u32 = (@as(u32, 1) << RETYPE_OBJECT_TYPE_BITS) - 1;

/// Packs a retype target object type and attenuated capability rights.
pub fn packRetypeTarget(object_type: capability.ObjectType, rights: capability.Rights) u32 {
    return @intFromEnum(object_type) |
        (capability.rightsBits(rights) << RETYPE_OBJECT_TYPE_BITS);
}

/// Returns the target object type from a packed retype request.
pub fn retypeTargetObjectType(encoded: u32) capability.ObjectType {
    return @enumFromInt(encoded & RETYPE_OBJECT_TYPE_MASK);
}

/// Returns the requested rights bits from a packed retype request.
pub fn retypeTargetRightsBits(encoded: u32) u32 {
    return encoded >> RETYPE_OBJECT_TYPE_BITS;
}

/// Joins low and high ABI words into a 64-bit physical offset.
pub fn joinU64(low: u32, high: u32) u64 {
    return @as(u64, low) | (@as(u64, high) << 32);
}

/// Returns the low ABI word of a 64-bit value.
pub fn lowU32(value: u64) u32 {
    return @truncate(value);
}

/// Returns the high ABI word of a 64-bit value.
pub fn highU32(value: u64) u32 {
    return @truncate(value >> 32);
}

/// Performs a syscall with three machine-word arguments.
pub fn syscall3(number: u32, argument0: usize, argument1: usize, argument2: usize) callconv(.c) u32 {
    return asm volatile (
        \\int $0x80
        : [return_value] "={eax}" (-> u32),
        : [number] "{eax}" (number),
          [argument0] "{ebx}" (argument0),
          [argument1] "{ecx}" (argument1),
          [argument2] "{edx}" (argument2),
        : .{ .memory = true });
}

/// Performs a syscall with five machine-word arguments.
pub fn syscall5(number: u32, argument0: usize, argument1: usize, argument2: usize, argument3: usize, argument4: usize) callconv(.c) u32 {
    return asm volatile (
        \\int $0x80
        : [return_value] "={eax}" (-> u32),
        : [number] "{eax}" (number),
          [argument0] "{ebx}" (argument0),
          [argument1] "{ecx}" (argument1),
          [argument2] "{edx}" (argument2),
          [argument3] "{esi}" (argument3),
          [argument4] "{edi}" (argument4),
        : .{ .memory = true });
}
