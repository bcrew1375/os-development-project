const abi = @import("abi");

const frame_adapter = @import("frame_adapter.zig");
const policy = @import("../../common/interrupts/policy.zig");

pub const idt = @import("interrupt_descriptor_table.zig");
pub const pic = @import("../../common/interrupts/pic.zig");

const Mechanisms = struct {
    pub fn acknowledgeInterrupt(vector: usize) void {
        pic.sendEndOfInterrupt(vector);
    }
};

const dispatcher = policy.Dispatcher(frame_adapter, Mechanisms);

pub fn enableInterrupts() void {
    asm volatile ("sti");
}

pub fn disableInterrupts() void {
    asm volatile ("cli");
}

pub fn acknowledgeInterrupt(vector: usize) void {
    Mechanisms.acknowledgeInterrupt(vector);
}

pub fn maskInterruptSource(kind: abi.notification.InterruptSourceKind) void {
    switch (kind) {
        .timer => pic.setMask(pic.TIMER_IRQ),
        _ => {},
    }
}

pub fn unmaskInterruptSource(kind: abi.notification.InterruptSourceKind) void {
    switch (kind) {
        .timer => pic.clearMask(pic.TIMER_IRQ),
        _ => {},
    }
}

pub fn interruptHandler(vector: usize, stack_pointer: usize) callconv(.c) void {
    dispatcher.dispatch(vector, stack_pointer);
}
