const SegmentDescriptor = packed struct {
    limit_low: u16 = 0,
    base_low: u24 = 0,
    access: u8 = 0,
    flags_and_limit_high: u8 = 0,
    base_high: u8 = 0,

    fn flat(access: u8) SegmentDescriptor {
        return .{
            .limit_low = 0xffff,
            .access = access,
            .flags_and_limit_high = 0b11001111,
        };
    }

    fn tss(base: usize, limit: usize) SegmentDescriptor {
        return .{
            .limit_low = @truncate(limit & 0xffff),
            .base_low = @truncate(base & 0x00ff_ffff),
            .access = 0x89,
            .flags_and_limit_high = @truncate((limit >> 16) & 0x0f),
            .base_high = @truncate(base >> 24),
        };
    }
};

const GlobalDescriptorTable = packed struct {
    null: SegmentDescriptor = .{},
    kernel_code: SegmentDescriptor = SegmentDescriptor.flat(0x9a),
    kernel_data: SegmentDescriptor = SegmentDescriptor.flat(0x92),
    user_code: SegmentDescriptor = SegmentDescriptor.flat(0xfa),
    user_data: SegmentDescriptor = SegmentDescriptor.flat(0xf2),
    tss: SegmentDescriptor = .{},
};

const GlobalDescriptorTableRegister = packed struct {
    size: u16 = undefined,
    address: u32 = undefined,
};

var gdt = GlobalDescriptorTable{};
var gdtr = GlobalDescriptorTableRegister{};

const TaskStateSegment = extern struct {
    previous_task_link: u16 = 0,
    reserved0: u16 = 0,
    esp0: u32 = 0,
    ss0: u16 = KERNEL_DATA_SELECTOR,
    reserved1: u16 = 0,
    esp1: u32 = 0,
    ss1: u16 = 0,
    reserved2: u16 = 0,
    esp2: u32 = 0,
    ss2: u16 = 0,
    reserved3: u16 = 0,
    cr3: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    es: u16 = 0,
    reserved4: u16 = 0,
    cs: u16 = 0,
    reserved5: u16 = 0,
    ss: u16 = 0,
    reserved6: u16 = 0,
    ds: u16 = 0,
    reserved7: u16 = 0,
    fs: u16 = 0,
    reserved8: u16 = 0,
    gs: u16 = 0,
    reserved9: u16 = 0,
    ldt_selector: u16 = 0,
    reserved10: u16 = 0,
    trap: u16 = 0,
    io_map_base: u16 = @sizeOf(TaskStateSegment),
};

comptime {
    @import("std").debug.assert(@sizeOf(SegmentDescriptor) == 8);
    @import("std").debug.assert(@sizeOf(GlobalDescriptorTable) == 48);
    @import("std").debug.assert(@sizeOf(TaskStateSegment) == 104);
}

var tss = TaskStateSegment{};

pub const KERNEL_CODE_SELECTOR = @offsetOf(GlobalDescriptorTable, "kernel_code");
pub const KERNEL_DATA_SELECTOR = @offsetOf(GlobalDescriptorTable, "kernel_data");
pub const USER_CODE_SELECTOR = @offsetOf(GlobalDescriptorTable, "user_code") | 0x3;
pub const USER_DATA_SELECTOR = @offsetOf(GlobalDescriptorTable, "user_data") | 0x3;
pub const TSS_SELECTOR = @offsetOf(GlobalDescriptorTable, "tss");

pub const CODE_SELECTOR = KERNEL_CODE_SELECTOR;

pub fn initialize(kernel_stack_top: usize) void {
    const tss_address = @intFromPtr(&tss);

    tss.ss0 = KERNEL_DATA_SELECTOR;
    tss.esp0 = @truncate(kernel_stack_top);
    tss.io_map_base = @sizeOf(TaskStateSegment);

    gdt.tss = SegmentDescriptor.tss(tss_address, @sizeOf(TaskStateSegment) - 1);

    gdtr.address = @intFromPtr(&gdt);
    gdtr.size = @sizeOf(GlobalDescriptorTable) - 1;

    asm volatile (
        \\lgdt (%[gdtr])
        \\
        \\mov %[kernelDataSelector], %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %ss
        \\mov %[tssSelector], %ax
        \\ltr %ax
        :
        : [gdtr] "{ecx}" (&gdtr),
          [kernelDataSelector] "i" (KERNEL_DATA_SELECTOR),
          [tssSelector] "i" (TSS_SELECTOR),
        : .{ .ecx = true, .memory = true });
}

pub fn setPrivilegeStack(kernel_stack_top: usize) void {
    tss.esp0 = @truncate(kernel_stack_top);
}

pub fn getPrivilegeStackForTest() usize {
    return tss.esp0;
}
