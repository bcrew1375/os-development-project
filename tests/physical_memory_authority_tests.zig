const abi = @import("abi");
const kernel = @import("kernel_common");
const std = @import("std");

const authority = kernel.memory_management.physical_memory_authority;

fn testSetup() void {
    authority.resetForTest();
}

test "Physical authority: create exposes immutable aligned range metadata" {
    testSetup();
    const handle = try authority.createRoot(
        0x2000,
        0x3000,
        abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        0x1000,
    );

    try std.testing.expectEqual(authority.Authority{
        .physical_start = 0x2000,
        .physical_end = 0x5000,
        .attributes = abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
        .kind = .untyped_memory,
        .parent = authority.INVALID_HANDLE,
        .bootstrap_root = true,
    }, try authority.get(handle));
    try std.testing.expectEqual(@as(usize, 1), authority.activeCount());
}

test "Physical authority: invalid ranges attributes and overlap are rejected" {
    testSetup();
    try std.testing.expectError(
        error.EmptyRange,
        authority.createRoot(0, 0, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000),
    );
    try std.testing.expectError(
        error.UnalignedRange,
        authority.createRoot(1, 0x1000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000),
    );
    try std.testing.expectError(
        error.InvalidAttributes,
        authority.createRoot(0, 0x1000, abi.boot_info.PHYSICAL_MEMORY_DEVICE, 0x1000),
    );
    try std.testing.expectError(
        error.RangeOverflow,
        authority.createRoot(
            std.math.maxInt(u64) - 0xfff,
            0x2000,
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            0x1000,
        ),
    );

    _ = try authority.createRoot(0x2000, 0x3000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    try std.testing.expectError(
        error.OverlappingAuthority,
        authority.createRoot(0x4000, 0x2000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000),
    );
}

test "Physical authority: bootstrap roots cannot be deleted" {
    testSetup();
    const first = try authority.createRoot(0, 0x1000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    try std.testing.expectError(error.BootstrapRootDeletion, authority.delete(first));
    try authority.destroyBootstrapRoot(first);
    try std.testing.expectError(error.InvalidAuthority, authority.get(first));

    const second = try authority.createRoot(0x1000, 0x1000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    try std.testing.expect(first != second);
    _ = try authority.get(second);
}

test "Physical authority: nested derivation rejects sibling overlap and typed parents" {
    testSetup();
    const root = try authority.createRoot(0x1000, 0x8000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    const child = try authority.derive(root, 0x1000, 0x4000, .untyped_memory, 0x1000);
    const frame = try authority.derive(child, 0x1000, 0x1000, .physical_frame, 0x1000);

    const frame_metadata = try authority.get(frame);
    try std.testing.expectEqual(@as(u64, 0x3000), frame_metadata.physical_start);
    try std.testing.expectEqual(authority.Kind.physical_frame, frame_metadata.kind);
    try std.testing.expectEqual(child, frame_metadata.parent);
    try std.testing.expectError(
        error.OverlappingAuthority,
        authority.derive(root, 0x2000, 0x1000, .untyped_memory, 0x1000),
    );
    try std.testing.expectError(
        error.InvalidAuthorityKind,
        authority.derive(frame, 0, 0x1000, .physical_frame, 0x1000),
    );
}

test "Physical authority: derivation validates alignment bounds and overflow" {
    testSetup();
    const root = try authority.createRoot(0x4000, 0x4000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    try std.testing.expectError(error.EmptyRange, authority.derive(root, 0, 0, .physical_frame, 0x1000));
    try std.testing.expectError(error.UnalignedRange, authority.derive(root, 1, 0x1000, .physical_frame, 0x1000));
    try std.testing.expectError(error.RangeOutOfBounds, authority.derive(root, 0x4000, 0x1000, .physical_frame, 0x1000));
    try std.testing.expectError(
        error.RangeOverflow,
        authority.derive(root, std.math.maxInt(u64) & ~@as(u64, 0xfff), 0x1000, .physical_frame, 0x1000),
    );
}

test "Physical authority: leaf deletion frees ranges and rejects stale handles" {
    testSetup();
    const root = try authority.createRoot(0, 0x4000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    const child = try authority.derive(root, 0, 0x2000, .untyped_memory, 0x1000);
    const frame = try authority.derive(child, 0, 0x1000, .physical_frame, 0x1000);

    try std.testing.expectError(error.AuthorityHasDescendants, authority.delete(child));
    try authority.delete(frame);
    try std.testing.expectError(error.InvalidAuthority, authority.get(frame));
    const replacement = try authority.derive(child, 0, 0x1000, .physical_frame, 0x1000);
    try std.testing.expect(frame != replacement);
}

test "Physical authority: revoke removes descendants deepest-first and preserves root" {
    testSetup();
    const root = try authority.createRoot(0, 0x8000, abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM, 0x1000);
    const child = try authority.derive(root, 0, 0x4000, .untyped_memory, 0x1000);
    const grandchild = try authority.derive(child, 0, 0x2000, .untyped_memory, 0x1000);
    const frame = try authority.derive(grandchild, 0, 0x1000, .physical_frame, 0x1000);

    try authority.revokeDescendants(root);
    _ = try authority.get(root);
    try std.testing.expectError(error.InvalidAuthority, authority.get(child));
    try std.testing.expectError(error.InvalidAuthority, authority.get(grandchild));
    try std.testing.expectError(error.InvalidAuthority, authority.get(frame));
    try std.testing.expectEqual(@as(usize, 1), authority.activeCount());
}

test "Physical authority: bounded storage reports exhaustion and reuse" {
    testSetup();
    for (0..authority.MAX_AUTHORITIES) |index| {
        _ = try authority.createRoot(
            index * 0x1000,
            0x1000,
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            0x1000,
        );
    }
    try std.testing.expectEqual(@as(usize, 0), authority.availableCount());
    try std.testing.expectError(
        error.OutOfAuthorities,
        authority.createRoot(
            authority.MAX_AUTHORITIES * 0x1000,
            0x1000,
            abi.boot_info.PHYSICAL_MEMORY_NORMAL_RAM,
            0x1000,
        ),
    );
}
