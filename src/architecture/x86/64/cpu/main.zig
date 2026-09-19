const gdt = @import("../interrupts/global_descriptor_table.zig");

const extended_feature_enable_register: u32 = 0xC000_0080;
const no_execute_enable: u64 = 1 << 11;
const write_protect: usize = 1 << 16;

pub fn unrecoverableHalt() noreturn {
    asm volatile (
        \\cli
        \\hlt
    );
    unreachable;
}

pub fn initializeMemoryProtection() void {
    var control_register_0 = asm volatile ("mov %%cr0, %[value]"
        : [value] "=r" (-> usize),
    );
    control_register_0 |= write_protect;
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (control_register_0),
        : .{ .memory = true });

    const extended_feature_enable = readModelSpecificRegister(extended_feature_enable_register);
    writeModelSpecificRegister(
        extended_feature_enable_register,
        extended_feature_enable | no_execute_enable,
    );
}

pub fn enterUserMode(entry_point: usize, stack_top: usize, argument0: usize) noreturn {
    asm volatile (
        \\cli
        \\mov %[userDataSelector], %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\push %[userDataSelector]
        \\push %[stackTop]
        \\pushfq
        \\pop %rax
        \\or $0x200, %rax
        \\push %rax
        \\push %[userCodeSelector]
        \\push %[entryPoint]
        \\mov %[argument0], %rdi
        \\iretq
        :
        : [userDataSelector] "i" (gdt.USER_DATA_SELECTOR),
          [userCodeSelector] "i" (gdt.USER_CODE_SELECTOR),
          [stackTop] "r" (stack_top),
          [entryPoint] "r" (entry_point),
          [argument0] "r" (argument0),
        : .{ .rax = true, .memory = true });
    unreachable;
}

fn readModelSpecificRegister(register: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [register] "{ecx}" (register),
    );
    return (@as(u64, high) << 32) | low;
}

fn writeModelSpecificRegister(register: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [register] "{ecx}" (register),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
        : .{ .memory = true });
}
