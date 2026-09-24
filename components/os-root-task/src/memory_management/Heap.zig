//! Boundary-tag allocator for one root-task heap extent.

const std = @import("std");

const Self = @This();

const HEADER_MAGIC: u32 = 0x4845_4150;
const FOOTER_MAGIC: u32 = 0x464F_4F54;
const DEFAULT_ALIGNMENT: usize = @alignOf(usize);
const ALLOCATION_TAG_SIZE: usize = @sizeOf(usize);

pub const Error = error{
    EmptyRegion,
    RegionOverflow,
    RegionTooSmall,
    InvalidRegionAlignment,
    EmptyAllocation,
    InvalidAlignment,
    AllocationOverflow,
    OutOfMemory,
    InvalidAllocation,
    DuplicateFree,
};

pub const Statistics = struct {
    region_bytes: usize,
    allocated_payload_bytes: usize,
    allocation_count: usize,
    completely_free: bool,
};

const BlockHeader = struct {
    magic: u32 = HEADER_MAGIC,
    size: usize,
    requested_size: usize,
    payload_offset: usize,
    free: bool,
};

const BlockFooter = struct {
    magic: u32 = FOOTER_MAGIC,
    size: usize,
};

const FreeBlock = struct {
    next: ?*FreeBlock,
};

const minimum_block_size = alignForwardUnchecked(
    @sizeOf(BlockHeader) + @sizeOf(FreeBlock) + @sizeOf(BlockFooter),
    DEFAULT_ALIGNMENT,
);

const AllocationLayout = struct {
    user_address: usize,
    payload_offset: usize,
    block_size: usize,
};

start_address: usize,
end_address: usize,
region_size: usize,
free_list: ?*FreeBlock,
allocated_payload_bytes: usize = 0,
allocation_count: usize = 0,

pub fn initialize(start_address: usize, size_in_bytes: usize) Error!Self {
    if (size_in_bytes == 0) return Error.EmptyRegion;
    if (start_address % @alignOf(BlockHeader) != 0) return Error.InvalidRegionAlignment;

    const end_address = std.math.add(usize, start_address, size_in_bytes) catch
        return Error.RegionOverflow;
    const usable_size = alignBackward(size_in_bytes, DEFAULT_ALIGNMENT);
    if (usable_size < minimum_block_size) return Error.RegionTooSmall;

    var self = Self{
        .start_address = start_address,
        .end_address = end_address,
        .region_size = usable_size,
        .free_list = null,
    };
    const header = initializeBlock(start_address, usable_size, true, 0, @sizeOf(BlockHeader));
    freeNodeFromHeader(header).next = null;
    self.free_list = freeNodeFromHeader(header);
    return self;
}

pub fn requiredRegionSize(size_in_bytes: usize, alignment: usize) Error!usize {
    try validateAllocationRequest(size_in_bytes, alignment);
    const actual_alignment = @max(alignment, DEFAULT_ALIGNMENT);
    const prefix = std.math.add(
        usize,
        @sizeOf(BlockHeader) + ALLOCATION_TAG_SIZE,
        actual_alignment - 1,
    ) catch return Error.AllocationOverflow;
    const with_payload = std.math.add(usize, prefix, size_in_bytes) catch
        return Error.AllocationOverflow;
    const with_footer = std.math.add(usize, with_payload, @sizeOf(BlockFooter)) catch
        return Error.AllocationOverflow;
    return alignForward(with_footer, DEFAULT_ALIGNMENT);
}

pub fn allocate(self: *Self, size_in_bytes: usize, alignment: usize) Error![]u8 {
    try validateAllocationRequest(size_in_bytes, alignment);
    const actual_alignment = @max(alignment, DEFAULT_ALIGNMENT);

    var previous: ?*FreeBlock = null;
    var current = self.free_list;
    while (current) |free_node| {
        const header = headerFromFreeNode(free_node);
        if (!self.validFreeHeader(header)) return Error.InvalidAllocation;

        const layout = computeAllocationLayout(
            @intFromPtr(header),
            size_in_bytes,
            actual_alignment,
        ) catch {
            previous = free_node;
            current = free_node.next;
            continue;
        };
        if (layout.block_size > header.size) {
            previous = free_node;
            current = free_node.next;
            continue;
        }

        const original_size = header.size;
        self.unlinkFreeNode(previous, free_node);
        const allocation_size = chooseAllocationBlockSize(original_size, layout.block_size);
        const allocated_header = initializeBlock(
            @intFromPtr(header),
            allocation_size,
            false,
            size_in_bytes,
            layout.payload_offset,
        );
        writeAllocationTag(allocated_header);

        const trailing_size = original_size - allocation_size;
        if (trailing_size >= minimum_block_size) {
            const trailing_header = initializeBlock(
                @intFromPtr(allocated_header) + allocation_size,
                trailing_size,
                true,
                0,
                @sizeOf(BlockHeader),
            );
            self.insertIntoFreeList(trailing_header);
        }

        self.allocated_payload_bytes = std.math.add(
            usize,
            self.allocated_payload_bytes,
            size_in_bytes,
        ) catch unreachable;
        self.allocation_count += 1;
        return @as([*]u8, @ptrFromInt(layout.user_address))[0..size_in_bytes];
    }
    return Error.OutOfMemory;
}

