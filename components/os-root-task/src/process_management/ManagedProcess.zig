//! Root-task-owned process record with parent protocol and lifecycle observation.

const abi = @import("abi");
const ipc = @import("ipc");
const memory_management = @import("memory_management");
const process_management = @import("process_management");

const child_process = process_management.child_process;
const AddressSpace = memory_management.operations.AddressSpace;

pub const State = enum {
    started,
    startup_observed,
    service_transferred,
    service_ready,
    terminal_observed,
    destroyed,
};

pub const Error = child_process.Error || ipc.Error || process_management.Error ||
    abi.process.MessageError || error{
    InvalidState,
    UnexpectedParentMessage,
    UnexpectedLifecycleEvent,
    LifecycleTokenMismatch,
};

pub const ManagedProcess = struct {
    child: child_process.ChildProcess,
    parent_endpoint: ipc.Endpoint,
    lifecycle_endpoint: ipc.Endpoint,
    service_endpoint: ipc.Endpoint,
    lifecycle_token: u32,
    expected_action: abi.process.ManagedChildAction,
    state: State = .started,

    pub fn createAndStart(
        comptime Environment: type,
        physical_allocator: *memory_management.PhysicalRangeAllocator,
        root_address_space: AddressSpace,
        image: []const u8,
        lifecycle_token: u32,
        action: abi.process.ManagedChildAction,
    ) Error!ManagedProcess {
        if (lifecycle_token == abi.process.INVALID_LIFECYCLE_TOKEN) {
            return error.LifecycleTokenMismatch;
        }
        const endpoint_manager = ipc.EndpointManager(Environment);
        const parent_endpoint = try endpoint_manager.createEndpoint();
        errdefer endpoint_manager.destroyEndpoint(parent_endpoint) catch {};
        const lifecycle_endpoint = try endpoint_manager.createEndpoint();
        errdefer endpoint_manager.destroyEndpoint(lifecycle_endpoint) catch {};
        const service_endpoint = try endpoint_manager.createEndpoint();
        errdefer endpoint_manager.destroyEndpoint(service_endpoint) catch {};
        const child = try child_process.createAndStartManaged(
            Environment,
            physical_allocator,
            root_address_space,
            image,
            .{
                .mode = .managed_lifecycle,
                .lifecycle_token = lifecycle_token,
                .managed_action = action,
            },
            null,
            null,
            parent_endpoint.capability,
            lifecycle_endpoint.capability,
        );
        return .{
            .child = child,
            .parent_endpoint = parent_endpoint,
            .lifecycle_endpoint = lifecycle_endpoint,
            .service_endpoint = service_endpoint,
            .lifecycle_token = lifecycle_token,
            .expected_action = action,
        };
    }

    pub fn observeStartup(
        self: *ManagedProcess,
        comptime Environment: type,
    ) Error!void {
        if (self.state != .started) return error.InvalidState;
        const endpoint_manager = ipc.EndpointManager(Environment);
        try self.expectParentMessage(endpoint_manager, .startup);
        self.state = .startup_observed;
    }

    pub fn transferServiceCapability(
        self: *ManagedProcess,
        comptime Environment: type,
    ) Error!void {
        if (self.state != .startup_observed) return error.InvalidState;
        const endpoint_manager = ipc.EndpointManager(Environment);
        try self.expectParentMessage(endpoint_manager, .service_request);
        try endpoint_manager.sendCapability(
            self.parent_endpoint,
            self.service_endpoint.capability,
            .{ .send = true },
            try abi.process.parentMessage(.service_ready, self.lifecycle_token, 0),
        );
        self.state = .service_transferred;
    }

    pub fn observeServiceReady(
        self: *ManagedProcess,
        comptime Environment: type,
    ) Error!void {
        if (self.state != .service_transferred) return error.InvalidState;
        const endpoint_manager = ipc.EndpointManager(Environment);
        const transferred = try self.expectServiceReady(endpoint_manager);
        if (abi.capability.capabilitySlotIndex(transferred) !=
            abi.system_smoke.CAPABILITY_TRANSFER_DESTINATION_SLOT)
        {
            return error.UnexpectedParentMessage;
        }
        try self.child.trackDelegatedCapability(transferred);
        self.state = .service_ready;
    }

    pub fn observeTerminal(
        self: *ManagedProcess,
        comptime Environment: type,
    ) Error!abi.process.LifecycleEvent {
        if (self.state != .service_ready) return error.InvalidState;
        const endpoint_manager = ipc.EndpointManager(Environment);
        const event = try abi.process.decodeLifecycleEvent(
            try endpoint_manager.receive(self.lifecycle_endpoint),
        );
        if (event.lifecycle_token != self.lifecycle_token) return error.LifecycleTokenMismatch;
        switch (self.expected_action) {
            .exit_success => if (event.kind != .exited or event.value != abi.syscall.EXIT_SUCCESS) {
                return error.UnexpectedLifecycleEvent;
            },
            .fault_invalid_opcode => if (event.kind != .faulted or
                event.value != @intFromEnum(abi.process.FaultReason.invalid_opcode))
            {
                return error.UnexpectedLifecycleEvent;
            },
        }
        self.state = .terminal_observed;
        return event;
    }

    pub fn destroy(
        self: *ManagedProcess,
        comptime Environment: type,
        physical_allocator: *memory_management.PhysicalRangeAllocator,
        root_address_space: AddressSpace,
    ) Error!void {
        if (self.state != .terminal_observed) return error.InvalidState;
        const endpoint_manager = ipc.EndpointManager(Environment);
        try self.child.destroy(Environment, physical_allocator, root_address_space);
        try endpoint_manager.destroyEndpoint(self.service_endpoint);
        try endpoint_manager.destroyEndpoint(self.lifecycle_endpoint);
        try endpoint_manager.destroyEndpoint(self.parent_endpoint);
        self.state = .destroyed;
    }

    fn expectParentMessage(
        self: *ManagedProcess,
        comptime endpoint_manager: type,
        expected_kind: abi.process.ParentMessageKind,
    ) Error!void {
        const message = try abi.process.decodeParentMessage(
            try endpoint_manager.receive(self.parent_endpoint),
        );
        if (message.lifecycle_token != self.lifecycle_token) return error.LifecycleTokenMismatch;
        if (message.kind != expected_kind) return error.UnexpectedParentMessage;
    }

    fn expectServiceReady(
        self: *ManagedProcess,
        comptime endpoint_manager: type,
    ) Error!abi.capability.CapabilityHandle {
        const message = try abi.process.decodeParentMessage(
            try endpoint_manager.receive(self.service_endpoint),
        );
        if (message.lifecycle_token != self.lifecycle_token) return error.LifecycleTokenMismatch;
        if (message.kind != .service_ready) return error.UnexpectedParentMessage;
        if (message.value == abi.capability.INVALID_CAPABILITY) return error.UnexpectedParentMessage;
        return message.value;
    }
};
