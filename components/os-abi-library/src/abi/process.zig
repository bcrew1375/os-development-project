//! Stable userspace process-management ABI structures.

const std = @import("std");
const capability = @import("capability.zig");
const ipc = @import("ipc.zig");

/// Fixed-width input used to bind a newly created thread to execution resources.
pub const ThreadConfiguration = extern struct {
    capability_space: capability.CapabilityHandle,
    address_space: capability.CapabilityHandle,
    entry_point: u64,
    stack_pointer: u64,
    argument: u64,
    lifecycle_endpoint: capability.CapabilityHandle = capability.INVALID_CAPABILITY,
    lifecycle_token: u32 = INVALID_LIFECYCLE_TOKEN,
    fault_endpoint: capability.CapabilityHandle = capability.INVALID_CAPABILITY,
    fault_token: u32 = INVALID_FAULT_TOKEN,
};

pub const CHILD_STARTUP_MAGIC: u32 = 0x4348_4C44;
pub const CHILD_STARTUP_VERSION: u32 = 5;
pub const INVALID_LIFECYCLE_TOKEN: u32 = 0;
pub const INVALID_FAULT_TOKEN: u32 = 0;
pub const FAULT_EVENT_RECORD_COUNT: usize = 4;

pub const FaultEventRecordKind = enum(u32) {
    header = 0x4641_5548,
    address = 0x4641_5541,
    instruction_pointer = 0x4641_5549,
    architecture_data = 0x4641_5552,
};

pub const FaultReplyAction = enum(u32) {
    resume_thread = 1,
    resume_at = 2,
    terminate = 3,
    _,
};

pub const FaultReplyRequest = extern struct {
    thread_handle: u32,
    fault_token: u32,
    action: FaultReplyAction,
    reserved: u32 = 0,
    value: u64 = 0,
};

pub const FaultEvent = struct {
    fault_token: u32,
    thread_handle: u32,
    reason: FaultReason,
    address: u64,
    instruction_pointer: u64,
    architecture_data: u64,
};

pub const ChildStartupMode = enum(u32) {
    ipc_ping_pong = 1,
    invalid_opcode = 2,
    capability_transfer = 3,
    managed_lifecycle = 4,
};

pub const ManagedChildAction = enum(u32) {
    exit_success = 1,
    fault_invalid_opcode = 2,
};

/// Fixed-layout startup data copied into a new child process's initial stack.
pub const ChildStartup = extern struct {
    magic: u32 = CHILD_STARTUP_MAGIC,
    version: u32 = CHILD_STARTUP_VERSION,
    mode: ChildStartupMode,
    request_endpoint_capability: capability.CapabilityHandle = capability.INVALID_CAPABILITY,
    reply_endpoint_capability: capability.CapabilityHandle = capability.INVALID_CAPABILITY,
    parent_endpoint_capability: capability.CapabilityHandle = capability.INVALID_CAPABILITY,
    lifecycle_token: u32 = INVALID_LIFECYCLE_TOKEN,
    managed_action: ManagedChildAction = .exit_success,
};

pub const ParentMessageKind = enum(u32) {
    startup = 1,
    service_request = 2,
    service_ready = 3,
};

pub const LifecycleEventKind = enum(u32) {
    exited = 1,
    faulted = 2,
};

pub const FaultReason = enum(u32) {
    divide_by_zero = 1,
    invalid_opcode = 2,
    general_protection = 3,
    page_fault = 4,
    alignment_check = 5,
};

pub const ParentMessage = struct {
    kind: ParentMessageKind,
    lifecycle_token: u32,
    value: u32,
};

pub const LifecycleEvent = struct {
    kind: LifecycleEventKind,
    lifecycle_token: u32,
    value: u32,
};

pub const MessageError = error{
    InvalidMessageKind,
    InvalidLifecycleToken,
};

pub fn parentMessage(kind: ParentMessageKind, lifecycle_token: u32, value: u32) MessageError!ipc.Message {
    if (lifecycle_token == INVALID_LIFECYCLE_TOKEN) return error.InvalidLifecycleToken;
    return .{ .words = .{ @intFromEnum(kind), lifecycle_token, value } };
}

