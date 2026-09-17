const std = @import("std");
const report = @import("coverage_report");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.next();
    const points_path = args.next() orelse return error.MissingPointsPath;
    const repository_root = args.next() orelse return error.MissingRepositoryRoot;
    if (args.next() != null) return error.UnexpectedArgument;

    const bytes = try std.fs.cwd().readFileAlloc(allocator, points_path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    var points: std.ArrayListUnmanaged(report.SourcePoint) = .empty;
    defer points.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = fields.next() orelse return error.InvalidPoint;
        const line_number = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.InvalidPoint, 10);
        const covered_text = fields.next() orelse return error.InvalidPoint;
        if (fields.next() != null) return error.InvalidPoint;
        try points.append(allocator, .{
            .path = path,
            .line = line_number,
            .covered = std.mem.eql(u8, covered_text, "1"),
        });
    }

    const scopes = [_]report.Scope{
        try fileScope(allocator, repository_root, "src/architecture/architecture.zig"),
        try fileScope(allocator, repository_root, "src/architecture/early_allocator.zig"),
        try directoryScope(allocator, repository_root, "src/architecture/x86/common"),
        try directoryScope(allocator, repository_root, "src/architecture/x86/64"),
    };
    defer for (scopes) |scope| allocator.free(scope.absolute_path);
    var summary = try report.summarizeScopes(allocator, &scopes, points.items);
    defer summary.deinit(allocator);

    var output_buffer: [4096]u8 = undefined;
    var output = std.fs.File.stdout().writer(&output_buffer);
    try output.interface.writeAll("Architecture coverage: x86_64\n\n");
    try report.writeTable(&output.interface, summary);
    try output.interface.flush();
}

fn fileScope(allocator: std.mem.Allocator, root: []const u8, path: []const u8) !report.Scope {
    return .{
        .absolute_path = try std.fs.path.join(allocator, &.{ root, path }),
        .display_path = path,
        .kind = .file,
    };
}

fn directoryScope(allocator: std.mem.Allocator, root: []const u8, path: []const u8) !report.Scope {
    return .{
        .absolute_path = try std.fs.path.join(allocator, &.{ root, path }),
        .display_path = path,
        .kind = .directory,
    };
}
