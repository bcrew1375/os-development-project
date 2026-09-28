//! Syscall operation selection, argument conversion, and ABI error mapping.

const abi = @import("abi");
const std = @import("std");
const types = @import("types.zig");

const Operation = types.Operation;
const Result = types.Result;

pub fn resolveOperation(err: anyerror) Operation {
    return if (err == error.ArgumentOutOfRange) .convert_argument else .resolve_address_space;
}

pub fn failure(operation: Operation, err: anyerror) Result {
    return .{ .failure = .{
        .operation = operation,
        .err = err,
        .return_value = abi.syscall.errorResult(errorCode(err)),
    } };
}

fn errorCode(err: anyerror) abi.syscall.ErrorCode {
    return switch (err) {
        error.InvalidCapability,
        error.CapabilityOwnerMismatch,
        error.InvalidCapabilityType,
        error.InvalidCapabilitySpaceHandle,
        error.InvalidThreadHandle,
        error.InvalidAddressSpaceHandle,
        error.InvalidMemoryObjectHandle,
        error.InvalidEndpointHandle,
        error.InvalidNotificationHandle,
        error.InvalidInterruptSourceHandle,
        error.ThreadOwnerMismatch,
        => .invalid_capability,
        error.InsufficientCapabilityRights => .insufficient_rights,
        error.InvalidCapabilityRights => .insufficient_rights,
        error.OutOfCapabilities,
        error.OutOfAuthorities,
        error.OutOfAddressSpaces,
        error.OutOfMemoryObjects,
        error.OutOfThreads,
        error.OutOfCapabilitySpaces,
        error.OutOfThreadContexts,
        error.OutOfEndpoints,
        error.OutOfNotifications,
        error.OutOfInterruptSources,
        error.OutOfVirtualMemoryAreas,
        error.AddressSpaceRootAllocationFailed,
        error.PhysicalMemoryAllocationFailed,
        => .out_of_resources,
        error.ArgumentOutOfRange,
        error.EmptyRange,
        error.RangeOverflow,
        error.RangeOutOfBounds,
        error.UnalignedRange,
        error.OverlappingAuthority,
        error.AuthorityHasDescendants,
        error.CapabilityHasDescendants,
        error.BootstrapRootDeletion,
        error.EmptyMemoryRange,
        error.MemoryRangeOverflow,
        error.KernelAddressRange,
        error.ObjectRangeOverflow,
        error.ObjectRangeOutOfBounds,
        error.UnalignedMemoryObjectRange,
        error.InvalidVirtualMemoryAreaRange,
        error.UnalignedVirtualMemoryArea,
        error.OverlappingVirtualMemoryArea,
        => .invalid_range,
        error.InvalidMemoryPermissions,
        error.ProtectionViolation,
        => .invalid_permissions,
        error.UndefinedVirtualMemoryArea,
        error.FaultOutsideVirtualMemoryArea,
        => .mapping_not_found,
        error.AddressSpaceInUse,
        error.MemoryObjectInUse,
        => .address_space_in_use,
        error.InvalidStateTransition,
        error.FaultReplyUnauthorized,
        error.InvalidFaultReply,
        error.NoRetainedFaultFrame,
        error.InvalidInstructionPointer,
        error.ThreadNotConfigured,
        error.ThreadAlreadyConfigured,
        error.SchedulerUninitialized,
        error.SchedulerAlreadyInitialized,
        error.NoCurrentThread,
        error.CurrentThreadMismatch,
        error.ThreadAlreadyQueued,
        error.ReadyQueueFull,
        => .invalid_state,
        error.ThreadInUse,
        error.CapabilitySpaceInUse,
        error.CapabilitySpaceNotEmpty,
        error.EndpointInUse,
        error.NotificationInUse,
        error.InterruptSourceInUse,
        error.InterruptSourceUnavailable,
        => .object_in_use,
        error.EndpointEmpty => .endpoint_empty,
        error.EndpointFull => .endpoint_full,
        error.EndpointCanceled => .endpoint_canceled,
        error.NotificationCanceled => .notification_canceled,
        error.CapabilitySlotOccupied => .capability_slot_occupied,
        error.InvalidCapabilitySlot => .invalid_capability_slot,
        error.NotificationAlreadyHasWaiter,
        error.NotificationWaiterNotFound,
        error.InterruptSourceNotBound,
        error.InterruptSourceAlreadyAcknowledged,
        error.InvalidInterruptSourceConfiguration,
        => .invalid_state,
        error.UserPageNotMapped,
        error.UserAccessDenied,
        error.WriteAccessDenied,
        error.CopyTooLarge,
        error.AddressOutOfRange,
        error.AddressRangeOverflow,
        error.PhysicalAddressOverflow,
        => .invalid_user_memory,
        else => .internal_failure,
    };
}

pub fn toU32(value: u64) error{ArgumentOutOfRange}!u32 {
    return if (value <= @as(u64, std.math.maxInt(u32)))
        @intCast(value)
    else
        error.ArgumentOutOfRange;
}
