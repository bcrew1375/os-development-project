//! Shared capability-subsystem error set.

const endpoint = @import("../ipc/endpoint.zig");
const interrupt_source = @import("../ipc/interrupt_source.zig");
const ipc_operations = @import("../ipc/operations.zig");
const notification = @import("../ipc/notification.zig");
const notification_operations = @import("../ipc/notification_operations.zig");
const authority = @import("../memory_management/physical_memory_authority.zig");
const process = @import("../process/main.zig");
const space = @import("space.zig");

pub const CapabilityError = error{
    OutOfCapabilities,
    InvalidCapability,
    CapabilityOwnerMismatch,
    InvalidCapabilityType,
    InsufficientCapabilityRights,
    CapabilityHasDescendants,
    InvalidCapabilityRights,
    InvalidCapabilitySlot,
    CapabilitySlotOccupied,
    CapabilitySpaceNotEmpty,
} || process.ProcessError || space.Error || authority.Error || endpoint.Error ||
    ipc_operations.Error || notification.Error || interrupt_source.Error ||
    notification_operations.Error;
