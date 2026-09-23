//! Deterministic normalization of boot-time physical-memory ranges.

const std = @import("std");

pub const Range = struct {
    start: u64,
    end: u64,

    pub fn size(self: Range) u64 {
        return self.end - self.start;
    }

    pub fn toNative(self: Range) error{NativeWidthOverflow}!NativeRange {
        if (self.start > std.math.maxInt(usize) or self.end > std.math.maxInt(usize)) {
            return error.NativeWidthOverflow;
        }
        return .{
            .start = @intCast(self.start),
            .end = @intCast(self.end),
        };
    }
};

pub const NativeRange = struct {
    start: usize,
    end: usize,
};

pub const MemoryKind = enum {
    available,
    reserved,
    reclaimable,
    bad,
};

pub const RetainedReason = enum {
    memory_map_reserved,
    firmware_reclaimable,
    bad_memory,
    page_alignment,
    kernel_image,
    active_page_tables,
    boot_module,
    framebuffer_or_mmio,
    retained_bootloader_data,
    kernel_page_table_pool,
    physical_address_limit,
};

pub const MemoryMapInput = struct {
    start: u64,
    size: u64,
    kind: MemoryKind,
};

pub const Exclusion = struct {
    start: u64,
    size: u64,
    reason: RetainedReason,
};

pub const RetainedRange = struct {
    range: Range,
    reason: RetainedReason,
};

pub const Result = struct {
    allocatable_count: usize,
    retained_count: usize,
};

pub const Error = error{
    EmptyRange,
    RangeOverflow,
    InvalidPageSize,
    OverlappingMemoryMap,
    OutputTooSmall,
    TooManyInputs,
};

const MAX_INPUTS = 512;

pub fn normalize(
    memory_map: []const MemoryMapInput,
    exclusions: []const Exclusion,
    page_size: u64,
    allocatable_output: []Range,
    retained_output: []RetainedRange,
) Error!Result {
    if (page_size == 0 or !std.math.isPowerOfTwo(page_size)) return Error.InvalidPageSize;
    if (memory_map.len > MAX_INPUTS or exclusions.len > MAX_INPUTS) return Error.TooManyInputs;

    var sorted_memory: [MAX_INPUTS]MemoryMapInput = undefined;
    @memcpy(sorted_memory[0..memory_map.len], memory_map);
    insertionSortMemory(sorted_memory[0..memory_map.len]);
    try validateMemoryMap(sorted_memory[0..memory_map.len]);

    var sorted_exclusions: [MAX_INPUTS]Exclusion = undefined;
    @memcpy(sorted_exclusions[0..exclusions.len], exclusions);
    insertionSortExclusions(sorted_exclusions[0..exclusions.len]);
    for (sorted_exclusions[0..exclusions.len]) |exclusion| {
        _ = try checkedRange(exclusion.start, exclusion.size);
    }

    var result = Result{ .allocatable_count = 0, .retained_count = 0 };
    for (sorted_memory[0..memory_map.len]) |entry| {
        const range = try checkedRange(entry.start, entry.size);
        if (entry.kind != .available) {
            try appendRetained(retained_output, &result.retained_count, .{
                .range = range,
                .reason = retainedReason(entry.kind),
            });
            continue;
        }

        try normalizeAvailable(
            range,
            sorted_exclusions[0..exclusions.len],
            page_size,
            allocatable_output,
            retained_output,
            &result,
        );
    }
    return result;
}

fn normalizeAvailable(
    range: Range,
    exclusions: []const Exclusion,
    page_size: u64,
    allocatable_output: []Range,
    retained_output: []RetainedRange,
    result: *Result,
) Error!void {
    const aligned_start = try alignForward(range.start, page_size);
    const aligned_end = std.mem.alignBackward(u64, range.end, page_size);
    if (range.start < @min(aligned_start, range.end)) {
        try appendRetained(retained_output, &result.retained_count, .{
            .range = .{ .start = range.start, .end = @min(aligned_start, range.end) },
            .reason = .page_alignment,
        });
    }
    if (aligned_end < range.end and aligned_end >= range.start) {
        try appendRetained(retained_output, &result.retained_count, .{
            .range = .{ .start = @max(aligned_end, range.start), .end = range.end },
            .reason = .page_alignment,
        });
    }
    if (aligned_start >= aligned_end) return;

    var cursor = aligned_start;
    for (exclusions) |exclusion| {
        const raw_exclusion = try checkedRange(exclusion.start, exclusion.size);
        const excluded = Range{
            .start = std.mem.alignBackward(u64, raw_exclusion.start, page_size),
            .end = try alignForward(raw_exclusion.end, page_size),
        };
        const overlap = intersection(.{ .start = aligned_start, .end = aligned_end }, excluded) orelse continue;
        if (cursor < overlap.start) {
            try appendRange(allocatable_output, &result.allocatable_count, .{
                .start = cursor,
                .end = overlap.start,
            });
        }
        if (cursor < overlap.end) {
            try appendRetained(retained_output, &result.retained_count, .{
                .range = .{ .start = @max(cursor, overlap.start), .end = overlap.end },
                .reason = exclusion.reason,
            });
            cursor = overlap.end;
        }
    }
    if (cursor < aligned_end) {
        try appendRange(allocatable_output, &result.allocatable_count, .{
            .start = cursor,
            .end = aligned_end,
        });
    }
}

