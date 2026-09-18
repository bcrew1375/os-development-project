//! Physical frame allocator initialized from the architecture memory map.

const arch = @import("arch");

const builtin = @import("builtin");
const std = @import("std");

/// Size in bytes of one physical frame.
pub const FRAME_SIZE: usize = @as(usize, @intCast(arch.mmu.getPageSize()));
/// Maximum tracked frames; currently sized for 64 GiB with 4 KiB pages.
pub const MAX_FRAMES: usize = 2097152;

/// Errors produced by physical memory allocation operations.
pub const PmmError = error{
    OutOfMemory,
    InvalidSize,
    InvalidIndex,
    ReservedFree,
};

var kernelBaseStartFrame: usize = 0;
var kernelBaseEndFrame: usize = 0;

var totalFrames: usize = 0;
var totalSystemFrames: usize = 0;
var totalAvailableFrames: usize = 0;
var currentAvailableFrames: usize = 0;
var trackAllocationsAsReserved: bool = false;

const FrameInfo = extern struct {
    used: bool = undefined,
    reserved: bool = undefined,
};

var frameMap: []allowzero FrameInfo = undefined;

extern const _kernel_start: usize;
extern const _kernel_end: usize;

/// Initializes frame accounting from the architecture memory and reservation maps.
pub fn initialize() !void {
    if (builtin.is_test) {
        kernelBaseStartFrame = _kernel_start / FRAME_SIZE;
        kernelBaseEndFrame = _kernel_end / FRAME_SIZE;
    } else {
        kernelBaseStartFrame = @intFromPtr(&_kernel_start) / FRAME_SIZE;
        kernelBaseEndFrame = (@intFromPtr(&_kernel_end) + (FRAME_SIZE - 1)) / FRAME_SIZE;
    }

    totalFrames = 0;
    totalAvailableFrames = 0;
    currentAvailableFrames = 0;
    totalSystemFrames = 0;

    const memory_map = arch.mmu.getMemoryMap();

    totalFrames = @truncate(try std.math.divFloor(u64, arch.mmu.getMaxAvailableAddress(), FRAME_SIZE));

    const frameMapPtr: *allowzero anyopaque = try arch.early_allocator.allocate(totalFrames * @sizeOf(FrameInfo), FRAME_SIZE, arch.ReservedMapRegionType.PERSISTENT);
    const frame_map_virtual_address =
        @as(usize, @intCast(arch.mmu.getDirectMapVirtualAddress())) + @intFromPtr(frameMapPtr);
    frameMap = @as(
        [*]allowzero FrameInfo,
        @ptrFromInt(frame_map_virtual_address),
    )[0..totalFrames];

    for (memory_map.entries[0..memory_map.length]) |region| {
        const region_start_frame: usize = @truncate(try std.math.divCeil(u64, region.address, FRAME_SIZE));
        const region_end_frame: usize = @truncate(try std.math.divTrunc(u64, region.address + region.size, FRAME_SIZE));

        var used = true;
        var reserved = true;

        switch (region.region_type) {
            arch.MemoryMapRegionType.AVAILABLE => {
                used = false;
                reserved = false;

                totalAvailableFrames += region_end_frame - region_start_frame;
            },
            else => {
                used = true;
                reserved = true;
            },
        }

        for (region_start_frame..region_end_frame) |frame| {
            if (frame >= totalFrames) {
                break;
            }

            frameMap[frame].used = used;
            frameMap[frame].reserved = reserved;
        }
    }

    currentAvailableFrames = totalAvailableFrames;

    const reservedMap = arch.early_allocator.getReservedMap();

    for (reservedMap.entries[0..reservedMap.length]) |region| {
        const region_start_frame: usize = @truncate(try std.math.divFloor(u64, region.address, FRAME_SIZE));
        const region_total_frames: usize = @truncate((try std.math.divCeil(u64, region.address +| region.size, FRAME_SIZE)) - region_start_frame);

        try reserve(region_start_frame, region_total_frames);
    }
}