pub fn free(self: *Self, bytes: []u8) Error!void {
    if (bytes.len == 0) return Error.EmptyAllocation;
    const header = try self.headerFromAllocation(bytes);
    if (header.free) return Error.DuplicateFree;
    if (header.requested_size != bytes.len) return Error.InvalidAllocation;

    self.allocated_payload_bytes -= header.requested_size;
    self.allocation_count -= 1;
    header.free = true;
    header.requested_size = 0;
    header.payload_offset = @sizeOf(BlockHeader);

    var merged = self.coalesceWithNext(header);
    merged = self.coalesceWithPrevious(merged);
    self.insertIntoFreeList(merged);
}

pub fn owns(self: *const Self, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const start = @intFromPtr(bytes.ptr);
    const end = std.math.add(usize, start, bytes.len) catch return false;
    return start >= self.start_address and end <= self.end_address;
}

pub fn isCompletelyFree(self: *const Self) bool {
    if (self.allocation_count != 0 or self.allocated_payload_bytes != 0) return false;
    const node = self.free_list orelse return false;
    if (node.next != null) return false;
    const header = headerFromFreeNode(node);
    return self.validFreeHeader(header) and
        @intFromPtr(header) == self.start_address and
        header.size == self.region_size;
}

pub fn statistics(self: *const Self) Statistics {
    return .{
        .region_bytes = self.region_size,
        .allocated_payload_bytes = self.allocated_payload_bytes,
        .allocation_count = self.allocation_count,
        .completely_free = self.isCompletelyFree(),
    };
}

fn validateAllocationRequest(size_in_bytes: usize, alignment: usize) Error!void {
    if (size_in_bytes == 0) return Error.EmptyAllocation;
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
        return Error.InvalidAlignment;
    }
}

fn computeAllocationLayout(
    block_address: usize,
    size_in_bytes: usize,
    alignment: usize,
) Error!AllocationLayout {
    const tag_base = std.math.add(
        usize,
        block_address,
        @sizeOf(BlockHeader) + ALLOCATION_TAG_SIZE,
    ) catch return Error.AllocationOverflow;
    const user_address = try alignForward(tag_base, alignment);
    const payload_offset = user_address - block_address;
    const payload_end = std.math.add(usize, payload_offset, size_in_bytes) catch
        return Error.AllocationOverflow;
    const block_end = std.math.add(usize, payload_end, @sizeOf(BlockFooter)) catch
        return Error.AllocationOverflow;
    return .{
        .user_address = user_address,
        .payload_offset = payload_offset,
        .block_size = try alignForward(block_end, DEFAULT_ALIGNMENT),
    };
}

fn headerFromAllocation(self: *const Self, bytes: []u8) Error!*BlockHeader {
    const address = @intFromPtr(bytes.ptr);
    if (address < self.start_address + ALLOCATION_TAG_SIZE or address >= self.end_address) {
        return Error.InvalidAllocation;
    }
    if (self.addressInFreeBlock(address)) return Error.DuplicateFree;
    const tag_address = address - ALLOCATION_TAG_SIZE;
    const header_address = @as(*const usize, @ptrFromInt(tag_address)).*;
    if (header_address < self.start_address or header_address >= self.end_address) {
        return Error.InvalidAllocation;
    }
    const header: *BlockHeader = @ptrFromInt(header_address);
    if (header.magic != HEADER_MAGIC) return Error.InvalidAllocation;
    if (header_address + header.payload_offset != address) return Error.InvalidAllocation;
    if (header.free) return Error.DuplicateFree;
    if (!self.validHeader(header)) return Error.InvalidAllocation;
    return header;
}

fn addressInFreeBlock(self: *const Self, address: usize) bool {
    var current = self.free_list;
    while (current) |node| {
        const header = headerFromFreeNode(node);
        const block_start = @intFromPtr(header);
        const block_end = block_start + header.size;
        if (address > block_start and address < block_end) return true;
        current = node.next;
    }
    return false;
}

