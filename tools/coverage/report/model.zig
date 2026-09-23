const std = @import("std");

pub const SourcePoint = struct {
    path: []const u8,
    line: u32,
    covered: bool,
    coverable: bool = true,
};

pub const Scope = struct {
    pub const Kind = enum { file, directory };

    absolute_path: []const u8,
    display_path: []const u8,
    kind: Kind,
};

pub const CoverageCounts = struct {
    covered: usize,
    coverable: usize,

    pub fn percentage(self: CoverageCounts) ?f64 {
        if (self.coverable == 0) return null;
        std.debug.assert(self.covered <= self.coverable);
        return 100.0 * @as(f64, @floatFromInt(self.covered)) /
            @as(f64, @floatFromInt(self.coverable));
    }
};

pub const FileCoverage = struct {
    path: []const u8,
    emitted_lines: usize = 0,
    coverable_lines: usize,
    missing_lines: []const u32,

    pub fn hasEmittedCode(self: FileCoverage) bool {
        return self.emitted_lines != 0 or self.coverable_lines != 0;
    }

    pub fn deinit(self: *FileCoverage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.missing_lines);
        self.* = undefined;
    }

    pub fn counts(self: FileCoverage) CoverageCounts {
        std.debug.assert(self.missing_lines.len <= self.coverable_lines);
        return .{
            .covered = self.coverable_lines - self.missing_lines.len,
            .coverable = self.coverable_lines,
        };
    }
};

pub const Summary = struct {
    files: []FileCoverage,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }

    pub fn counts(self: Summary) CoverageCounts {
        var total: CoverageCounts = .{ .covered = 0, .coverable = 0 };
        for (self.files) |file| {
            const file_counts = file.counts();
            total.covered += file_counts.covered;
            total.coverable += file_counts.coverable;
        }
        return total;
    }
};