/// Allocates `needed_frames` contiguous frames and returns the physical address.
pub fn allocate(needed_frames: usize) !usize {
    if ((needed_frames < 1) or
        (needed_frames > totalAvailableFrames))
    {
        return PmmError.InvalidSize;
    }

    if (needed_frames > currentAvailableFrames) {
        return PmmError.OutOfMemory;
    }

    const start_frame = try get_start_frame(needed_frames);
    const end_frame: usize = start_frame + needed_frames;

    for (start_frame..end_frame) |frame| {
        frameMap[frame].used = true;
    }

    currentAvailableFrames -= needed_frames;

    if (trackAllocationsAsReserved) {
        totalSystemFrames +|= needed_frames;
    }

    return start_frame * FRAME_SIZE;
}

/// Marks a frame range as reserved and unavailable for allocation.
pub fn reserve(start_frame: usize, total_frames: usize) !void {
    const end_frame = start_frame + total_frames;

    if (end_frame > totalFrames) {
        return;
    }

    for (start_frame..start_frame + total_frames) |frame| {
        frameMap[frame].used = true;
        frameMap[frame].reserved = true;
    }

    totalSystemFrames +|= total_frames;
    currentAvailableFrames -|= total_frames;
}

/// Frees a non-reserved frame range.
pub fn free(start_frame: usize, total_frames: usize) !void {
    const end_frame: usize = start_frame +| total_frames;

    if (end_frame > totalFrames) {
        return PmmError.InvalidIndex;
    }

    if (total_frames > totalAvailableFrames) {
        return PmmError.InvalidSize;
    }

    for (start_frame..end_frame) |frame| {
        if (frameMap[frame].reserved == true) {
            return PmmError.ReservedFree;
        }

        frameMap[frame].used = false;
    }

    currentAvailableFrames += total_frames;
}

fn get_start_frame(needed_frames: usize) !usize {
    var frame_count: usize = 0;
    var start_frame: usize = 0;
    var is_first: bool = true;

    for (0..totalFrames) |frame| {
        if (frameMap[frame].used == true) {
            frame_count = 0;
            start_frame = 0;
            is_first = true;
            continue;
        }

        if (is_first) {
            is_first = false;
            start_frame = frame;
        }

        frame_count += 1;

        if (frame_count == needed_frames) {
            return start_frame;
        }
    }

    return PmmError.OutOfMemory;
}

fn markFrames(start_frame: usize, total_frames: usize, region_type: arch.MemoryMapRegionType) void {
    const end_frame: usize = start_frame + total_frames;

    for (start_frame..end_frame) |frame| {
        switch (region_type) {
            arch.MemoryMapRegionType.AVAILABLE => {
                frameMap[frame].used = false;
            },
            else => {
                frameMap[frame].reserved = true;
            },
        }
    }
}

/// Returns the total number of tracked frames.
pub fn getTotalFrames() usize {
    return totalFrames;
}

/// Returns the number of frames initially classified as available.
pub fn getTotalAvailableFrames() usize {
    return totalAvailableFrames;
}

/// Returns the number of frames reserved for kernel/system use.
pub fn getTotalSystemFrames() usize {
    return totalSystemFrames;
}

/// Returns the number of currently allocatable frames.
pub fn getCurrentAvailableFrames() usize {
    return currentAvailableFrames;
}

/// Returns initially available RAM in bytes.
pub fn getTotalAvailableRAM() u64 {
    return totalAvailableFrames * FRAME_SIZE;
}

/// Returns currently allocatable RAM in bytes.
pub fn getCurrentAvailableRAM() u64 {
    return currentAvailableFrames * FRAME_SIZE;
}

/// Returns RAM reserved for kernel/system use in bytes.
pub fn getTotalSystemReservedRAM() u64 {
    return totalSystemFrames * FRAME_SIZE;
}

/// Controls whether future allocations also count as system-reserved frames.
pub fn setTrackAllocationsAsReserved(track: bool) void {
    trackAllocationsAsReserved = track;
}