fn validHeader(self: *const Self, header: *const BlockHeader) bool {
    const address = @intFromPtr(header);
    if (address < self.start_address or address > self.end_address - @sizeOf(BlockHeader)) {
        return false;
    }
    if (header.magic != HEADER_MAGIC or header.size < minimum_block_size) return false;
    const block_end = std.math.add(usize, address, header.size) catch return false;
    if (block_end > self.end_address) return false;
    const footer = footerFromHeader(header);
    return footer.magic == FOOTER_MAGIC and footer.size == header.size;
}

fn validFreeHeader(self: *const Self, header: *const BlockHeader) bool {
    return self.validHeader(header) and header.free;
}

fn coalesceWithNext(self: *Self, header: *BlockHeader) *BlockHeader {
    const next_address = @intFromPtr(header) + header.size;
    if (next_address >= self.start_address + self.region_size) return header;
    const next_header: *BlockHeader = @ptrFromInt(next_address);
    if (!self.validHeader(next_header) or !next_header.free) return header;
    self.removeFreeNode(freeNodeFromHeader(next_header));
    header.size += next_header.size;
    footerFromHeader(header).* = .{ .size = header.size };
    return header;
}

fn coalesceWithPrevious(self: *Self, header: *BlockHeader) *BlockHeader {
    if (@intFromPtr(header) == self.start_address) return header;
    const previous_footer_address = @intFromPtr(header) - @sizeOf(BlockFooter);
    const previous_footer: *const BlockFooter = @ptrFromInt(previous_footer_address);
    if (previous_footer.magic != FOOTER_MAGIC) return header;
    if (previous_footer.size > @intFromPtr(header) - self.start_address) return header;
    const previous_address = @intFromPtr(header) - previous_footer.size;
    const previous_header: *BlockHeader = @ptrFromInt(previous_address);
    if (!self.validHeader(previous_header) or !previous_header.free) return header;
    self.removeFreeNode(freeNodeFromHeader(previous_header));
    previous_header.size += header.size;
    footerFromHeader(previous_header).* = .{ .size = previous_header.size };
    return previous_header;
}

fn insertIntoFreeList(self: *Self, header: *BlockHeader) void {
    const node = freeNodeFromHeader(header);
    node.next = null;
    var previous: ?*FreeBlock = null;
    var current = self.free_list;
    while (current) |entry| {
        if (@intFromPtr(entry) > @intFromPtr(node)) break;
        previous = entry;
        current = entry.next;
    }
    node.next = current;
    if (previous) |entry| {
        entry.next = node;
    } else {
        self.free_list = node;
    }
}

fn removeFreeNode(self: *Self, target: *FreeBlock) void {
    var previous: ?*FreeBlock = null;
    var current = self.free_list;
    while (current) |entry| {
        if (entry == target) {
            self.unlinkFreeNode(previous, entry);
            return;
        }
        previous = entry;
        current = entry.next;
    }
    unreachable;
}

fn unlinkFreeNode(self: *Self, previous: ?*FreeBlock, node: *FreeBlock) void {
    if (previous) |entry| {
        entry.next = node.next;
    } else {
        self.free_list = node.next;
    }
}

fn initializeBlock(
    address: usize,
    size: usize,
    is_free: bool,
    requested_size: usize,
    payload_offset: usize,
) *BlockHeader {
    const header: *BlockHeader = @ptrFromInt(address);
    header.* = .{
        .size = size,
        .requested_size = requested_size,
        .payload_offset = payload_offset,
        .free = is_free,
    };
    footerFromHeader(header).* = .{ .size = size };
    return header;
}

fn writeAllocationTag(header: *BlockHeader) void {
    const address = @intFromPtr(header) + header.payload_offset - ALLOCATION_TAG_SIZE;
    @as(*usize, @ptrFromInt(address)).* = @intFromPtr(header);
}

fn footerFromHeader(header: *const BlockHeader) *BlockFooter {
    return @ptrFromInt(@intFromPtr(header) + header.size - @sizeOf(BlockFooter));
}

fn freeNodeFromHeader(header: *BlockHeader) *FreeBlock {
    return @ptrFromInt(@intFromPtr(header) + @sizeOf(BlockHeader));
}

fn headerFromFreeNode(node: *FreeBlock) *BlockHeader {
    return @ptrFromInt(@intFromPtr(node) - @sizeOf(BlockHeader));
}

fn chooseAllocationBlockSize(available_size: usize, requested_size: usize) usize {
    const remainder = available_size - requested_size;
    return if (remainder >= minimum_block_size) requested_size else available_size;
}

fn alignForward(value: usize, alignment: usize) Error!usize {
    const with_mask = std.math.add(usize, value, alignment - 1) catch
        return Error.AllocationOverflow;
    return with_mask & ~(alignment - 1);
}

fn alignForwardUnchecked(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn alignBackward(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
}
