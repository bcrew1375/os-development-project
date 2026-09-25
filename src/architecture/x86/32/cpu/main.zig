const gdt = @import("../interrupts/global_descriptor_table.zig");

pub fn unrecoverableHalt() noreturn {
    asm volatile (
        \\cli
        \\hlt
    );
    unreachable;
}

pub fn waitForInterrupt() void {
    asm volatile (
        \\sti
        \\hlt
        ::: .{ .memory = true });
}

pub fn enterUserMode(entry_point: usize, stack_top: usize, argument0: usize) noreturn {
    _ = argument0;

    asm volatile (
        \\cli
        \\mov %[userDataSelector], %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\push %[userDataSelector]
        \\push %[stackTop]
        \\pushf
        \\pop %eax
        \\or $0x200, %eax
        \\push %eax
        \\push %[userCodeSelector]
        \\push %[entryPoint]
        \\iret
        :
        : [userDataSelector] "i" (gdt.USER_DATA_SELECTOR),
          [userCodeSelector] "i" (gdt.USER_CODE_SELECTOR),
          [stackTop] "r" (stack_top),
          [entryPoint] "r" (entry_point),
        : .{ .eax = true, .memory = true });
    unreachable;
}
