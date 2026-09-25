const std = @import("std");

const KERNEL_CODE_INDEX: usize = 1;
const KERNEL_DATA_INDEX: usize = 2;
const USER_DATA_INDEX: usize = 3;
const USER_CODE_INDEX: usize = 4;
const TSS_INDEX: usize = 5;

const DescriptorTableEntryCount: usize = 7;
const TaskStateSegmentSize: usize = 104;

const GlobalDescriptorTableRegister = packed struct {
    size: u16 = undefined,
    address: u64 = undefined,
};

const TaskStateSegment = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    io_map_base: u16 = TaskStateSegmentSize,
};

comptime {
    std.debug.assert(@bitSizeOf(GlobalDescriptorTableRegister) == 80);
    std.debug.assert(@bitSizeOf(TaskStateSegment) == TaskStateSegmentSize * 8);
}

var gdt align(16) = [_]u64{0} ** DescriptorTableEntryCount;
var gdtr align(16) = GlobalDescriptorTableRegister{};
var tss align(16) = TaskStateSegment{};

pub const KERNEL_CODE_SELECTOR: u16 = KERNEL_CODE_INDEX * @sizeOf(u64);
pub const KERNEL_DATA_SELECTOR: u16 = KERNEL_DATA_INDEX * @sizeOf(u64);
pub const USER_DATA_SELECTOR: u16 = (USER_DATA_INDEX * @sizeOf(u64)) | 0x3;
pub const USER_CODE_SELECTOR: u16 = (USER_CODE_INDEX * @sizeOf(u64)) | 0x3;
pub const TSS_SELECTOR: u16 = TSS_INDEX * @sizeOf(u64);

pub const CODE_SELECTOR = KERNEL_CODE_SELECTOR;

pub fn initialize(kernel_stack_top: usize) void {
    tss.rsp0 = kernel_stack_top;
    tss.io_map_base = TaskStateSegmentSize;

    gdt[0] = 0;
    gdt[KERNEL_CODE_INDEX] = codeDescriptor(0);
    gdt[KERNEL_DATA_INDEX] = dataDescriptor(0);
    gdt[USER_DATA_INDEX] = dataDescriptor(3);
    gdt[USER_CODE_INDEX] = codeDescriptor(3);
    setTaskStateSegmentDescriptor(@intFromPtr(&tss), TaskStateSegmentSize - 1);

    gdtr.address = @intFromPtr(&gdt);
    gdtr.size = @sizeOf(@TypeOf(gdt)) - 1;

    asm volatile (
        \\lgdt (%[gdtr])
        \\mov %[kernelDataSelector], %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%ss
        \\xor %%eax, %%eax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\pushq %[kernelCodeSelector]
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\mov %[tssSelector], %%ax
        \\ltr %%ax
        :
        : [gdtr] "r" (&gdtr),
          [kernelCodeSelector] "i" (KERNEL_CODE_SELECTOR),
          [kernelDataSelector] "i" (KERNEL_DATA_SELECTOR),
          [tssSelector] "i" (TSS_SELECTOR),
        : .{ .rax = true, .memory = true });
}

pub fn setPrivilegeStack(kernel_stack_top: usize) void {
    tss.rsp0 = kernel_stack_top;
}

pub fn getPrivilegeStackForTest() usize {
    return tss.rsp0;
}

fn codeDescriptor(dpl: u2) u64 {
    return descriptor(presentBit() | descriptorPrivilegeLevelBits(dpl) | 0x1A, 0x20);
}

fn dataDescriptor(dpl: u2) u64 {
    return descriptor(presentBit() | descriptorPrivilegeLevelBits(dpl) | 0x12, 0);
}

fn descriptor(access: u8, flags: u8) u64 {
    return (@as(u64, access) << 40) | (@as(u64, flags & 0xF0) << 48);
}

fn setTaskStateSegmentDescriptor(base: usize, limit: usize) void {
    gdt[TSS_INDEX] = (@as(u64, limit & 0xffff)) |
        (@as(u64, base & 0x00ff_ffff) << 16) |
        (@as(u64, 0x89) << 40) |
        (@as(u64, (limit >> 16) & 0x0f) << 48) |
        (@as(u64, (base >> 24) & 0xff) << 56);
    gdt[TSS_INDEX + 1] = @as(u64, base >> 32);
}

fn presentBit() u8 {
    return 0x80;
}

fn descriptorPrivilegeLevelBits(dpl: u2) u8 {
    return @as(u8, dpl) << 5;
}
