const std = @import("std");
const report = @import("coverage_report");

test "coverage report deduplicates source lines and filters other directories" {
    const common_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "src/common");
    defer std.testing.allocator.free(common_root);

    const capability_path = try std.fs.path.join(std.testing.allocator, &.{
        common_root,
        "capability/main.zig",
    });
    defer std.testing.allocator.free(capability_path);
    const non_canonical_capability_path = try std.fs.path.join(std.testing.allocator, &.{
        common_root,
        "../common/capability/main.zig",
    });
    defer std.testing.allocator.free(non_canonical_capability_path);

    const points = [_]report.SourcePoint{
        .{ .path = capability_path, .line = 34, .covered = false },
        .{ .path = non_canonical_capability_path, .line = 34, .covered = true },
        .{ .path = capability_path, .line = 35, .covered = false },
        .{ .path = "/workspace/tests/tests.zig", .line = 1, .covered = true },
        .{ .path = capability_path, .line = 0, .covered = true },
    };

    var summary = try report.summarize(std.testing.allocator, common_root, &points);
    defer summary.deinit(std.testing.allocator);

    const capability = findFile(summary.files, "src/common/capability/main.zig").?;
    try std.testing.expectEqual(@as(usize, 1), capability.covered_lines);
    try std.testing.expectEqual(@as(usize, 2), capability.coverable_lines);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), capability.percentage().?, 0.001);
    try std.testing.expect(summary.files.len >= 10);
}

test "coverage report inventories uninstrumented common files" {
    const common_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "src/common");
    defer std.testing.allocator.free(common_root);

    var summary = try report.summarize(std.testing.allocator, common_root, &.{});
    defer summary.deinit(std.testing.allocator);

    const namespace = findFile(summary.files, "src/common/memory_management/main.zig").?;
    try std.testing.expectEqual(@as(usize, 0), namespace.covered_lines);
    try std.testing.expectEqual(@as(usize, 0), namespace.coverable_lines);
    try std.testing.expectEqual(@as(?f64, null), namespace.percentage());
    try std.testing.expectEqual(@as(?f64, null), summary.percentage());
}

test "coverage report sorts files and aggregates totals" {
    const common_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "src/common");
    defer std.testing.allocator.free(common_root);
    const process_path = try std.fs.path.join(std.testing.allocator, &.{ common_root, "process/main.zig" });
    defer std.testing.allocator.free(process_path);

    const points = [_]report.SourcePoint{
        .{ .path = process_path, .line = 58, .covered = true },
        .{ .path = process_path, .line = 59, .covered = false },
    };
    var summary = try report.summarize(std.testing.allocator, common_root, &points);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.covered_lines);
    try std.testing.expectEqual(@as(usize, 2), summary.coverable_lines);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), summary.percentage().?, 0.001);
    for (summary.files[1..], summary.files[0 .. summary.files.len - 1]) |current, previous| {
        try std.testing.expect(std.mem.order(u8, previous.path, current.path) != .gt);
    }
}

fn findFile(files: []const report.FileCoverage, path: []const u8) ?report.FileCoverage {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}
