//! Loads the root-process ELF image and finalizes its segment permissions.

const arch = @import("arch");
const kernel_common = @import("kernel_common");
const shared = @import("shared");
const std = @import("std");

const boot_modules = @import("boot_modules.zig");
const user_memory = @import("user_memory.zig");

const elf_loader = shared.executable.elf;
const vmm = kernel_common.memory_management.virtual_memory;

pub fn loadRootProcessElf(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    root_module: arch.BootModule,
) !usize {
    const image = try boot_modules.getBootModuleBytes(root_module);
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const loadable_image = try elf_loader.parseLoadableImage(image, page_size);

    for (0..loadable_image.segment_count) |segment_index| {
        try loadRootProcessSegment(page_table_root, address_space, image, try elf_loader.getLoadableSegment(image, segment_index));
    }

    return @intCast(loadable_image.entry_point);
}

fn loadRootProcessSegment(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    image: []const u8,
    segment: elf_loader.LoadableSegment,
) !void {
    const mapping_range = pageAlignedSegmentRange(segment);

    try mapSegmentWriteableForLoading(page_table_root, address_space, mapping_range, segment);
    try writeSegmentContents(page_table_root, image, segment);
    try restoreSegmentPermissions(page_table_root, address_space, mapping_range, finalUserSegmentPermissions(segment));
}

const AddressRange = struct { start: u64, end: u64 };

fn pageAlignedSegmentRange(segment: elf_loader.LoadableSegment) AddressRange {
    const page_size: u64 = @intCast(arch.mmu.getPageSize());
    const virtual_end = segment.virtual_address + segment.memory_size;
    return .{
        .start = std.mem.alignBackward(u64, segment.virtual_address, page_size),
        .end = std.mem.alignForward(u64, virtual_end, page_size),
    };
}

fn finalUserSegmentPermissions(segment: elf_loader.LoadableSegment) vmm.MemoryPermissions {
    return .{
        .readable = segment.permissions.readable,
        .writeable = segment.permissions.writeable,
        .executable = segment.permissions.executable,
        .user_accessible = true,
    };
}

/// Maps the segment writeable regardless of its final permissions, since
/// `writeSegmentContents` needs write access to populate it. Permissions are
/// locked down to their real values afterward by `restoreSegmentPermissions`.
fn mapSegmentWriteableForLoading(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    range: AddressRange,
    segment: elf_loader.LoadableSegment,
) !void {
    try vmm.mapBootstrapContiguousInAddressSpace(page_table_root, address_space, range.start, range.end, .{
        .readable = segment.permissions.readable,
        .writeable = true,
        .executable = segment.permissions.executable,
        .user_accessible = true,
    });
}

fn writeSegmentContents(
    page_table_root: arch.AddressSpaceRoot,
    image: []const u8,
    segment: elf_loader.LoadableSegment,
) !void {
    const file_end = try std.math.add(usize, segment.file_offset, segment.file_size);
    try user_memory.copyIntoUserSpace(page_table_root, segment.virtual_address, image[segment.file_offset..file_end]);

    const bss_start = segment.virtual_address + segment.file_size;
    const bss_size = segment.memory_size - segment.file_size;
    try user_memory.zeroUserSpace(page_table_root, bss_start, bss_size);
}

fn restoreSegmentPermissions(
    page_table_root: arch.AddressSpaceRoot,
    address_space: *vmm.AddressSpace,
    range: AddressRange,
    permissions: vmm.MemoryPermissions,
) !void {
    try vmm.protectInAddressSpace(page_table_root, address_space, range.start, range.end, permissions);
}
