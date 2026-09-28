const std = @import("std");
const abi = @import("abi");
const arch = @import("arch");
const kernel = @import("kernel_common");

const assertions = @import("../support/syscall/assertions.zig");
const production_fixtures = @import("../support/syscall/production_fixtures.zig");

const createPendingManagedFault = production_fixtures.createPendingManagedFault;
const expectFailure = assertions.expectFailure;
const expectReturned = assertions.expectReturned;
const request = assertions.request;
const resetProductionState = production_fixtures.resetProductionState;
const writeFaultReplyRequest = production_fixtures.writeFaultReplyRequest;

test "Syscall: production fault replies enforce manager authority and one-shot recovery" {
    try arch.impl.test_support.initializeDefaultMemoryFixture();
    defer arch.impl.test_support.deinitializeMemoryFixture();
    resetProductionState();

    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const root_address_capability = try kernel.capability.createAddressSpaceCapability(root_space);
    const root_address_space = try kernel.capability.resolveAddressSpace(
        root_space,
        root_address_capability,
        .{ .manage = true },
    );
    const root = try kernel.process.getAddressSpaceRoot(root_address_space);
    try arch.mmu.mapTableInAddressSpace(root, 0x0040_0000, 0, .{ .user = true, .write = true });
    try arch.mmu.mapPageInAddressSpace(root, 0x0040_0000, 0x1000, .{ .user = true, .write = true });
    arch.mmu.switchAddressSpaceRoot(root);

    const manager_space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const manager_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        manager_space_capability,
        .{ .manage = true },
    );
    const fault_endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const wrong_endpoint_capability = try kernel.capability.createEndpointCapability(root_space);
    const fault_endpoint_handle = try kernel.capability.resolveEndpoint(
        root_space,
        fault_endpoint_capability,
        .{ .manage = true },
    );
    const manager_endpoint_capability = try kernel.capability.installCapability(
        root_space,
        manager_space_capability,
        fault_endpoint_capability,
        .{ .manage = true },
    );
    const attenuated_endpoint_capability = try kernel.capability.installCapability(
        root_space,
        manager_space_capability,
        fault_endpoint_capability,
        .{ .receive = true },
    );
    const manager_wrong_endpoint_capability = try kernel.capability.installCapability(
        root_space,
        manager_space_capability,
        wrong_endpoint_capability,
        .{ .manage = true },
    );

    try kernel.process.scheduler.initialize(root);
    kernel.process.execution_context.install(.{
        .thread_handle = kernel.process.execution_context.ROOT_THREAD_HANDLE,
        .capability_space_handle = manager_space,
        .address_space_handle = root_address_space,
        .process_handle = kernel.process.ROOT_PROCESS_HANDLE,
    });

    const request_address: u64 = 0x0040_0000;
    const resume_token: u32 = 0x101;
    const resume_thread = try createPendingManagedFault(
        root_address_space,
        fault_endpoint_handle,
        resume_token,
        0x0050_0000,
        0x1000,
    );
    const replacement_token: u32 = 0x202;
    const replacement_thread = try createPendingManagedFault(
        root_address_space,
        fault_endpoint_handle,
        replacement_token,
        0x0051_0000,
        0x2000,
    );

    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = resume_thread,
        .fault_token = resume_token,
        .action = .resume_thread,
        .reserved = 1,
    });
    try expectFailure(
        .fault_reply,
        error.InvalidFaultReply,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = resume_thread,
        .fault_token = resume_token,
        .action = @enumFromInt(99),
    });
    try expectFailure(
        .fault_reply,
        error.InvalidFaultReply,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = resume_thread,
        .fault_token = resume_token,
        .action = .resume_thread,
    });
    try expectFailure(
        .fault_reply,
        error.InsufficientCapabilityRights,
        abi.syscall.errorResult(.insufficient_rights),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ attenuated_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try expectFailure(
        .fault_reply,
        error.InvalidStateTransition,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_wrong_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = resume_thread,
        .fault_token = resume_token + 1,
        .action = .resume_thread,
    });
    try expectFailure(
        .fault_reply,
        error.FaultReplyUnauthorized,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = replacement_thread,
        .fault_token = resume_token,
        .action = .resume_thread,
    });
    try expectFailure(
        .fault_reply,
        error.FaultReplyUnauthorized,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = resume_thread,
        .fault_token = resume_token,
        .action = .resume_thread,
        .value = 1,
    });
    try expectFailure(
        .fault_reply,
        error.InvalidFaultReply,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );

    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = resume_thread,
        .fault_token = resume_token,
        .action = .resume_thread,
    });
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(
        kernel.process.thread.State.ready,
        (try kernel.process.thread.get(resume_thread)).state,
    );
    try expectFailure(
        .fault_reply,
        error.InvalidStateTransition,
        abi.syscall.errorResult(.invalid_state),
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );

    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = replacement_thread,
        .fault_token = replacement_token,
        .action = .resume_at,
        .value = 0x0051_1000,
    });
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    try std.testing.expectEqual(
        kernel.process.thread.State.ready,
        (try kernel.process.thread.get(replacement_thread)).state,
    );

    const termination_token: u32 = 0x303;
    const terminated_thread = try createPendingManagedFault(
        root_address_space,
        fault_endpoint_handle,
        termination_token,
        0x0052_0000,
        0x3000,
    );
    try writeFaultReplyRequest(0x1000, .{
        .thread_handle = terminated_thread,
        .fault_token = termination_token,
        .action = .terminate,
        .value = 37,
    });
    try expectReturned(
        abi.syscall.SYSCALL_SUCCESS,
        kernel.syscall.dispatchFromCurrentContext(
            request(.fault_reply, .{ manager_endpoint_capability, request_address, 0, 0, 0 }),
        ),
    );
    const terminated = try kernel.process.thread.get(terminated_thread);
    try std.testing.expectEqual(kernel.process.thread.State.exited, terminated.state);
    try std.testing.expectEqual(@as(?u64, 37), terminated.exit_status);
}
