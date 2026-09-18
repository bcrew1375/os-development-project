const std = @import("std");
const coverage_report = @import("coverage_report");

const maximum_file_size = 64 * 1024 * 1024;
const format_header = "OS_ARCHITECTURE_COVERAGE_POINTS\t2";

pub const Parsed = struct {
    file_contents: []u8,
    source_points: []coverage_report.SourcePoint,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.source_points);
        allocator.free(self.file_contents);
    }
};

pub fn read(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    expected_architecture: []const u8,
) !Parsed {
    const file_contents = try std.fs.cwd().readFileAlloc(
        allocator,
        file_path,
        maximum_file_size,
    );
    errdefer allocator.free(file_contents);

    var source_points: std.ArrayListUnmanaged(coverage_report.SourcePoint) = .empty;
    errdefer source_points.deinit(allocator);
    var lines = std.mem.splitScalar(u8, file_contents, '\n');
    const expected_source_point_count = try parseHeader(&lines, expected_architecture);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try source_points.append(allocator, try parseSourcePoint(line));
    }
    if (source_points.items.len != expected_source_point_count) {
        return error.SourcePointCountMismatch;
    }
    return .{
        .file_contents = file_contents,
        .source_points = try source_points.toOwnedSlice(allocator),
    };
}

fn parseHeader(
    lines: *std.mem.SplitIterator(u8, .scalar),
    expected_architecture: []const u8,
) !usize {
    try expectLine(lines.next(), format_header);
    const recorded_architecture = try headerValue(lines.next(), "architecture");
    if (!std.mem.eql(u8, recorded_architecture, expected_architecture)) {
        return error.ArchitectureMismatch;
    }
    const instrumentation_point_count = try headerValue(
        lines.next(),
        "instrumentation_points",
    );
    _ = std.fmt.parseUnsigned(
        usize,
        instrumentation_point_count,
        10,
    ) catch return error.InvalidPointsHeader;
    const source_point_count = try headerValue(lines.next(), "source_points");
    const parsed_source_point_count = std.fmt.parseUnsigned(
        usize,
        source_point_count,
        10,
    ) catch return error.InvalidPointsHeader;
    try expectLine(lines.next(), "points");
    return parsed_source_point_count;
}

fn parseSourcePoint(line: []const u8) !coverage_report.SourcePoint {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const source_path = fields.next() orelse return error.InvalidPoint;
    const line_number_text = fields.next() orelse return error.InvalidPoint;
    const covered_text = fields.next() orelse return error.InvalidPoint;
    if (fields.next() != null) return error.InvalidPoint;
    if (!std.mem.eql(u8, covered_text, "0") and
        !std.mem.eql(u8, covered_text, "1"))
    {
        return error.InvalidPoint;
    }
    return .{
        .path = source_path,
        .line = std.fmt.parseUnsigned(u32, line_number_text, 10) catch {
            return error.InvalidPoint;
        },
        .covered = std.mem.eql(u8, covered_text, "1"),
    };
}

fn expectLine(actual: ?[]const u8, expected: []const u8) !void {
    if (actual == null or !std.mem.eql(u8, actual.?, expected)) {
        return error.InvalidPointsHeader;
    }
}

fn headerValue(line: ?[]const u8, field_name: []const u8) ![]const u8 {
    const header_line = line orelse return error.InvalidPointsHeader;
    var fields = std.mem.splitScalar(u8, header_line, '\t');
    const actual_field_name = fields.next() orelse return error.InvalidPointsHeader;
    if (!std.mem.eql(u8, actual_field_name, field_name)) {
        return error.InvalidPointsHeader;
    }
    const value = fields.next() orelse return error.InvalidPointsHeader;
    if (fields.next() != null) return error.InvalidPointsHeader;
    return value;
}