fn validateMemoryMap(memory_map: []const MemoryMapInput) Error!void {
    var previous_end: u64 = 0;
    for (memory_map, 0..) |entry, index| {
        const range = try checkedRange(entry.start, entry.size);
        if (index != 0 and range.start < previous_end) return Error.OverlappingMemoryMap;
        previous_end = range.end;
    }
}

fn checkedRange(start: u64, size: u64) Error!Range {
    if (size == 0) return Error.EmptyRange;
    const end = std.math.add(u64, start, size) catch return Error.RangeOverflow;
    return .{ .start = start, .end = end };
}

fn alignForward(value: u64, alignment: u64) Error!u64 {
    const mask = alignment - 1;
    const adjusted = std.math.add(u64, value, mask) catch return Error.RangeOverflow;
    return adjusted & ~mask;
}

fn intersection(left: Range, right: Range) ?Range {
    const start = @max(left.start, right.start);
    const end = @min(left.end, right.end);
    if (start >= end) return null;
    return .{ .start = start, .end = end };
}

fn appendRange(output: []Range, count: *usize, range: Range) Error!void {
    if (range.start >= range.end) return;
    if (count.* > 0 and output[count.* - 1].end == range.start) {
        output[count.* - 1].end = range.end;
        return;
    }
    if (count.* >= output.len) return Error.OutputTooSmall;
    output[count.*] = range;
    count.* += 1;
}

fn appendRetained(output: []RetainedRange, count: *usize, retained: RetainedRange) Error!void {
    if (retained.range.start >= retained.range.end) return;
    if (count.* > 0) {
        const previous = &output[count.* - 1];
        if (previous.reason == retained.reason and previous.range.end == retained.range.start) {
            previous.range.end = retained.range.end;
            return;
        }
    }
    if (count.* >= output.len) return Error.OutputTooSmall;
    output[count.*] = retained;
    count.* += 1;
}

fn retainedReason(kind: MemoryKind) RetainedReason {
    return switch (kind) {
        .available => unreachable,
        .reserved => .memory_map_reserved,
        .reclaimable => .firmware_reclaimable,
        .bad => .bad_memory,
    };
}

fn insertionSortMemory(entries: []MemoryMapInput) void {
    if (entries.len < 2) return;
    for (1..entries.len) |index| {
        const value = entries[index];
        var insertion_index = index;
        while (insertion_index > 0 and lessMemory(value, entries[insertion_index - 1])) {
            entries[insertion_index] = entries[insertion_index - 1];
            insertion_index -= 1;
        }
        entries[insertion_index] = value;
    }
}

fn insertionSortExclusions(entries: []Exclusion) void {
    if (entries.len < 2) return;
    for (1..entries.len) |index| {
        const value = entries[index];
        var insertion_index = index;
        while (insertion_index > 0 and lessExclusion(value, entries[insertion_index - 1])) {
            entries[insertion_index] = entries[insertion_index - 1];
            insertion_index -= 1;
        }
        entries[insertion_index] = value;
    }
}

fn lessMemory(left: MemoryMapInput, right: MemoryMapInput) bool {
    if (left.start != right.start) return left.start < right.start;
    if (left.size != right.size) return left.size < right.size;
    return @intFromEnum(left.kind) < @intFromEnum(right.kind);
}

fn lessExclusion(left: Exclusion, right: Exclusion) bool {
    if (left.start != right.start) return left.start < right.start;
    if (left.size != right.size) return left.size < right.size;
    return @intFromEnum(left.reason) < @intFromEnum(right.reason);
}
