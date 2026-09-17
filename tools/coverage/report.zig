const std = @import("std");

pub const SourcePoint = struct {
    path: []const u8,
    line: u32,
    covered: bool,
};

pub const Scope = struct {
    pub const Kind = enum { file, directory };

    absolute_path: []const u8,
    display_path: []const u8,
    kind: Kind,
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
    return summarizeScopes(allocator, &.{.{
        .absolute_path = common_root,
        .display_path = "src/common",
        .kind = .directory,
    }}, points);
}

pub fn summarizeScopes(
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    points: []const SourcePoint,
) !Summary {
    const NormalizedScope = struct {
        absolute_path: []u8,
        display_path: []const u8,
        kind: Scope.Kind,
    };
    const normalized_scopes = try allocator.alloc(NormalizedScope, scopes.len);
    defer allocator.free(normalized_scopes);
    var initialized_scopes: usize = 0;
    defer for (normalized_scopes[0..initialized_scopes]) |scope| {
        allocator.free(scope.absolute_path);
    };
    for (scopes, normalized_scopes) |scope, *normalized| {
        normalized.* = .{
            .absolute_path = try normalizePath(allocator, scope.absolute_path),
            .display_path = scope.display_path,
            .kind = scope.kind,
        };
        initialized_scopes += 1;
    }

    var states: std.StringArrayHashMapUnmanaged(FileState) = .empty;
    defer {
        for (states.keys(), states.values()) |path, *state| {
            allocator.free(path);
            state.deinit(allocator);
        }
        states.deinit(allocator);
    }

    for (normalized_scopes) |scope| {
        try inventoryScope(allocator, scope, &states);
    }

    for (points) |point| {
        if (point.line == 0) continue;
        const normalized_path = try normalizePath(allocator, point.path);
        defer allocator.free(normalized_path);

        const display_path = try pointDisplayPath(allocator, normalized_scopes, normalized_path) orelse continue;
        defer allocator.free(display_path);
        const state = states.getPtr(display_path) orelse continue;
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
            .path = try allocator.dupe(u8, path),
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
    try writeTable(writer, summary);
}

pub fn writeTable(writer: *std.Io.Writer, summary: Summary) !void {
    try writer.print("{s:<52} {s:>9} {s:>10} {s:>12}\n", .{
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
            try writer.print("{s:<52} {d:>9} {d:>10} {s:>12}\n", .{
                file.path,
                file.covered_lines,
                file.coverable_lines,
                "not emitted",
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
        try writer.print("{s:<52} {d:>9} {d:>10} {s:>12}\n", .{
            "TOTAL",
            summary.covered_lines,
            summary.coverable_lines,
            "not emitted",
        });
    }
}

fn inventoryScope(
    allocator: std.mem.Allocator,
    scope: anytype,
    states: *std.StringArrayHashMapUnmanaged(FileState),
) !void {
    if (scope.kind == .file) {
        const path = try allocator.dupe(u8, scope.display_path);
        errdefer allocator.free(path);
        try states.put(allocator, path, .{});
        return;
    }

    var directory = try std.fs.openDirAbsolute(scope.absolute_path, .{ .iterate = true });
    defer directory.close();

    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fs.path.join(allocator, &.{ scope.display_path, entry.path });
        errdefer allocator.free(path);
        try states.put(allocator, path, .{});
    }
}

fn pointDisplayPath(
    allocator: std.mem.Allocator,
    scopes: anytype,
    path: []const u8,
) !?[]u8 {
    for (scopes) |scope| switch (scope.kind) {
        .file => {
            if (std.mem.eql(u8, path, scope.absolute_path)) {
                return try allocator.dupe(u8, scope.display_path);
            }
        },
        .directory => {
            if (!std.mem.startsWith(u8, path, scope.absolute_path)) continue;
            if (path.len == scope.absolute_path.len) continue;
            if (path[scope.absolute_path.len] != '/') continue;
            return try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ scope.display_path, path[scope.absolute_path.len + 1 ..] },
            );
        },
    };
    return null;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const separators_normalized = try allocator.dupe(u8, path);
    defer allocator.free(separators_normalized);
    for (separators_normalized) |*character| {
        if (character.* == '\\') character.* = '/';
    }
    return std.fs.path.resolve(allocator, &.{separators_normalized});
}
