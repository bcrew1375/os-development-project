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

const NormalizedScope = struct {
    absolute_path: []u8,
    display_path: []const u8,
    kind: Scope.Kind,
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
    const path_width = 42;
    const table_width = path_width + 1 + 8 + 1 + 9 + 1 + 15;

    try writePathColumn(writer, "File", path_width);
    try writer.print(" {s:>8} {s:>9} {s:>15}\n", .{
        "Covered", "Coverable", "Coverage",
    });

    for (summary.files) |file| {
        try writePathColumn(writer, file.path, path_width);
        if (file.percentage()) |percentage| {
            var percentage_buffer: [32]u8 = undefined;
            const percentage_text = try std.fmt.bufPrint(
                &percentage_buffer,
                "{d:.2}%",
                .{percentage},
            );
            try writer.print(" {d:>8} {d:>9} {s:>15}\n", .{
                file.covered_lines,
                file.coverable_lines,
                percentage_text,
            });
        } else {
            try writer.print(" {d:>8} {d:>9} {s:>15}\n", .{
                file.covered_lines,
                file.coverable_lines,
                "no emitted code",
            });
        }
    }

    try writer.splatByteAll('-', table_width);
    try writer.writeByte('\n');
    try writePathColumn(writer, "TOTAL", path_width);
    if (summary.percentage()) |percentage| {
        var percentage_buffer: [32]u8 = undefined;
        const percentage_text = try std.fmt.bufPrint(
            &percentage_buffer,
            "{d:.2}%",
            .{percentage},
        );
        try writer.print(" {d:>8} {d:>9} {s:>15}\n", .{
            summary.covered_lines,
            summary.coverable_lines,
            percentage_text,
        });
    } else {
        try writer.print(" {d:>8} {d:>9} {s:>15}\n", .{
            summary.covered_lines,
            summary.coverable_lines,
            "no emitted code",
        });
    }
}

fn writePathColumn(writer: *std.Io.Writer, path: []const u8, width: usize) !void {
    const ellipsis = "...";
    if (path.len <= width) {
        try writer.writeAll(path);
        try writer.splatByteAll(' ', width - path.len);
        return;
    }

    const remaining_width = width - ellipsis.len;
    const prefix_length = remaining_width / 2;
    const suffix_length = remaining_width - prefix_length;
    try writer.writeAll(path[0..prefix_length]);
    try writer.writeAll(ellipsis);
    try writer.writeAll(path[path.len - suffix_length ..]);
}

fn inventoryScope(
    allocator: std.mem.Allocator,
    scope: NormalizedScope,
    states: *std.StringArrayHashMapUnmanaged(FileState),
) !void {
    if (scope.kind == .file) {
        const path = try allocator.dupe(u8, scope.display_path);
        try addInventoryFile(allocator, states, path);
        return;
    }

    var directory = try std.fs.openDirAbsolute(scope.absolute_path, .{ .iterate = true });
    defer directory.close();

    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fs.path.join(allocator, &.{ scope.display_path, entry.path });
        try addInventoryFile(allocator, states, path);
    }
}

fn addInventoryFile(
    allocator: std.mem.Allocator,
    states: *std.StringArrayHashMapUnmanaged(FileState),
    path: []u8,
) !void {
    errdefer allocator.free(path);
    const result = try states.getOrPut(allocator, path);
    if (result.found_existing) return error.DuplicateCoverageScope;
    result.value_ptr.* = .{};
}

fn pointDisplayPath(
    allocator: std.mem.Allocator,
    scopes: []const NormalizedScope,
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
