const gdt = @import("global_descriptor_table.zig");
const pic = @import("../../common/interrupts/pic.zig");
const vectors = @import("../../common/interrupts/vectors.zig");

const std = @import("std");

const interruptHandler = @import("main.zig").interruptHandler;

const TOTAL_INTERRUPTS: usize = 256;

const InterruptDescriptorTableStruct = packed struct {
    offset_1: u16 = 0, // Offset bits 0-15
    selector: u16 = 0, // Selector from GDT
    ist: u3 = 0, // Interrupt Stack Table offset
    ist_padding: u5 = 0, // IST padding bits
    type_attributes: u8 = 0, // Descriptor type and attributes
    offset_2: u16 = 0, // Offset bits 16-31
    offset_3: u32 = 0, // Offset bits 32-63
    reserved: u32 = 0, // Reserved bits
};

const InterruptDescriptorTableRegisterStruct = packed struct {
    limit: u16 = 0, // Size of descriptor table minus 1
    base: u64 = 0, // Base address of the start of the interrupt descriptor table
};

comptime {
    std.debug.assert(@sizeOf(InterruptDescriptorTableStruct) == 16);
    std.debug.assert(@bitSizeOf(InterruptDescriptorTableRegisterStruct) == 80);
}

var interrupt_descriptor_table: [TOTAL_INTERRUPTS]InterruptDescriptorTableStruct align(16) =
    [_]InterruptDescriptorTableStruct{.{}} ** TOTAL_INTERRUPTS;

var interrupt_descriptor_table_register: InterruptDescriptorTableRegisterStruct align(16) =
    InterruptDescriptorTableRegisterStruct{ .base = undefined };

var trampolines: [TOTAL_INTERRUPTS]*const fn () callconv(.naked) void = undefined;

pub fn initialize() void {
    inline for (0..TOTAL_INTERRUPTS) |vector| {
        trampolines[vector] = makeTrampoline(vector);
        set(vector, @intFromPtr(trampolines[vector]), interruptGate(0));
    }

    set(vectors.syscall, @intFromPtr(trampolines[vectors.syscall]), interruptGate(3));

    interrupt_descriptor_table_register.limit = @sizeOf(@TypeOf(interrupt_descriptor_table)) - 1;
    interrupt_descriptor_table_register.base = @intFromPtr(&interrupt_descriptor_table);

    idtLoad();

    pic.remap(pic.MASTER_VECTOR_OFFSET, pic.SLAVE_VECTOR_OFFSET);
    pic.maskAll();
    pic.clearMask(pic.KEYBOARD_IRQ);
}

pub fn set(interruptVector: usize, address: usize, typeAttribute: usize) void {
    var interrupt_descriptor: *InterruptDescriptorTableStruct = &interrupt_descriptor_table[interruptVector];
    interrupt_descriptor.offset_1 = @truncate(address & 0xffff);
    interrupt_descriptor.selector = gdt.CODE_SELECTOR;
    interrupt_descriptor.ist = 0;
    interrupt_descriptor.ist_padding = 0;
    interrupt_descriptor.type_attributes = @truncate(typeAttribute);
    interrupt_descriptor.offset_2 = @truncate((address >> 16) & 0xffff);
    interrupt_descriptor.offset_3 = @truncate(address >> 32);
    interrupt_descriptor.reserved = 0;
    return;
}

fn interruptGate(dpl: u2) usize {
    return 0x80 | (@as(usize, dpl) << 5) | 0x0E;
}

fn hasErrorCode(comptime vector: u32) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21 => true,
        else => false,
    };
}

// Generate a long-mode trampoline that saves general-purpose registers and
// calls `interruptHandler(vector, stack_pointer)` using the SysV x86_64 ABI.
fn makeTrampoline(comptime vector: u32) *const fn () callconv(.naked) void {
    return struct {
        fn trampoline() align(16) callconv(.naked) void {
            asm volatile ((if (hasErrorCode(vector)) "" else "pushq $0\n") ++
                    \\pushq %%rax
                    \\pushq %%rcx
                    \\pushq %%rdx
                    \\pushq %%rbx
                    \\pushq %%rbp
                    \\pushq %%rsi
                    \\pushq %%rdi
                    \\pushq %%r8
                    \\pushq %%r9
                    \\pushq %%r10
                    \\pushq %%r11
                    \\pushq %%r12
                    \\pushq %%r13
                    \\pushq %%r14
                    \\pushq %%r15
                    \\mov %%rsp, %%rsi
                    \\mov %[vector], %%dil
                    \\subq $8, %%rsp
                    \\call %[interruptHandler:P]
                    \\addq $8, %%rsp
                    \\popq %%r15
                    \\popq %%r14
                    \\popq %%r13
                    \\popq %%r12
                    \\popq %%r11
                    \\popq %%r10
                    \\popq %%r9
                    \\popq %%r8
                    \\popq %%rdi
                    \\popq %%rsi
                    \\popq %%rbp
                    \\popq %%rbx
                    \\popq %%rdx
                    \\popq %%rcx
                    \\popq %%rax
                    \\addq $8, %%rsp
                    \\iretq
                :
                : [vector] "i" (vector),
                  [interruptHandler] "i" (&interruptHandler),
                : .{ .memory = true });
        }
    }.trampoline;
}

fn idtLoad() void {
    asm volatile (
        \\cli
        \\lidt (%[interrupt_descriptor_table_register])
        :
        : [interrupt_descriptor_table_register] "r" (&interrupt_descriptor_table_register),
        : .{ .memory = true });
}
