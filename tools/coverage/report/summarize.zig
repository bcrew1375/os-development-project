const std = @import("std");
const model = @import("model.zig");

const FileState = struct {
    display_path: []u8,
    lines: std.AutoHashMapUnmanaged(u32, bool) = .empty,

    fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
        allocator.free(self.display_path);
        self.lines.deinit(allocator);
        self.* = undefined;
    }
};

const NormalizedScope = struct {
    absolute_path: []u8,
    display_path: []const u8,
    kind: model.Scope.Kind,

    fn deinit(self: *NormalizedScope, allocator: std.mem.Allocator) void {
        allocator.free(self.absolute_path);
        self.* = undefined;
    }
};

const FileStates = std.StringArrayHashMapUnmanaged(FileState);

pub fn common(
    allocator: std.mem.Allocator,
    common_root: []const u8,
    points: []const model.SourcePoint,
) !model.Summary {
    return scopes(allocator, &.{.{
        .absolute_path = common_root,
        .display_path = "src/common",
        .kind = .directory,
    }}, points);
}

pub fn scopes(
    allocator: std.mem.Allocator,
    coverage_scopes: []const model.Scope,
    points: []const model.SourcePoint,
) !model.Summary {
    const normalized_scopes = try normalizeScopes(allocator, coverage_scopes);
    defer freeNormalizedScopes(allocator, normalized_scopes);

    var states: FileStates = .empty;
    defer deinitStates(allocator, &states);
    for (normalized_scopes) |scope| try inventoryScope(allocator, scope, &states);
    try aggregatePoints(allocator, &states, points);
    return createSummary(allocator, &states);
}

fn normalizeScopes(
    allocator: std.mem.Allocator,
    coverage_scopes: []const model.Scope,
) ![]NormalizedScope {
    const normalized = try allocator.alloc(NormalizedScope, coverage_scopes.len);
    errdefer allocator.free(normalized);
    var initialized: usize = 0;
    errdefer for (normalized[0..initialized]) |*scope| scope.deinit(allocator);

    for (coverage_scopes, normalized) |scope, *destination| {
        destination.* = .{
            .absolute_path = try normalizePath(allocator, scope.absolute_path),
            .display_path = scope.display_path,
            .kind = scope.kind,
        };
        initialized += 1;
    }
    return normalized;
}

fn freeNormalizedScopes(
    allocator: std.mem.Allocator,
    normalized_scopes: []NormalizedScope,
) void {
    for (normalized_scopes) |*scope| scope.deinit(allocator);
    allocator.free(normalized_scopes);
}

fn deinitStates(allocator: std.mem.Allocator, states: *FileStates) void {
    for (states.keys(), states.values()) |absolute_path, *state| {
        allocator.free(absolute_path);
        state.deinit(allocator);
    }
    states.deinit(allocator);
}

fn inventoryScope(
    allocator: std.mem.Allocator,
    scope: NormalizedScope,
    states: *FileStates,
) !void {
    if (scope.kind == .file) {
        try inventoryFileScope(allocator, scope, states);
        return;
    }

    var directory = try std.fs.openDirAbsolute(scope.absolute_path, .{ .iterate = true });
    defer directory.close();
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try inventoryDirectoryFile(allocator, scope, entry.path, states);
    }
}

fn inventoryFileScope(
    allocator: std.mem.Allocator,
    scope: NormalizedScope,
    states: *FileStates,
) !void {
    const absolute_path = try allocator.dupe(u8, scope.absolute_path);
    errdefer allocator.free(absolute_path);
    const display_path = try allocator.dupe(u8, scope.display_path);
    errdefer allocator.free(display_path);
    try addFile(allocator, states, absolute_path, display_path);
}

fn inventoryDirectoryFile(
    allocator: std.mem.Allocator,
    scope: NormalizedScope,
    relative_path: []const u8,
    states: *FileStates,
) !void {
    const absolute_path = try std.fs.path.resolve(
        allocator,
        &.{ scope.absolute_path, relative_path },
    );
    errdefer allocator.free(absolute_path);
    const display_path = try std.fs.path.join(
        allocator,
        &.{ scope.display_path, relative_path },
    );
    errdefer allocator.free(display_path);
    try addFile(allocator, states, absolute_path, display_path);
}

fn addFile(
    allocator: std.mem.Allocator,
    states: *FileStates,
    absolute_path: []u8,
    display_path: []u8,
) !void {
    const result = try states.getOrPut(allocator, absolute_path);
    if (result.found_existing) return error.DuplicateCoverageScope;
    result.value_ptr.* = .{ .display_path = display_path };
}

fn aggregatePoints(
    allocator: std.mem.Allocator,
    states: *FileStates,
    points: []const model.SourcePoint,
) !void {
    for (points) |point| {
        if (point.line == 0) continue;
        const absolute_path = try normalizePath(allocator, point.path);
        defer allocator.free(absolute_path);
        const state = states.getPtr(absolute_path) orelse continue;
        const line = try state.lines.getOrPut(allocator, point.line);
        if (!line.found_existing) line.value_ptr.* = false;
        line.value_ptr.* = line.value_ptr.* or point.covered;
    }
}

fn createSummary(allocator: std.mem.Allocator, states: *FileStates) !model.Summary {
    const files = try allocator.alloc(model.FileCoverage, states.count());
    errdefer allocator.free(files);
    var initialized: usize = 0;
    errdefer for (files[0..initialized]) |*file| file.deinit(allocator);

    for (states.values(), 0..) |*state, index| {
        files[index] = try createFileCoverage(allocator, state);
        initialized += 1;
    }
    std.mem.sort(model.FileCoverage, files, {}, lessThanPath);
    return .{ .files = files };
}

fn createFileCoverage(
    allocator: std.mem.Allocator,
    state: *const FileState,
) !model.FileCoverage {
    const path = try allocator.dupe(u8, state.display_path);
    errdefer allocator.free(path);

    var missing_count: usize = 0;
    var covered_iterator = state.lines.valueIterator();
    while (covered_iterator.next()) |covered| missing_count += @intFromBool(!covered.*);
    const missing_lines = try allocator.alloc(u32, missing_count);
    errdefer allocator.free(missing_lines);

    var missing_index: usize = 0;
    var line_iterator = state.lines.iterator();
    while (line_iterator.next()) |entry| {
        if (entry.value_ptr.*) continue;
        missing_lines[missing_index] = entry.key_ptr.*;
        missing_index += 1;
    }
    std.mem.sort(u32, missing_lines, {}, std.sort.asc(u32));
    return .{
        .path = path,
        .coverable_lines = state.lines.count(),
        .missing_lines = missing_lines,
    };
}

fn lessThanPath(_: void, left: model.FileCoverage, right: model.FileCoverage) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const separators_normalized = try allocator.dupe(u8, path);
    defer allocator.free(separators_normalized);
    for (separators_normalized) |*character| {
        if (character.* == '\\') character.* = '/';
    }
    return std.fs.path.resolve(allocator, &.{separators_normalized});
}
