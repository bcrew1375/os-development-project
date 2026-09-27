//! User/kernel syscall ABI numbers and low-level trap helpers.

const capability = @import("capability.zig");
const ipc = @import("ipc.zig");
const notification = @import("notification.zig");

/// Numeric syscall identifiers placed in the syscall number register.
pub const SyscallNumber = enum(u32) {
    debug_write = 0,
    exit = 1,
    yield = 2,
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
    destroy_memory_object = 21,
    create_capability_space = 22,
    create_thread = 23,
    configure_thread = 24,
    start_thread = 25,
    suspend_thread = 26,
    resume_thread = 27,
    terminate_thread = 28,
    install_capability = 29,
    destroy_thread = 30,
    destroy_capability_space = 31,
    delete_capability = 32,
    create_endpoint = 33,
    destroy_endpoint = 34,
    endpoint_send = 35,
    endpoint_receive = 36,
    endpoint_send_capability = 37,
    endpoint_receive_capability = 38,
    fault_reply = 39,
    create_notification = 40,
    destroy_notification = 41,
    notification_wait = 42,
    notification_signal = 43,
    create_interrupt_source = 44,
    destroy_interrupt_source = 45,
    bind_interrupt_source = 46,
    unbind_interrupt_source = 47,
    acknowledge_interrupt_source = 48,
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
    invalid_state = 10,
    object_in_use = 11,
    invalid_user_memory = 12,
    endpoint_empty = 13,
    endpoint_full = 14,
    endpoint_canceled = 15,
    capability_slot_occupied = 16,
    invalid_capability_slot = 17,
    notification_canceled = 18,
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
        @intFromEnum(ErrorCode.invalid_state) => .invalid_state,
        @intFromEnum(ErrorCode.object_in_use) => .object_in_use,
        @intFromEnum(ErrorCode.invalid_user_memory) => .invalid_user_memory,
        @intFromEnum(ErrorCode.endpoint_empty) => .endpoint_empty,
        @intFromEnum(ErrorCode.endpoint_full) => .endpoint_full,
        @intFromEnum(ErrorCode.endpoint_canceled) => .endpoint_canceled,
        @intFromEnum(ErrorCode.capability_slot_occupied) => .capability_slot_occupied,
        @intFromEnum(ErrorCode.invalid_capability_slot) => .invalid_capability_slot,
        @intFromEnum(ErrorCode.notification_canceled) => .notification_canceled,
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

/// Performs a receive syscall returning status plus three message registers.
pub fn syscallReceive(number: u32, endpoint: capability.CapabilityHandle) ipc.ReceiveResult {
    var status: u32 = undefined;
    var word0: usize = undefined;
    var word1: usize = undefined;
    var word2: usize = undefined;
    asm volatile (
        \\int $0x80
        : [status] "={eax}" (status),
          [word0] "={ebx}" (word0),
          [word1] "={ecx}" (word1),
          [word2] "={edx}" (word2),
        : [number] "{eax}" (number),
          [endpoint] "{ebx}" (endpoint),
        : .{ .memory = true });
    return .{
        .status = status,
        .message = .{ .words = .{ @truncate(word0), @truncate(word1), @truncate(word2) } },
    };
}

/// Performs a notification wait returning a count and sticky-overflow indication.
pub fn syscallNotificationWait(
    number: u32,
    notification_capability: capability.CapabilityHandle,
) notification.WaitResult {
    var status: u32 = undefined;
    var pending_count: usize = undefined;
    var overflowed: usize = undefined;
    asm volatile (
        \\int $0x80
        : [status] "={eax}" (status),
          [pending_count] "={ebx}" (pending_count),
          [overflowed] "={ecx}" (overflowed),
        : [number] "{eax}" (number),
          [notification_capability] "{ebx}" (notification_capability),
        : .{ .memory = true });
    return .{
        .status = status,
        .pending_count = @truncate(pending_count),
        .overflowed = overflowed != 0,
    };
}

/// Performs a capability-transfer receive returning a handle plus three message registers.
pub fn syscallTransferReceive(
    number: u32,
    endpoint: capability.CapabilityHandle,
    request: *const ipc.TransferReceiveRequest,
) ipc.TransferReceiveResult {
    var status: u32 = undefined;
    var word0: usize = undefined;
    var word1: usize = undefined;
    var word2: usize = undefined;
    var installed_capability: usize = undefined;
    asm volatile (
        \\int $0x80
        : [status] "={eax}" (status),
          [word0] "={ebx}" (word0),
          [word1] "={ecx}" (word1),
          [word2] "={edx}" (word2),
          [installed_capability] "={esi}" (installed_capability),
        : [number] "{eax}" (number),
          [endpoint] "{ebx}" (endpoint),
          [request] "{ecx}" (request),
        : .{ .memory = true });
    return .{
        .status = status,
        .message = .{ .words = .{ @truncate(word0), @truncate(word1), @truncate(word2) } },
        .capability = @truncate(installed_capability),
    };
}
