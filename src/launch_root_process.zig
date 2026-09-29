//! Facade for the kernel's first user process.
//!
//! The mechanics live in the `root_process/` namespace: virtual layout, ELF
//! loading, initial stack construction, boot-info delegation, boot-module
//! mapping, and the preparation transaction. This file keeps the stable public
//! surface (`RootProcessLayout`, `PreparedRootProcess`, prepare/enter) and the
//! handoff of the prepared thread to the scheduler.

const kernel_common = @import("kernel_common");

const layout = @import("root_process/layout.zig");
const preparation = @import("root_process/preparation.zig");

pub const RootProcessLayout = layout.RootProcessLayout;
pub const PreparedRootProcess = preparation.PreparedRootProcess;

var root_thread_handle: ?kernel_common.process.thread.Handle = null;

pub fn launchRootProcess() !noreturn {
    const prepared_root_process = try prepareRootProcess();
    enterPreparedRootProcess(prepared_root_process);
}

pub fn prepareRootProcess() !PreparedRootProcess {
    return preparation.prepareRootProcess();
}

pub fn enterPreparedRootProcess(prepared_root_process: PreparedRootProcess) noreturn {
    root_thread_handle = prepared_root_process.thread_handle;
    kernel_common.process.scheduler.initialize(prepared_root_process.address_space_root) catch {
        @panic("failed to initialize scheduler");
    };
    kernel_common.process.scheduler.makeReady(prepared_root_process.thread_handle) catch {
        @panic("failed to enqueue prepared root thread");
    };
    kernel_common.process.scheduler.start();
}

pub fn isRootThreadForSmoke() bool {
    const expected = root_thread_handle orelse return false;
    const current = kernel_common.process.execution_context.current() catch return false;
    return current.thread_handle == expected;
}
