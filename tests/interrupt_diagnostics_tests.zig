const arch = @import("arch");
const std = @import("std");
const diagnostics = arch.impl.test_support.interrupt_diagnostics;
const pic_policy = arch.impl.test_support.pic_policy;
const vectors = diagnostics.vectors;

test "Interrupt diagnostics keep exceptions visible and page faults bounded" {
    var state: diagnostics.State = .{};
    try std.testing.expect(state.recordInterrupt(vectors.divide_by_zero).print);
    try std.testing.expect(state.recordInterrupt(vectors.divide_by_zero).print);
    try std.testing.expect(state.recordInterrupt(vectors.page_fault).print);
    try std.testing.expect(!state.recordInterrupt(vectors.page_fault).print);
}

test "Interrupt diagnostics sample timers and print hardware vectors once" {
    var state: diagnostics.State = .{};
    try std.testing.expect(state.recordInterrupt(vectors.timer).print);
    for (2..diagnostics.TIMER_DIAGNOSTIC_INTERVAL) |_| {
        try std.testing.expect(!state.recordInterrupt(vectors.timer).print);
    }
    const sampled = state.recordInterrupt(vectors.timer);
    try std.testing.expect(sampled.print);
    try std.testing.expectEqual(diagnostics.TIMER_DIAGNOSTIC_INTERVAL, sampled.count);

    try std.testing.expect(state.recordInterrupt(vectors.keyboard).print);
    try std.testing.expect(!state.recordInterrupt(vectors.keyboard).print);
}

test "Interrupt diagnostics never decorate syscall output" {
    var state: diagnostics.State = .{};
    const first = state.recordInterrupt(vectors.syscall);
    const second = state.recordInterrupt(vectors.syscall);

    try std.testing.expect(!first.print);
    try std.testing.expect(!second.print);
    try std.testing.expectEqual(@as(usize, 0), first.count);
    try std.testing.expectEqual(@as(usize, 0), second.count);
}

test "Interrupt diagnostics handle out-of-range vectors and saturating counts" {
    var state: diagnostics.State = .{};
    const out_of_range = state.recordInterrupt(vectors.total);
    try std.testing.expect(!out_of_range.print);
    try std.testing.expectEqual(@as(usize, 0), out_of_range.count);

    state.interrupt_counts[vectors.keyboard] = std.math.maxInt(usize);
    const saturated = state.recordInterrupt(vectors.keyboard);
    try std.testing.expectEqual(std.math.maxInt(usize), saturated.count);
}

test "PIC hardware-vector classification covers exactly the legacy IRQ range" {
    try std.testing.expect(!pic_policy.isHardwareInterrupt(pic_policy.MASTER_VECTOR_OFFSET - 1));
    try std.testing.expect(pic_policy.isHardwareInterrupt(pic_policy.MASTER_VECTOR_OFFSET));
    try std.testing.expect(pic_policy.isHardwareInterrupt(pic_policy.SLAVE_VECTOR_OFFSET + 7));
    try std.testing.expect(!pic_policy.isHardwareInterrupt(pic_policy.SLAVE_VECTOR_OFFSET + 8));
}
