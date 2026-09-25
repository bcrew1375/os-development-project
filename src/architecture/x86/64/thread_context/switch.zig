//! x86-64 kernel continuation switching and initial userspace return.

extern fn x86_64_thread_context_switch(
    current_stack_pointer: *usize,
    next_stack_pointer: usize,
) callconv(.c) void;

pub fn switchKernelStack(
    current_stack_pointer: *usize,
    next_stack_pointer: usize,
) void {
    x86_64_thread_context_switch(current_stack_pointer, next_stack_pointer);
}

fn switchKernelStackImpl(
    current_stack_pointer: *usize,
    next_stack_pointer: usize,
) callconv(.naked) void {
    _ = current_stack_pointer;
    _ = next_stack_pointer;
    asm volatile (
        \\pushq %rbx
        \\pushq %rbp
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\movq %rsp, (%rdi)
        \\movq %rsi, %rsp
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %rbp
        \\popq %rbx
        \\retq
    );
}

pub fn restoreInitialContext() callconv(.naked) noreturn {
    asm volatile (
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rdi
        \\popq %rsi
        \\popq %rbp
        \\popq %rbx
        \\popq %rdx
        \\popq %rcx
        \\popq %rax
        \\addq $8, %rsp
        \\iretq
    );
}

comptime {
    @export(&switchKernelStackImpl, .{ .name = "x86_64_thread_context_switch" });
}
