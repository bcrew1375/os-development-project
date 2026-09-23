const std = @import("std");
const report = @import("coverage_report");

test "coverage report merges points by source line and ignores unrelated paths" {
    const common_root = try realPath("src/common");
    defer std.testing.allocator.free(common_root);
    const capability_path = try joinPath(&.{ common_root, "capability/main.zig" });
    defer std.testing.allocator.free(capability_path);
    const alternate_path = try joinPath(&.{
        common_root,
        "../common/capability/main.zig",
    });
    defer std.testing.allocator.free(alternate_path);

    const points = [_]report.SourcePoint{
        .{ .path = capability_path, .line = 34, .covered = false },
        .{ .path = alternate_path, .line = 34, .covered = true },
        .{ .path = capability_path, .line = 35, .covered = false },
        .{ .path = "/workspace/tests/tests.zig", .line = 1, .covered = true },
        .{ .path = capability_path, .line = 0, .covered = true },
    };

    var summary = try report.summarize(std.testing.io, std.testing.allocator, common_root, &points);
    defer summary.deinit(std.testing.allocator);

    const capability = findFile(summary.files, "src/common/capability/main.zig").?;
    try expectCounts(capability.counts(), 1, 2);
    try std.testing.expectEqualSlices(u32, &.{35}, capability.missing_lines);
    try std.testing.expectApproxEqAbs(
        @as(f64, 50.0),
        capability.counts().percentage().?,
        0.001,
    );
}

test "coverage report inventories files with no emitted code" {
    const common_root = try realPath("src/common");
    defer std.testing.allocator.free(common_root);

    var summary = try report.summarize(std.testing.io, std.testing.allocator, common_root, &.{});
    defer summary.deinit(std.testing.allocator);

    const namespace = findFile(summary.files, "src/common/memory_management/main.zig").?;
    try expectCounts(namespace.counts(), 0, 0);
    try std.testing.expectEqual(@as(usize, 0), namespace.missing_lines.len);
    try std.testing.expectEqual(@as(?f64, null), namespace.counts().percentage());
    try std.testing.expectEqual(@as(?f64, null), summary.counts().percentage());
}

test "coverage report distinguishes emitted code without coverable lines" {
    const architecture_file = try realPath("src/architecture/architecture.zig");
    defer std.testing.allocator.free(architecture_file);
    const scopes = [_]report.Scope{.{
        .absolute_path = architecture_file,
        .display_path = "architecture.zig",
        .kind = .file,
    }};
    const points = [_]report.SourcePoint{.{
        .path = architecture_file,
        .line = 10,
        .covered = false,
        .coverable = false,
    }};
    var summary = try report.summarizeScopes(
        std.testing.io,
        std.testing.allocator,
        &scopes,
        &points,
    );
    defer summary.deinit(std.testing.allocator);

    const architecture = summary.files[0];
    try std.testing.expect(architecture.hasEmittedCode());
    try std.testing.expectEqual(@as(usize, 1), architecture.emitted_lines);
    try expectCounts(architecture.counts(), 0, 0);
    try std.testing.expectEqual(@as(usize, 0), architecture.missing_lines.len);
}

test "coverage report sorts missing lines, files, and derives totals" {
    const common_root = try realPath("src/common");
    defer std.testing.allocator.free(common_root);
    const process_path = try joinPath(&.{ common_root, "process/main.zig" });
    defer std.testing.allocator.free(process_path);

    const points = [_]report.SourcePoint{
        .{ .path = process_path, .line = 61, .covered = false },
        .{ .path = process_path, .line = 58, .covered = true },
        .{ .path = process_path, .line = 60, .covered = false },
        .{ .path = process_path, .line = 59, .covered = false },
    };
    var summary = try report.summarize(std.testing.io, std.testing.allocator, common_root, &points);
    defer summary.deinit(std.testing.allocator);

    try expectCounts(summary.counts(), 1, 4);
    const process = findFile(summary.files, "src/common/process/main.zig").?;
    try std.testing.expectEqualSlices(u32, &.{ 59, 60, 61 }, process.missing_lines);
    for (summary.files[1..], summary.files[0 .. summary.files.len - 1]) |current, previous| {
        try std.testing.expect(std.mem.order(u8, previous.path, current.path) != .gt);
    }
}

