const std = @import("std");
const abi = @import("abi");
const shared = @import("shared");

test "BootInfo ABI layout is stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(abi.boot_info.BootInfo));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(abi.boot_info.BootInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.boot_info.BootInfo, "magic"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(abi.boot_info.BootInfo, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.boot_info.BootInfo, "module_count"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(abi.boot_info.BootInfo, "modules_address"));
}

test "BootModuleInfo ABI layout is stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(abi.boot_info.BootModuleInfo));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(abi.boot_info.BootModuleInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.boot_info.BootModuleInfo, "physical_start"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.boot_info.BootModuleInfo, "physical_end"));
}

test "Capability rights containment is explicit" {
    const all = abi.capability.Rights{
        .read = true,
        .write = true,
        .execute = true,
        .manage = true,
    };

    try std.testing.expect(all.contains(.{ .read = true }));
    try std.testing.expect(all.contains(.{ .read = true, .write = true }));
    try std.testing.expect(!(abi.capability.Rights{ .read = true }).contains(.{ .write = true }));
}

test "ELF parser rejects non-ELF bytes" {
    const image = "not an elf image";
    try std.testing.expectError(
        error.InvalidElfImage,
        shared.executable.elf.parseLoadableImage(image, 4096),
    );
}
