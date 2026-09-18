const arch = @import("arch");
const kernel = @import("kernel_common");
const std = @import("std");

test "Terminal: initialization reaches the platform console" {
    arch.platform.resetForTest();

    kernel.terminal.initialize();

    try std.testing.expectEqual(
        @as(usize, 1),
        arch.platform.getStateForTest().console_initialization_count,
    );
}

test "Terminal: print uses the default color and writes all bytes" {
    arch.platform.resetForTest();

    kernel.terminal.print.printString("print test");

    try std.testing.expectEqualStrings("print test", arch.platform.getConsoleBytesForTest());
    try std.testing.expectEqualSlices(
        arch.TextColor,
        &.{arch.TextColor.WHITE},
        arch.platform.getColorChangesForTest(),
    );
}

test "Terminal: colored print restores the default color" {
    arch.platform.resetForTest();

    kernel.terminal.print.printStringColor("colored test", arch.TextColor.GREEN);

    try std.testing.expectEqualStrings("colored test", arch.platform.getConsoleBytesForTest());
    try std.testing.expectEqualSlices(
        arch.TextColor,
        &.{ arch.TextColor.GREEN, arch.TextColor.WHITE },
        arch.platform.getColorChangesForTest(),
    );
}
