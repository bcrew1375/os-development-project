const std = @import("std");
const report = @import("coverage_report");
const points_file = @import("architecture_points_file");

fn expectPointsFile(
    contents: []const u8,
    expected_architecture: []const u8,
) !points_file.Parsed {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.writeFile(.{
        .sub_path = "points.tsv",
        .data = contents,
    });
    const file_path = try temporary_directory.dir.realpathAlloc(
        std.testing.allocator,
        "points.tsv",
    );
    defer std.testing.allocator.free(file_path);
    return points_file.read(std.testing.allocator, file_path, expected_architecture);
}

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

test "coverage report supports file and directory scopes" {
    const architecture_file = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "src/architecture/architecture.zig",
    );
    defer std.testing.allocator.free(architecture_file);
    const common_directory = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "src/architecture/x86/common",
    );
    defer std.testing.allocator.free(common_directory);
    const vectors_file = try std.fs.path.join(
        std.testing.allocator,
        &.{ common_directory, "interrupts/vectors.zig" },
    );
    defer std.testing.allocator.free(vectors_file);

    const scopes = [_]report.Scope{
        .{
            .absolute_path = architecture_file,
            .display_path = "src/architecture/architecture.zig",
            .kind = .file,
        },
        .{
            .absolute_path = common_directory,
            .display_path = "src/architecture/x86/common",
            .kind = .directory,
        },
    };
    const points = [_]report.SourcePoint{
        .{ .path = architecture_file, .line = 10, .covered = true },
        .{ .path = vectors_file, .line = 1, .covered = false },
    };
    var summary = try report.summarizeScopes(
        std.testing.allocator,
        &scopes,
        &points,
    );
    defer summary.deinit(std.testing.allocator);

    const architecture = findFile(
        summary.files,
        "src/architecture/architecture.zig",
    ).?;
    const vectors = findFile(
        summary.files,
        "src/architecture/x86/common/interrupts/vectors.zig",
    ).?;
    try std.testing.expectEqual(@as(usize, 1), architecture.covered_lines);
    try std.testing.expectEqual(@as(usize, 1), architecture.coverable_lines);
    try std.testing.expectEqual(@as(usize, 0), vectors.covered_lines);
    try std.testing.expectEqual(@as(usize, 1), vectors.coverable_lines);
}

test "coverage report rejects duplicate scopes" {
    const architecture_file = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "src/architecture/architecture.zig",
    );
    defer std.testing.allocator.free(architecture_file);
    const scopes = [_]report.Scope{
        .{
            .absolute_path = architecture_file,
            .display_path = "src/architecture/architecture.zig",
            .kind = .file,
        },
        .{
            .absolute_path = architecture_file,
            .display_path = "src/architecture/architecture.zig",
            .kind = .file,
        },
    };

    try std.testing.expectError(
        error.DuplicateCoverageScope,
        report.summarizeScopes(std.testing.allocator, &scopes, &.{}),
    );
}

test "coverage table keeps columns aligned for long paths" {
    const files = [_]report.FileCoverage{
        .{
            .path = "short.zig",
            .covered_lines = 1,
            .coverable_lines = 2,
        },
        .{
            .path = "src/architecture/x86/64/interrupts/interrupt_descriptor_table.zig",
            .covered_lines = 18,
            .coverable_lines = 18,
        },
        .{
            .path = "src/architecture/namespace.zig",
            .covered_lines = 0,
            .coverable_lines = 0,
        },
    };
    const summary: report.Summary = .{
        .files = @constCast(&files),
        .covered_lines = 19,
        .coverable_lines = 20,
    };

    var output_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output_buffer);
    try report.writeTable(&writer, summary);
    const output = output_buffer[0..writer.end];

    var lines = std.mem.splitScalar(u8, output, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expectEqual(@as(usize, 77), line.len);
        line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), line_count);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/architecture/x8...descriptor_table.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "95.00%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no emitted code") != null);
}

test "architecture points file parses valid and empty point lists" {
    var parsed = try expectPointsFile(
        "OS_ARCHITECTURE_COVERAGE_POINTS\t2\n" ++
            "architecture\tx86_64\n" ++
            "instrumentation_points\t2\n" ++
            "source_points\t2\n" ++
            "points\n" ++
            "src/architecture/a.zig\t12\t1\n" ++
            "src/architecture/b.zig\t34\t0\n",
        "x86_64",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.source_points.len);
    try std.testing.expectEqualStrings("src/architecture/a.zig", parsed.source_points[0].path);
    try std.testing.expectEqual(@as(u32, 12), parsed.source_points[0].line);
    try std.testing.expect(parsed.source_points[0].covered);

    var empty = try expectPointsFile(
        "OS_ARCHITECTURE_COVERAGE_POINTS\t2\n" ++
            "architecture\tx86_32\n" ++
            "instrumentation_points\t0\n" ++
            "source_points\t0\n" ++
            "points\n",
        "x86_32",
    );
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.source_points.len);
}

test "architecture points file rejects invalid headers" {
    try std.testing.expectError(
        error.InvalidPointsHeader,
        expectPointsFile(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t1\narchitecture\tx86_64\n" ++
                "instrumentation_points\t0\nsource_points\t0\npoints\n",
            "x86_64",
        ),
    );
    try std.testing.expectError(
        error.ArchitectureMismatch,
        expectPointsFile(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t2\narchitecture\tx86_32\n" ++
                "instrumentation_points\t0\nsource_points\t0\npoints\n",
            "x86_64",
        ),
    );
    try std.testing.expectError(
        error.InvalidPointsHeader,
        expectPointsFile("OS_ARCHITECTURE_COVERAGE_POINTS\t2\n", "x86_64"),
    );
    try std.testing.expectError(
        error.InvalidPointsHeader,
        expectPointsFile(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t2\narchitecture\tx86_64\n" ++
                "instrumentation_points\tnot-a-number\nsource_points\t0\npoints\n",
            "x86_64",
        ),
    );
    try std.testing.expectError(
        error.InvalidPointsHeader,
        expectPointsFile(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t2\narchitecture\tx86_64\n" ++
                "instrumentation_points\t0\nsource_points\tnan\npoints\n",
            "x86_64",
        ),
    );
}

test "architecture points file rejects malformed records and count mismatch" {
    const header = "OS_ARCHITECTURE_COVERAGE_POINTS\t2\n" ++
        "architecture\tx86_64\n" ++
        "instrumentation_points\t1\n" ++
        "source_points\t1\n" ++
        "points\n";

    try std.testing.expectError(
        error.InvalidPoint,
        expectPointsFile(header ++ "path\t1\t2\n", "x86_64"),
    );
    try std.testing.expectError(
        error.InvalidPoint,
        expectPointsFile(header ++ "path\tnan\t1\n", "x86_64"),
    );
    try std.testing.expectError(
        error.InvalidPoint,
        expectPointsFile(header ++ "path\t1\t1\textra\n", "x86_64"),
    );
    try std.testing.expectError(
        error.SourcePointCountMismatch,
        expectPointsFile(header, "x86_64"),
    );
}

fn findFile(files: []const report.FileCoverage, path: []const u8) ?report.FileCoverage {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}
