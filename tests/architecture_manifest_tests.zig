const manifest = @import("architecture/manifest.zig");

const std = @import("std");

fn expectLastSharedTest(
    architecture: manifest.Architecture,
    expected_test_id: manifest.TestId,
) !void {
    var last_shared_test: ?manifest.TestId = null;
    for (manifest.tests) |test_case| {
        if (!test_case.supports(architecture)) continue;
        if (test_case.mode != .shared_machine) continue;
        last_shared_test = test_case.id;
    }

    try std.testing.expect(last_shared_test != null);
    try std.testing.expectEqual(expected_test_id, last_shared_test.?);
}

test "shared coverage initializes descriptor tables last" {
    try expectLastSharedTest(.x86_32, .x86_32_descriptor_tables_initialize);
    try expectLastSharedTest(.x86_64, .x86_64_descriptor_tables_initialize);
}
