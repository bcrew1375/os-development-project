//! Architecture-independent syscall decoding and kernel policy dispatch.

const process = @import("../process/main.zig");
const dispatch = @import("dispatch.zig");
const error_mapping = @import("error_mapping.zig");
const production_services = @import("production_services.zig");
const types = @import("types.zig");

pub const Request = types.Request;
pub const Operation = types.Operation;
pub const Failure = types.Failure;
pub const Result = types.Result;

/// Dispatches a production syscall using the installed execution context.
pub fn dispatchFromCurrentContext(request: Request) Result {
    const caller_capability_space = process.execution_context.currentCapabilitySpaceHandle() catch |err| {
        return error_mapping.failure(.resolve_execution_context, err);
    };
    return dispatchWithServices(
        production_services.ProductionServices,
        caller_capability_space,
        request,
    );
}

/// Dispatches policy through a statically supplied service implementation.
pub fn dispatchWithServices(
    comptime Services: type,
    caller_capability_space: process.thread.CapabilitySpaceHandle,
    request: Request,
) Result {
    return dispatch.dispatchWithServices(Services, caller_capability_space, request);
}
