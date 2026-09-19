const port_io = @import("../io/port_io.zig");
const pic = @import("../../interrupts/pic.zig");

var interrupt_count: usize = 0;

pub fn initializeTimer(frequency: usize) void {
    if (frequency == 0) {
        return;
    }

    resetInterruptCount();

    const PIT_DIVISOR: u16 = @truncate(1193182 / frequency);
    port_io.out8(0x43, 0b00110100);
    port_io.out8(0x40, @truncate(PIT_DIVISOR & 0xFF));
    port_io.out8(0x40, @truncate(PIT_DIVISOR >> 8));

    pic.clearMask(pic.TIMER_IRQ);
}

pub fn recordInterrupt() void {
    _ = @atomicRmw(usize, &interrupt_count, .Add, 1, .monotonic);
}

pub fn resetInterruptCount() void {
    @atomicStore(usize, &interrupt_count, 0, .monotonic);
}

pub fn getInterruptCount() usize {
    return @atomicLoad(usize, &interrupt_count, .monotonic);
}
