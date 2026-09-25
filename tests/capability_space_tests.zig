const kernel = @import("kernel_common");
const std = @import("std");

fn setup() void {
    kernel.process.resetForTest();
}

test "Capability space: root identity is valid and bounded storage is explicit" {
    setup();
    const spaces = kernel.process.capability_spaces;
    try spaces.validate(spaces.ROOT_CAPABILITY_SPACE_HANDLE);
    try std.testing.expectEqual(@as(usize, 1), spaces.activeCount());

    var handles: [spaces.MAX_CAPABILITY_SPACES - 1]spaces.Handle = undefined;
    for (&handles) |*handle| handle.* = try spaces.create();
    try std.testing.expectEqual(@as(usize, spaces.MAX_CAPABILITY_SPACES), spaces.activeCount());
    try std.testing.expectError(error.OutOfCapabilitySpaces, spaces.create());
}

test "Capability space: destroyed handles become stale and slots are reusable" {
    setup();
    const spaces = kernel.process.capability_spaces;
    const stale = try spaces.create();
    try spaces.destroy(stale);
    try std.testing.expectError(error.InvalidCapabilitySpaceHandle, spaces.validate(stale));

    const replacement = try spaces.create();
    try std.testing.expect(replacement != stale);
    try spaces.validate(replacement);
    try std.testing.expectError(
        error.CapabilitySpaceInUse,
        spaces.destroy(spaces.ROOT_CAPABILITY_SPACE_HANDLE),
    );
}
