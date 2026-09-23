const std = @import("std");
const model = @import("model.zig");

const Layout = struct {
    const covered_width = 7;
    const coverable_width = 9;
    const coverage_width = 17;
    const missing_width = 23;

    path_width: usize,

    fn init(summary: model.Summary) Layout {
        var path_width: usize = @max("File".len, "TOTAL".len);
        for (summary.files) |file| path_width = @max(path_width, file.path.len);
        return .{ .path_width = path_width };
    }

    fn missingOffset(self: Layout) usize {
        return self.path_width + covered_width + coverable_width + coverage_width + 4;
    }

    fn tableWidth(self: Layout) usize {
        return self.missingOffset() + missing_width;
    }
};

const LineRange = struct {
    first: u32,
    last: u32,

    fn formattedLength(self: LineRange) usize {
        return decimalLength(self.first) + if (self.first == self.last)
            0
        else
            1 + decimalLength(self.last);
    }

    fn write(self: LineRange, writer: *std.Io.Writer) !void {
        if (self.first == self.last) {
            try writer.print("{d}", .{self.first});
        } else {
            try writer.print("{d}-{d}", .{ self.first, self.last });
        }
    }
};

const LineRangeIterator = struct {
    lines: []const u32,
    index: usize = 0,

    fn next(self: *LineRangeIterator) ?LineRange {
        if (self.index == self.lines.len) return null;
        const first = self.lines[self.index];
        var last = first;
        self.index += 1;
        while (self.index < self.lines.len and
            last != std.math.maxInt(u32) and
            self.lines[self.index] == last + 1)
        {
            last = self.lines[self.index];
            self.index += 1;
        }
        return .{ .first = first, .last = last };
    }
};

pub fn writeCommon(writer: *std.Io.Writer, summary: model.Summary) !void {
    try writer.writeAll("Common code coverage\n\n");
    try write(writer, summary);
}

pub fn write(writer: *std.Io.Writer, summary: model.Summary) !void {
    const layout = Layout.init(summary);
    try writeHeader(writer, layout);
    for (summary.files) |file| try writeFile(writer, layout, file);
    try writer.splatByteAll('-', layout.tableWidth());
    try writer.writeByte('\n');
    try writeSummary(writer, layout, summary);
}

fn writeHeader(writer: *std.Io.Writer, layout: Layout) !void {
    try writePath(writer, layout, "File");
    try writer.print(" {s:>7} {s:>9} {s:>17} {s:<23}\n", .{
        "Covered", "Coverable", "Coverage", "Missing",
    });
}

fn writeFile(writer: *std.Io.Writer, layout: Layout, file: model.FileCoverage) !void {
    try writePath(writer, layout, file.path);
    try writeCounts(writer, file.counts(), file.hasEmittedCode());
    try writeMissingLines(writer, layout, file.missing_lines);
}

fn writeSummary(writer: *std.Io.Writer, layout: Layout, summary: model.Summary) !void {
    try writePath(writer, layout, "TOTAL");
    var has_emitted_code = false;
    for (summary.files) |file| has_emitted_code = has_emitted_code or file.hasEmittedCode();
    try writeCounts(writer, summary.counts(), has_emitted_code);
    try writer.splatByteAll(' ', Layout.missing_width);
    try writer.writeByte('\n');
}

fn writeCounts(
    writer: *std.Io.Writer,
    counts: model.CoverageCounts,
    has_emitted_code: bool,
) !void {
    var percentage_buffer: [32]u8 = undefined;
    const coverage = if (counts.percentage()) |percentage|
        try std.fmt.bufPrint(&percentage_buffer, "{d:.2}%", .{percentage})
    else if (has_emitted_code)
        "no coverable code"
    else
        "no emitted code";
    try writer.print(" {d:>7} {d:>9} {s:>17} ", .{
        counts.covered,
        counts.coverable,
        coverage,
    });
}

fn writeMissingLines(
    writer: *std.Io.Writer,
    layout: Layout,
    missing_lines: []const u32,
) !void {
    var ranges: LineRangeIterator = .{ .lines = missing_lines };
    var written: usize = 0;
    while (ranges.next()) |range| {
        const separator_length: usize = if (written == 0) 0 else 2;
        if (written != 0 and
            written + separator_length + range.formattedLength() > Layout.missing_width)
        {
            try finishMissingColumn(writer, written);
            try writer.splatByteAll(' ', layout.missingOffset());
            written = 0;
        }
        if (written != 0) {
            try writer.writeAll(", ");
            written += 2;
        }
        try range.write(writer);
        written += range.formattedLength();
    }
    try finishMissingColumn(writer, written);
}

fn finishMissingColumn(writer: *std.Io.Writer, written: usize) !void {
    try writer.splatByteAll(' ', Layout.missing_width - written);
    try writer.writeByte('\n');
}

fn writePath(writer: *std.Io.Writer, layout: Layout, path: []const u8) !void {
    try writer.writeAll(path);
    try writer.splatByteAll(' ', layout.path_width - path.len);
}

fn decimalLength(value: u32) usize {
    var remaining = value;
    var length: usize = 1;
    while (remaining >= 10) : (remaining /= 10) length += 1;
    return length;
}