pub fn decodeParentMessage(message: ipc.Message) MessageError!ParentMessage {
    const kind: ParentMessageKind = switch (message.words[0]) {
        @intFromEnum(ParentMessageKind.startup) => .startup,
        @intFromEnum(ParentMessageKind.service_request) => .service_request,
        @intFromEnum(ParentMessageKind.service_ready) => .service_ready,
        else => return error.InvalidMessageKind,
    };
    if (message.words[1] == INVALID_LIFECYCLE_TOKEN) return error.InvalidLifecycleToken;
    return .{ .kind = kind, .lifecycle_token = message.words[1], .value = message.words[2] };
}

pub fn lifecycleEvent(kind: LifecycleEventKind, lifecycle_token: u32, value: u32) MessageError!ipc.Message {
    if (lifecycle_token == INVALID_LIFECYCLE_TOKEN) return error.InvalidLifecycleToken;
    return .{ .words = .{ @intFromEnum(kind), lifecycle_token, value } };
}

pub fn decodeLifecycleEvent(message: ipc.Message) MessageError!LifecycleEvent {
    const kind: LifecycleEventKind = switch (message.words[0]) {
        @intFromEnum(LifecycleEventKind.exited) => .exited,
        @intFromEnum(LifecycleEventKind.faulted) => .faulted,
        else => return error.InvalidMessageKind,
    };
    if (message.words[1] == INVALID_LIFECYCLE_TOKEN) return error.InvalidLifecycleToken;
    return .{ .kind = kind, .lifecycle_token = message.words[1], .value = message.words[2] };
}

pub fn faultEventMessages(event: FaultEvent) [FAULT_EVENT_RECORD_COUNT]ipc.Message {
    return .{
        .{ .words = .{
            @intFromEnum(FaultEventRecordKind.header),
            event.fault_token,
            event.thread_handle,
        } },
        .{ .words = .{
            @intFromEnum(FaultEventRecordKind.address),
            @truncate(event.address),
            @truncate(event.address >> 32),
        } },
        .{ .words = .{
            @intFromEnum(FaultEventRecordKind.instruction_pointer),
            @truncate(event.instruction_pointer),
            @truncate(event.instruction_pointer >> 32),
        } },
        .{ .words = .{
            @intFromEnum(FaultEventRecordKind.architecture_data),
            @intFromEnum(event.reason),
            @truncate(event.architecture_data),
        } },
    };
}

comptime {
    std.debug.assert(@sizeOf(ThreadConfiguration) == 48);
    std.debug.assert(@offsetOf(ThreadConfiguration, "capability_space") == 0);
    std.debug.assert(@offsetOf(ThreadConfiguration, "address_space") == 4);
    std.debug.assert(@offsetOf(ThreadConfiguration, "entry_point") == 8);
    std.debug.assert(@offsetOf(ThreadConfiguration, "stack_pointer") == 16);
    std.debug.assert(@offsetOf(ThreadConfiguration, "argument") == 24);
    std.debug.assert(@offsetOf(ThreadConfiguration, "lifecycle_endpoint") == 32);
    std.debug.assert(@offsetOf(ThreadConfiguration, "lifecycle_token") == 36);
    std.debug.assert(@offsetOf(ThreadConfiguration, "fault_endpoint") == 40);
    std.debug.assert(@offsetOf(ThreadConfiguration, "fault_token") == 44);
    std.debug.assert(@sizeOf(FaultReplyRequest) == 24);
    std.debug.assert(@offsetOf(FaultReplyRequest, "value") == 16);
    std.debug.assert(@sizeOf(ChildStartup) == 32);
    std.debug.assert(@alignOf(ChildStartup) == 4);
    std.debug.assert(@offsetOf(ChildStartup, "mode") == 8);
    std.debug.assert(@offsetOf(ChildStartup, "request_endpoint_capability") == 12);
    std.debug.assert(@offsetOf(ChildStartup, "reply_endpoint_capability") == 16);
    std.debug.assert(@offsetOf(ChildStartup, "parent_endpoint_capability") == 20);
    std.debug.assert(@offsetOf(ChildStartup, "lifecycle_token") == 24);
    std.debug.assert(@offsetOf(ChildStartup, "managed_action") == 28);
}