test "coverage report supports file and directory scopes" {
    const architecture_file = try realPath("src/architecture/architecture.zig");
    defer std.testing.allocator.free(architecture_file);
    const common_directory = try realPath("src/architecture/x86/common");
    defer std.testing.allocator.free(common_directory);
    const vectors_file = try joinPath(&.{ common_directory, "interrupts/vectors.zig" });
    defer std.testing.allocator.free(vectors_file);

    const scopes = [_]report.Scope{
        .{
            .absolute_path = architecture_file,
            .display_path = "architecture.zig",
            .kind = .file,
        },
        .{
            .absolute_path = common_directory,
            .display_path = "x86/common",
            .kind = .directory,
        },
    };
    const points = [_]report.SourcePoint{
        .{ .path = architecture_file, .line = 10, .covered = true },
        .{ .path = vectors_file, .line = 1, .covered = false },
    };
    var summary = try report.summarizeScopes(
        std.testing.io,
        std.testing.allocator,
        &scopes,
        &points,
    );
    defer summary.deinit(std.testing.allocator);

    const architecture = findFile(summary.files, "architecture.zig").?;
    const vectors = findFile(summary.files, "x86/common/interrupts/vectors.zig").?;
    try expectCounts(architecture.counts(), 1, 1);
    try expectCounts(vectors.counts(), 0, 1);
    try std.testing.expectEqualSlices(u32, &.{1}, vectors.missing_lines);
}

test "coverage report rejects overlapping inventory entries" {
    const architecture_file = try realPath("src/architecture/architecture.zig");
    defer std.testing.allocator.free(architecture_file);
    const scopes = [_]report.Scope{
        .{
            .absolute_path = architecture_file,
            .display_path = "architecture.zig",
            .kind = .file,
        },
        .{
            .absolute_path = architecture_file,
            .display_path = "architecture.zig",
            .kind = .file,
        },
    };

    try std.testing.expectError(
        error.DuplicateCoverageScope,
        report.summarizeScopes(std.testing.io, std.testing.allocator, &scopes, &.{}),
    );
}

test "coverage report releases partial state after allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        summarizeSingleFile,
        .{},
    );
}

test "coverage table preserves complete paths and compresses ranges" {
    var files = [_]report.FileCoverage{
        .{
            .path = "short.zig",
            .coverable_lines = 7,
            .missing_lines = &.{ 12, 13, 14, 31, 44, 45 },
        },
        .{
            .path = "x86/32/interrupts/interrupt_descriptor_table.zig",
            .coverable_lines = 14,
            .missing_lines = &.{},
        },
        .{
            .path = "x86/64/interrupts/interrupt_descriptor_table.zig",
            .coverable_lines = 18,
            .missing_lines = &.{},
        },
        .{
            .path = "namespace.zig",
            .coverable_lines = 0,
            .missing_lines = &.{},
        },
        .{
            .path = "emitted_without_instrumentation.zig",
            .emitted_lines = 2,
            .coverable_lines = 0,
            .missing_lines = &.{},
        },
    };
    const summary: report.Summary = .{ .files = &files };
    var output_buffer: [4096]u8 = undefined;
    const output = try renderTable(&output_buffer, summary);

    var lines = std.mem.splitScalar(u8, output, '\n');
    const header = lines.next().?;
    try expectColumns(header, "File", "Covered", "Coverable", "Coverage", "Missing");
    try expectColumns(lines.next().?, "short.zig", "1", "7", "14.29%", "12-14, 31, 44-45");
    const x86_32 = lines.next().?;
    const x86_64 = lines.next().?;
    try expectColumns(
        x86_32,
        "x86/32/interrupts/interrupt_descriptor_table.zig",
        "14",
        "14",
        "100.00%",
        "",
    );
    try expectColumns(
        x86_64,
        "x86/64/interrupts/interrupt_descriptor_table.zig",
        "18",
        "18",
        "100.00%",
        "",
    );
    try expectColumns(lines.next().?, "namespace.zig", "0", "0", "no emitted code", "");
    try expectColumns(
        lines.next().?,
        "emitted_without_instrumentation.zig",
        "0",
        "0",
        "no coverable code",
        "",
    );
    const separator = lines.next().?;
    try std.testing.expectEqual(@as(usize, 108), separator.len);
    for (separator) |character| try std.testing.expectEqual(@as(u8, '-'), character);
    try expectColumns(lines.next().?, "TOTAL", "33", "39", "84.62%", "");
    try std.testing.expectEqualStrings("", lines.next().?);
}

