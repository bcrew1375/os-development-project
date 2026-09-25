const arch = @import("arch");
const kernel_common = @import("kernel_common");
const terminal = kernel_common.terminal;
const kernel_initialization = @import("kernel_initialization.zig");
const launch_root_process = @import("launch_root_process.zig");
const TextColor = @import("arch").TextColor;

const std = @import("std");
const abi = @import("abi");

pub export fn kernelMain() void {
    const prepared_root_process = kernel_initialization.initialize(
        KernelInitializationServices,
    ) catch {
        arch.cpu.unrecoverableHalt();
    };

    launch_root_process.enterPreparedRootProcess(prepared_root_process);
}

const KernelInitializationServices = struct {
    pub const PreparedRootProcess = launch_root_process.PreparedRootProcess;

    pub fn initializeTerminal() void {
        terminal.initialize();
    }

    pub fn writeMessage(message: []const u8) void {
        terminal.print.printString(message);
    }

    pub fn writeSystemSmokeHeader() void {
        terminal.print.printString(abi.system_smoke.HEADER);
    }

    pub fn writeRootProcessPrepared() void {
        terminal.print.printString(abi.system_smoke.ROOT_PROCESS_PREPARED);
    }

    pub fn writeKernelInitialized() void {
        terminal.print.printString(abi.system_smoke.KERNEL_INITIALIZED);
    }

    pub fn prepareRootProcess() !PreparedRootProcess {
        return launch_root_process.prepareRootProcess();
    }

    pub fn setErrorColor() void {
        arch.platform.setColor(TextColor.RED);
    }

    pub fn writePreparationFailure(err: anyerror) void {
        arch.platform.writer().print(
            "First user process preparation failed with error: {s}\n",
            .{@errorName(err)},
        ) catch {};
    }

    pub fn finishBoot() void {
        arch.boot.finishBoot();
    }

    pub fn initializeInterrupts() void {
        arch.interrupts.initialize();
    }

    pub fn enableInterrupts() void {
        arch.interrupts.enableInterrupts();
    }
};

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, number: ?usize) noreturn {
    arch.interrupts.disableInterrupts();
    arch.platform.setColor(TextColor.RED);
    arch.platform.writer().writeAll("\n!KERNEL PANIC!\n") catch {};
    arch.platform.writer().writeAll(message) catch {};
    arch.platform.writer().writeAll("\n") catch {};
    _ = stack_trace;
    _ = number;
    while (true) {}
}
