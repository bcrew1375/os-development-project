pub const Scope = struct {
    pub const Kind = enum { file, directory };

    repository_path: []const u8,
    kind: Kind,
};

const x86_32_scopes = [_]Scope{
    .{ .repository_path = "src/architecture/architecture.zig", .kind = .file },
    .{ .repository_path = "src/architecture/early_allocator.zig", .kind = .file },
    .{ .repository_path = "src/architecture/x86/common/arch.zig", .kind = .file },
    .{ .repository_path = "src/architecture/x86/common/interrupts", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/common/platform", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/32/arch.zig", .kind = .file },
    .{ .repository_path = "src/architecture/x86/32/boot/main.zig", .kind = .file },
    .{ .repository_path = "src/architecture/x86/32/boot/multiboot", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/32/cpu", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/32/early_allocator", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/32/interrupts", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/32/mmu", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/32/platform", .kind = .directory },
};

const x86_64_scopes = [_]Scope{
    .{ .repository_path = "src/architecture/architecture.zig", .kind = .file },
    .{ .repository_path = "src/architecture/early_allocator.zig", .kind = .file },
    .{ .repository_path = "src/architecture/x86/common/arch.zig", .kind = .file },
    .{ .repository_path = "src/architecture/x86/common/boot/limine", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/common/interrupts", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/common/platform", .kind = .directory },
    .{ .repository_path = "src/architecture/x86/64", .kind = .directory },
};

pub fn scopesForArchitecture(architecture_name: []const u8) ![]const Scope {
    if (equal(architecture_name, "x86_32")) return &x86_32_scopes;
    if (equal(architecture_name, "x86_64")) return &x86_64_scopes;
    return error.InvalidArchitecture;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (left_byte != right_byte) return false;
    }
    return true;
}
