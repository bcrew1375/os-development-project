//! Bounded kernel-owned storage for runtime page-table frames.

const arch = @import("arch");
const builtin = @import("builtin");

/// The kernel retains 2 MiB for runtime page tables on 4 KiB-page targets.
pub const FRAME_CAPACITY: usize = 512;
/// One address space may own at most 64 frames, including its root frame.
pub const MAX_FRAMES_PER_ADDRESS_SPACE: usize = 64;

const FrameState = struct {
    owner_root: usize = 0,
    allocated: bool = false,
};

var physicalBase: usize = 0;
var initialized: bool = false;
var frames: [FRAME_CAPACITY]FrameState = [_]FrameState{.{}} ** FRAME_CAPACITY;

pub const Error = error{
    PoolExhausted,
    AddressSpaceLimitReached,
    InvalidFrame,
} || arch.EarlyAllocError;

/// Reserves the complete pool as one early-allocation range.
pub fn initialize() Error!void {
    if (initialized) return;

    const page_size = arch.mmu.getPageSize();
    physicalBase = if (builtin.is_test)
        page_size
    else
        @intFromPtr(try arch.early_allocator.allocate(
            FRAME_CAPACITY * page_size,
            page_size,
            .PAGE_TABLE_POOL,
        ));
    frames = [_]FrameState{.{}} ** FRAME_CAPACITY;
    initialized = true;
}

/// Allocates a root frame and assigns ownership to the root's physical address.
pub fn allocateRootFrame() Error!usize {
    try initialize();
    const frame_index = findFreeFrame() orelse return Error.PoolExhausted;
    const physical_address = framePhysicalAddress(frame_index);
    frames[frame_index] = .{
        .owner_root = physical_address,
        .allocated = true,
    };
    return physical_address;
}

/// Allocates a lower-level table frame owned by `root`.
pub fn allocateFrame(root: arch.AddressSpaceRoot) Error!usize {
    try initialize();
    if (ownedFrameCount(root) >= MAX_FRAMES_PER_ADDRESS_SPACE) {
        return Error.AddressSpaceLimitReached;
    }

    const frame_index = findFreeFrame() orelse return Error.PoolExhausted;
    frames[frame_index] = .{
        .owner_root = root.value,
        .allocated = true,
    };
    return framePhysicalAddress(frame_index);
}

/// Releases one frame after a transactional table-installation rollback.
pub fn freeFrame(root: arch.AddressSpaceRoot, physical_address: usize) Error!void {
    const frame_index = frameIndex(physical_address) orelse return Error.InvalidFrame;
    const state = &frames[frame_index];
    if (!state.allocated or state.owner_root != root.value) return Error.InvalidFrame;
    state.* = .{};
}

/// Releases the root and every lower-level frame owned by it.
pub fn freeAddressSpace(root: arch.AddressSpaceRoot) void {
    if (!initialized) return;
    for (&frames) |*state| {
        if (state.allocated and state.owner_root == root.value) state.* = .{};
    }
}

pub fn availableFrameCount() usize {
    if (!initialized) return FRAME_CAPACITY;
    var count: usize = 0;
    for (frames) |state| {
        if (!state.allocated) count += 1;
    }
    return count;
}

pub fn ownedFrameCount(root: arch.AddressSpaceRoot) usize {
    if (!initialized) return 0;
    var count: usize = 0;
    for (frames) |state| {
        if (state.allocated and state.owner_root == root.value) count += 1;
    }
    return count;
}

pub fn resetForTest() void {
    physicalBase = 0;
    initialized = false;
    frames = [_]FrameState{.{}} ** FRAME_CAPACITY;
}

fn findFreeFrame() ?usize {
    for (frames, 0..) |state, index| {
        if (!state.allocated) return index;
    }
    return null;
}

fn framePhysicalAddress(index: usize) usize {
    return physicalBase + index * arch.mmu.getPageSize();
}

fn frameIndex(physical_address: usize) ?usize {
    if (!initialized or physical_address < physicalBase) return null;
    const offset = physical_address - physicalBase;
    const page_size = arch.mmu.getPageSize();
    if (offset % page_size != 0) return null;
    const index = offset / page_size;
    if (index >= frames.len) return null;
    return index;
}
