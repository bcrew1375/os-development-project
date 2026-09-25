//! x86-32 kernel continuation switching and initial userspace return.

extern fn x86_32_thread_context_switch(
    current_stack_pointer: *usize,
    next_stack_pointer: usize,
) callconv(.c) void;

pub fn switchKernelStack(
    current_stack_pointer: *usize,
    next_stack_pointer: usize,
) void {
    x86_32_thread_context_switch(current_stack_pointer, next_stack_pointer);
}

fn switchKernelStackImpl(
    current_stack_pointer: *usize,
    next_stack_pointer: usize,
) callconv(.naked) void {
    _ = current_stack_pointer;
    _ = next_stack_pointer;
    asm volatile (
        \\push %ebx
        \\push %esi
        \\push %edi
        \\push %ebp
        \\mov 20(%esp), %eax
        \\mov %esp, (%eax)
        \\mov 24(%esp), %esp
        \\pop %ebp
        \\pop %edi
        \\pop %esi
        \\pop %ebx
        \\ret
    );
}

pub fn restoreInitialContext() callconv(.naked) noreturn {
    asm volatile (
        \\pop %eax
        \\mov %ax, %gs
        \\pop %eax
        \\mov %ax, %fs
        \\pop %eax
        \\mov %ax, %es
        \\pop %eax
        \\mov %ax, %ds
        \\popa
        \\add $4, %esp
        \\iret
    );
}

comptime {
    @export(&switchKernelStackImpl, .{ .name = "x86_32_thread_context_switch" });
}
