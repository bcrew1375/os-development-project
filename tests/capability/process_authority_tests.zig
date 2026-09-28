const std = @import("std");
const kernel = @import("kernel_common");

const fixtures = @import("../support/capability/fixtures.zig");

const testSetup = fixtures.resetState;

test "Capability: thread and capability-space objects are bounded authorities" {
    testSetup();
    const root_space = kernel.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE;
    const space_capability = try kernel.capability.createCapabilitySpaceCapability(root_space);
    const child_space = try kernel.capability.resolveCapabilitySpace(
        root_space,
        space_capability,
        .{ .manage = true },
    );
    const thread_capability = try kernel.capability.createThreadCapability(root_space);
    const thread_handle = try kernel.capability.resolveThread(
        root_space,
        thread_capability,
        .{ .configure = true },
    );
    try std.testing.expect((try kernel.process.thread.get(thread_handle)).state == .new);

    try kernel.capability.destroyThreadCapability(root_space, thread_capability);
    try kernel.capability.destroyCapabilitySpaceCapability(root_space, space_capability);
    try std.testing.expectError(
        error.InvalidCapabilitySpaceHandle,
        kernel.process.capability_spaces.validate(child_space),
    );
}
