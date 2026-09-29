const builtin = @import("builtin");
const memory_management = @import("memory_management");
const shared = @import("shared");
const std = @import("std");

const elf = shared.executable.elf;

pub const PlannedSegment = struct {
    source: elf.LoadableSegment,
    virtual_start: usize,
    mapping_size: usize,
    permissions: u32,
};

pub fn LoadPlan(comptime max_load_segments: usize) type {
    return struct {
        entry_point: usize,
        segments: [max_load_segments]PlannedSegment = undefined,
        segment_count: usize = 0,
    };
}

pub fn plan(
    image: []const u8,
    comptime page_size: usize,
    comptime max_load_segments: usize,
    comptime stack_start: usize,
    comptime stack_top: usize,
) !LoadPlan(max_load_segments) {
    const parsed = try elf.parseLoadableImage(image, page_size);
    const expected_class: elf.ElfClass = switch (builtin.cpu.arch) {
        .x86 => .elf32,
        .x86_64 => .elf64,
        else => @compileError("unsupported child ELF architecture"),
    };
    if (parsed.class != expected_class) return error.WrongElfClass;
    if (parsed.segment_count > max_load_segments) return error.TooManyLoadSegments;
    const entry_point = std.math.cast(usize, parsed.entry_point) orelse
        return error.AddressOutOfRange;

    var result = LoadPlan(max_load_segments){ .entry_point = entry_point };
    for (0..parsed.segment_count) |index| {
        const segment = try elf.getLoadableSegment(image, index);
        const virtual_address = std.math.cast(usize, segment.virtual_address) orelse
            return error.AddressOutOfRange;
        const memory_size = std.math.cast(usize, segment.memory_size) orelse
            return error.AddressOutOfRange;
        const virtual_end = std.math.add(usize, virtual_address, memory_size) catch
            return error.SegmentRangeOverflow;
        const virtual_start = std.mem.alignBackward(usize, virtual_address, page_size);
        const mapping_end = std.mem.alignForward(usize, virtual_end, page_size);
        if (mapping_end <= virtual_start) return error.SegmentRangeOverflow;
        if (rangesOverlap(virtual_start, mapping_end, stack_start, stack_top)) {
            return error.SegmentOverlapsStack;
        }
        const permissions = permissionFlags(segment.permissions);
        if (permissions == 0) return error.EmptySegmentPermissions;
        for (result.segments[0..result.segment_count]) |existing| {
            if (rangesOverlap(
                virtual_start,
                mapping_end,
                existing.virtual_start,
                existing.virtual_start + existing.mapping_size,
            )) return error.PageAlignedSegmentOverlap;
        }
        result.segments[result.segment_count] = .{
            .source = segment,
            .virtual_start = virtual_start,
            .mapping_size = mapping_end - virtual_start,
            .permissions = permissions,
        };
        result.segment_count += 1;
    }

    var entry_is_executable = false;
    for (result.segments[0..result.segment_count]) |segment| {
        const segment_end = segment.source.virtual_address + segment.source.memory_size;
        if (parsed.entry_point >= segment.source.virtual_address and
            parsed.entry_point < segment_end and segment.source.permissions.executable)
        {
            entry_is_executable = true;
        }
    }
    if (!entry_is_executable) return error.EntryPointNotExecutable;
    return result;
}

fn permissionFlags(permissions: elf.SegmentPermissions) u32 {
    var flags: u32 = 0;
    if (permissions.readable) flags |= memory_management.operations.MAP_READ;
    if (permissions.writeable) flags |= memory_management.operations.MAP_WRITE;
    if (permissions.executable) flags |= memory_management.operations.MAP_EXECUTE;
    return flags;
}

fn rangesOverlap(first_start: usize, first_end: usize, second_start: usize, second_end: usize) bool {
    return first_start < second_end and second_start < first_end;
}
