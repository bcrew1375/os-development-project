const std = @import("std");

pub const SourcePoint = struct {
    path: []const u8,
    line: u32,
    covered: bool,
};

pub const FileCoverage = struct {
    path: []const u8,
    covered_lines: usize,
    coverable_lines: usize,

    pub fn percentage(self: FileCoverage) ?f64 {
        if (self.coverable_lines == 0) return null;
        return 100.0 * @as(f64, @floatFromInt(self.covered_lines)) /
            @as(f64, @floatFromInt(self.coverable_lines));
    }
};

pub const Summary = struct {
    files: []FileCoverage,
    covered_lines: usize,
    coverable_lines: usize,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        for (self.files) |file| allocator.free(file.path);
        allocator.free(self.files);
        self.* = undefined;
    }

    pub fn percentage(self: Summary) ?f64 {
        const total: FileCoverage = .{
            .path = "",
            .covered_lines = self.covered_lines,
            .coverable_lines = self.coverable_lines,
        };
        return total.percentage();
    }
};

const LineState = struct {
    coverable: bool = false,
    covered: bool = false,
};

const FileState = struct {
    lines: std.AutoHashMapUnmanaged(u32, LineState) = .empty,

    fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
    }
};

pub fn summarize(
    allocator: std.mem.Allocator,
    common_root: []const u8,
    points: []const SourcePoint,
) !Summary {
    const normalized_root = try normalizePath(allocator, common_root);
    defer allocator.free(normalized_root);

    var states: std.StringArrayHashMapUnmanaged(FileState) = .empty;
    defer {
        for (states.keys(), states.values()) |path, *state| {
            allocator.free(path);
            state.deinit(allocator);
        }
        states.deinit(allocator);
    }

    try inventoryFiles(allocator, normalized_root, &states);

    for (points) |point| {
        if (point.line == 0) continue;
        const normalized_path = try normalizePath(allocator, point.path);
        defer allocator.free(normalized_path);

        const relative_path = relativeCommonPath(normalized_root, normalized_path) orelse continue;
        const state = states.getPtr(relative_path) orelse continue;
        const result = try state.lines.getOrPut(allocator, point.line);
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.coverable = true;
        result.value_ptr.covered = result.value_ptr.covered or point.covered;
    }

    var files = try allocator.alloc(FileCoverage, states.count());
    var initialized_files: usize = 0;
    errdefer {
        for (files[0..initialized_files]) |file| allocator.free(file.path);
        allocator.free(files);
    }

    var covered_total: usize = 0;
    var coverable_total: usize = 0;
    for (states.keys(), states.values(), 0..) |path, state, index| {
        var covered: usize = 0;
        var coverable: usize = 0;
        var line_iterator = state.lines.valueIterator();
        while (line_iterator.next()) |line| {
            coverable += @intFromBool(line.coverable);
            covered += @intFromBool(line.covered);
        }

        files[index] = .{
            .path = try std.fs.path.join(allocator, &.{ "src/common", path }),
            .covered_lines = covered,
            .coverable_lines = coverable,
        };
        initialized_files += 1;
        covered_total += covered;
        coverable_total += coverable;
    }

    std.mem.sort(FileCoverage, files, {}, struct {
        fn lessThan(_: void, left: FileCoverage, right: FileCoverage) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.lessThan);

    return .{
        .files = files,
        .covered_lines = covered_total,
        .coverable_lines = coverable_total,
    };
}

pub fn write(writer: *std.Io.Writer, summary: Summary) !void {
    try writer.writeAll("Common code coverage\n\n");
    try writer.print("{s:<52} {s:>9} {s:>10} {s:>10}\n", .{
        "File", "Covered", "Coverable", "Coverage",
    });

    for (summary.files) |file| {
        if (file.percentage()) |percentage| {
            try writer.print("{s:<52} {d:>9} {d:>10} {d:>9.2}%\n", .{
                file.path,
                file.covered_lines,
                file.coverable_lines,
                percentage,
            });
        } else {
            try writer.print("{s:<52} {d:>9} {d:>10} {s:>10}\n", .{
                file.path,
                file.covered_lines,
                file.coverable_lines,
                "N/A",
            });
        }
    }

    try writer.writeAll("-------------------------------------------------------------------------------------\n");
    if (summary.percentage()) |percentage| {
        try writer.print("{s:<52} {d:>9} {d:>10} {d:>9.2}%\n", .{
            "TOTAL",
            summary.covered_lines,
            summary.coverable_lines,
            percentage,
        });
    } else {
        try writer.print("{s:<52} {d:>9} {d:>10} {s:>10}\n", .{
            "TOTAL",
            summary.covered_lines,
            summary.coverable_lines,
            "N/A",
        });
    }
}

fn inventoryFiles(
    allocator: std.mem.Allocator,
    common_root: []const u8,
    states: *std.StringArrayHashMapUnmanaged(FileState),
) !void {
    var directory = try std.fs.openDirAbsolute(common_root, .{ .iterate = true });
    defer directory.close();

    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path);
        try states.put(allocator, path, .{});
    }
}

fn relativeCommonPath(common_root: []const u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, common_root)) return null;
    if (path.len == common_root.len) return null;
    if (path[common_root.len] != '/') return null;
    return path[common_root.len + 1 ..];
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const separators_normalized = try allocator.dupe(u8, path);
    defer allocator.free(separators_normalized);
    for (separators_normalized) |*character| {
        if (character.* == '\\') character.* = '/';
    }
    return std.fs.path.resolve(allocator, &.{separators_normalized});
}
