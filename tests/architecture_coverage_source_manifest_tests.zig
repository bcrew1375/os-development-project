const std = @import("std");
const source_manifest = @import("architecture_coverage_source_manifest");

test "x86-32 coverage inventory selects Multiboot and excludes Limine" {
    const scopes = try source_manifest.scopesForArchitecture("x86_32");

    try expectScope(scopes, "src/architecture/x86/32/boot/multiboot", .directory);
    try expectNoScope(scopes, "src/architecture/x86/32/boot/limine");
    try expectNoScope(scopes, "src/architecture/x86/common/boot/limine");
}

test "x86-64 coverage inventory includes its complete Limine path" {
    const scopes = try source_manifest.scopesForArchitecture("x86_64");

    try expectScope(scopes, "src/architecture/x86/64", .directory);
    try expectScope(scopes, "src/architecture/x86/common/boot/limine", .directory);
}

test "architecture coverage inventory rejects unsupported architectures" {
    try std.testing.expectError(
        error.InvalidArchitecture,
        source_manifest.scopesForArchitecture("arm64"),
    );
}

fn expectScope(
    scopes: []const source_manifest.Scope,
    repository_path: []const u8,
    kind: source_manifest.Scope.Kind,
) !void {
    for (scopes) |scope| {
        if (!std.mem.eql(u8, scope.repository_path, repository_path)) continue;
        try std.testing.expectEqual(kind, scope.kind);
        return;
    }
    return error.ExpectedScopeNotFound;
}

fn expectNoScope(
    scopes: []const source_manifest.Scope,
    repository_path: []const u8,
) !void {
    for (scopes) |scope| {
        try std.testing.expect(!std.mem.eql(u8, scope.repository_path, repository_path));
    }
}
