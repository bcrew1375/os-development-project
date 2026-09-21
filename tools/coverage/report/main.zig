const std = @import("std");
const model = @import("model.zig");
const summarize_report = @import("summarize.zig");
const table = @import("table.zig");

pub const CoverageCounts = model.CoverageCounts;
pub const FileCoverage = model.FileCoverage;
pub const Scope = model.Scope;
pub const SourcePoint = model.SourcePoint;
pub const Summary = model.Summary;

pub fn summarize(
    io: std.Io,
    allocator: std.mem.Allocator,
    common_root: []const u8,
    points: []const SourcePoint,
) !Summary {
    return summarize_report.common(io, allocator, common_root, points);
}

pub fn summarizeScopes(
    io: std.Io,
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    points: []const SourcePoint,
) !Summary {
    return summarize_report.scopes(io, allocator, scopes, points);
}

pub fn write(writer: *std.Io.Writer, summary: Summary) !void {
    try table.writeCommon(writer, summary);
}

pub fn writeTable(writer: *std.Io.Writer, summary: Summary) !void {
    try table.write(writer, summary);
}
