const arch = @import("arch");
const framework = @import("../framework.zig");

const timer_frequency_hz: usize = 1000;
const required_interrupt_count: usize = 2;
const maximum_poll_iterations: usize = 100_000_000;

pub fn interruptsAreDelivered() !void {
    arch.interrupts.disableInterrupts();
    @call(.never_inline, arch.boot.finishBoot, .{});
    arch.platform.resetTimerInterruptCount();
    @call(.never_inline, arch.platform.initializeTimer, .{timer_frequency_hz});

    arch.interrupts.enableInterrupts();
    defer arch.interrupts.disableInterrupts();

    var poll_iteration: usize = 0;
    while (arch.platform.getTimerInterruptCount() < required_interrupt_count and
        poll_iteration < maximum_poll_iterations) : (poll_iteration += 1)
    {
        asm volatile ("pause");
    }

    arch.interrupts.disableInterrupts();
    try framework.expect(arch.platform.getTimerInterruptCount() >= required_interrupt_count);
}
