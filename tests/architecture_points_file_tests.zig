const std = @import("std");
const points_file = @import("architecture_points_file");

test "architecture points file parses valid and empty point lists" {
    var parsed = try readFixture(
        "OS_ARCHITECTURE_COVERAGE_POINTS\t3\n" ++
            "architecture\tx86_64\n" ++
            "instrumentation_points\t2\n" ++
            "source_points\t3\n" ++
            "points\n" ++
            "src/architecture/a.zig\t12\t1\n" ++
            "src/architecture/b.zig\t34\t0\n" ++
            "src/architecture/c.zig\t56\t2\n",
        "x86_64",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.source_points.len);
    try std.testing.expectEqualStrings("src/architecture/a.zig", parsed.source_points[0].path);
    try std.testing.expectEqual(@as(u32, 12), parsed.source_points[0].line);
    try std.testing.expect(parsed.source_points[0].covered);
    try std.testing.expect(parsed.source_points[0].coverable);
    try std.testing.expect(!parsed.source_points[2].covered);
    try std.testing.expect(!parsed.source_points[2].coverable);

    var empty = try readFixture(
        "OS_ARCHITECTURE_COVERAGE_POINTS\t3\n" ++
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
        readFixture(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t1\narchitecture\tx86_64\n" ++
                "instrumentation_points\t0\nsource_points\t0\npoints\n",
            "x86_64",
        ),
    );
    try std.testing.expectError(
        error.ArchitectureMismatch,
        readFixture(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t3\narchitecture\tx86_32\n" ++
                "instrumentation_points\t0\nsource_points\t0\npoints\n",
            "x86_64",
        ),
    );
    try std.testing.expectError(
        error.InvalidPointsHeader,
        readFixture("OS_ARCHITECTURE_COVERAGE_POINTS\t3\n", "x86_64"),
    );
    try std.testing.expectError(
        error.InvalidPointsHeader,
        readFixture(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t3\narchitecture\tx86_64\n" ++
                "instrumentation_points\tnot-a-number\nsource_points\t0\npoints\n",
            "x86_64",
        ),
    );
    try std.testing.expectError(
        error.InvalidPointsHeader,
        readFixture(
            "OS_ARCHITECTURE_COVERAGE_POINTS\t3\narchitecture\tx86_64\n" ++
                "instrumentation_points\t0\nsource_points\tnan\npoints\n",
            "x86_64",
        ),
    );
}

test "architecture points file rejects malformed records and count mismatch" {
    const header = "OS_ARCHITECTURE_COVERAGE_POINTS\t3\n" ++
        "architecture\tx86_64\n" ++
        "instrumentation_points\t1\n" ++
        "source_points\t1\n" ++
        "points\n";

    try std.testing.expectError(
        error.InvalidPoint,
        readFixture(header ++ "path\t1\t3\n", "x86_64"),
    );
    try std.testing.expectError(
        error.InvalidPoint,
        readFixture(header ++ "path\tnan\t1\n", "x86_64"),
    );
    try std.testing.expectError(
        error.InvalidPoint,
        readFixture(header ++ "path\t1\t1\textra\n", "x86_64"),
    );
    try std.testing.expectError(
        error.SourcePointCountMismatch,
        readFixture(header, "x86_64"),
    );
}

fn readFixture(
    contents: []const u8,
    expected_architecture: []const u8,
) !points_file.Parsed {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    try temporary_directory.dir.writeFile(std.testing.io, .{
        .sub_path = "points.tsv",
        .data = contents,
    });
    const canonical_file_path = try temporary_directory.dir.realPathFileAlloc(
        std.testing.io,
        "points.tsv",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(canonical_file_path);
    const file_path = try std.testing.allocator.dupe(u8, canonical_file_path);
    defer std.testing.allocator.free(file_path);
    return points_file.read(std.testing.io, std.testing.allocator, file_path, expected_architecture);
}