test "coverage table wraps complete ranges on aligned continuation rows" {
    var files = [_]report.FileCoverage{.{
        .path = "wrapped.zig",
        .coverable_lines = 16,
        .missing_lines = &.{
            1,                    2,  3,  10, 20, 21, 22,
            30,                   40, 41, 50, 60, 61, std.math.maxInt(u32) - 1,
            std.math.maxInt(u32),
        },
    }};
    const summary: report.Summary = .{ .files = &files };
    var output_buffer: [4096]u8 = undefined;
    const output = try renderTable(&output_buffer, summary);

    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next();
    try expectColumns(
        lines.next().?,
        "wrapped.zig",
        "1",
        "16",
        "6.25%",
        "1-3, 10, 20-22, 30",
    );
    try expectContinuation(lines.next().?, "40-41, 50, 60-61");
    try expectContinuation(lines.next().?, "4294967294-4294967295");
}

fn renderTable(output_buffer: []u8, summary: report.Summary) ![]const u8 {
    var writer: std.Io.Writer = .fixed(output_buffer);
    try report.writeTable(&writer, summary);
    return output_buffer[0..writer.end];
}

fn summarizeSingleFile(allocator: std.mem.Allocator) !void {
    const canonical_architecture_file = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "src/architecture/architecture.zig",
        allocator,
    );
    defer allocator.free(canonical_architecture_file);
    const architecture_file = try allocator.dupe(u8, canonical_architecture_file);
    defer allocator.free(architecture_file);
    const scopes = [_]report.Scope{.{
        .absolute_path = architecture_file,
        .display_path = "architecture.zig",
        .kind = .file,
    }};
    const points = [_]report.SourcePoint{.{
        .path = architecture_file,
        .line = 10,
        .covered = false,
    }};
    var summary = try report.summarizeScopes(std.testing.io, allocator, &scopes, &points);
    defer summary.deinit(allocator);
}

fn expectColumns(
    line: []const u8,
    expected_path: ?[]const u8,
    expected_covered: []const u8,
    expected_coverable: []const u8,
    expected_coverage: []const u8,
    expected_missing: []const u8,
) !void {
    const path_width = line.len - 60;
    if (expected_path) |path| try std.testing.expectEqualStrings(path, pathColumn(line, path_width));
    try std.testing.expectEqualStrings(expected_covered, trimColumn(line[path_width + 1 .. path_width + 8]));
    try std.testing.expectEqualStrings(expected_coverable, trimColumn(line[path_width + 9 .. path_width + 18]));
    try std.testing.expectEqualStrings(expected_coverage, trimColumn(line[path_width + 19 .. path_width + 36]));
    try std.testing.expectEqualStrings(expected_missing, trimColumn(line[path_width + 37 ..]));
}

fn expectContinuation(line: []const u8, expected_missing: []const u8) !void {
    const missing_offset = line.len - 23;
    try std.testing.expectEqualStrings("", trimColumn(line[0..missing_offset]));
    try std.testing.expectEqualStrings(expected_missing, trimColumn(line[missing_offset..]));
}

fn pathColumn(line: []const u8, path_width: usize) []const u8 {
    return trimColumn(line[0..path_width]);
}

fn trimColumn(column: []const u8) []const u8 {
    return std.mem.trim(u8, column, " ");
}

fn expectCounts(
    actual: report.CoverageCounts,
    expected_covered: usize,
    expected_coverable: usize,
) !void {
    try std.testing.expectEqual(expected_covered, actual.covered);
    try std.testing.expectEqual(expected_coverable, actual.coverable);
}

fn findFile(files: []const report.FileCoverage, path: []const u8) ?report.FileCoverage {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

fn realPath(path: []const u8) ![]u8 {
    const canonical_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(canonical_path);
    return std.testing.allocator.dupe(u8, canonical_path);
}

fn joinPath(parts: []const []const u8) ![]u8 {
    return std.fs.path.join(std.testing.allocator, parts);
}
