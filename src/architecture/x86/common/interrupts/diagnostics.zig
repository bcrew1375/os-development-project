pub const vectors = @import("vectors.zig");

pub const TIMER_DIAGNOSTIC_INTERVAL: usize = 100;

pub const Decision = struct {
    print: bool,
    count: usize,
};

/// Per-dispatcher state for bounded interrupt bring-up diagnostics.
pub const State = struct {
    interrupt_seen: [vectors.total]bool = [_]bool{false} ** vectors.total,
    interrupt_counts: [vectors.total]usize = [_]usize{0} ** vectors.total,

    pub fn recordInterrupt(self: *State, vector: usize) Decision {
        var count: usize = 0;
        if (vector < vectors.total) {
            self.interrupt_counts[vector] +|= 1;
            count = self.interrupt_counts[vector];
        }

        if (vector < vectors.first_hardware_interrupt and vector != vectors.page_fault) {
            return .{ .print = true, .count = count };
        }

        if (vector == vectors.timer) {
            return .{
                .print = count == 1 or count % TIMER_DIAGNOSTIC_INTERVAL == 0,
                .count = count,
            };
        }

        if (vector < vectors.total and !self.interrupt_seen[vector]) {
            self.interrupt_seen[vector] = true;
            return .{ .print = true, .count = count };
        }

        return .{ .print = false, .count = count };
    }
};
