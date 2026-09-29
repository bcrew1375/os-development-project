const abi = @import("abi");
const arch = @import("arch");
const kernel_common = @import("kernel_common");
const root = @import("root");

const diagnostics = @import("diagnostics.zig");
const vectors = @import("vectors.zig");
const keyboard = @import("../platform/io/keyboard.zig");
const time = @import("../platform/time/main.zig");

pub const MASTER_VECTOR_OFFSET: usize = 0x20;
pub const SLAVE_VECTOR_OFFSET: usize = 0x28;

pub const InterruptedFrame = struct {
    error_code: u64,
    instruction_pointer: u64,
    code_selector: u64,
    user_mode: bool,
};

pub fn isHardwareInterrupt(vector: usize) bool {
    return vector >= MASTER_VECTOR_OFFSET and vector < SLAVE_VECTOR_OFFSET + 8;
}

pub fn Dispatcher(comptime FrameAdapter: type, comptime Mechanisms: type) type {
    validateFrameAdapter(FrameAdapter);
    validateMechanisms(Mechanisms);
    const TrapFrame = FrameAdapter.TrapFrame;

    return struct {
        var diagnostic_state: diagnostics.State = .{};

        pub fn dispatch(vector: usize, stack_pointer: usize) void {
            const trap_frame = FrameAdapter.fromStackPointer(stack_pointer);
            if (observeExpectedFault(vector, trap_frame)) return;

            const diagnostic = diagnostic_state.recordInterrupt(vector);
            if (diagnostic.print) {
                arch.platform.writer().print("Interrupt 0x{x}: ", .{vector}) catch {};
            }

            const schedule_from_idle = dispatchVector(vector, trap_frame, diagnostic);
            if (diagnostic.print) {
                arch.platform.writer().print(" --- Stack Index: {x}\n", .{stack_pointer}) catch {};
            }

            Mechanisms.acknowledgeInterrupt(vector);
            if (schedule_from_idle) scheduleFromIdleIfReady();
        }

        fn observeExpectedFault(vector: usize, trap_frame: *const TrapFrame) bool {
            if (comptime @hasDecl(root, "architectureTestObserveException")) {
                return root.architectureTestObserveException(
                    vector,
                    FrameAdapter.errorCode(trap_frame),
                    FrameAdapter.instructionPointer(trap_frame),
                    FrameAdapter.readCr2(),
                );
            }
            return false;
        }

        fn dispatchVector(
            vector: usize,
            trap_frame: *TrapFrame,
            diagnostic: diagnostics.Decision,
        ) bool {
            switch (vector) {
                vectors.divide_by_zero => handleException(trap_frame, .divide_by_zero, "Divide by zero."),
                vectors.debug_exception => arch.platform.writer().writeAll("Debug exception.\n") catch {},
                0x02...0x05 => {},
                vectors.invalid_opcode => handleException(trap_frame, .invalid_opcode, "Invalid opcode."),
                0x07 => {},
                vectors.double_fault => arch.platform.writer().writeAll("Double fault.\n") catch {},
                0x09 => {},
                vectors.invalid_tss => arch.platform.writer().writeAll("Invalid TSS.\n") catch {},
                0x0B => {},
                vectors.stack_segment_fault => arch.platform.writer().writeAll("Stack segment fault.\n") catch {},
                vectors.general_protection_fault => handleGeneralProtectionFault(trap_frame),
                vectors.page_fault => handlePageFault(trap_frame, diagnostic),
                0x0F, 0x10 => {},
                vectors.alignment_check => handleException(trap_frame, .alignment_check, "Alignment check."),
                0x12...0x1F => {},
                vectors.timer => {
                    handleTimer(diagnostic);
                    return true;
                },
                vectors.keyboard => handleKeyboard(diagnostic),
                0x22...0x7F => {},
                vectors.syscall => handleSyscall(trap_frame),
                else => {},
            }
            return false;
        }

        fn handleGeneralProtectionFault(trap_frame: *const TrapFrame) noreturn {
            const interrupted_frame = FrameAdapter.readInterruptedFrame(trap_frame);
            arch.platform.writer().writeAll("General protection fault.\n") catch {};
            arch.platform.writer().print(
                " EIP: 0x{x}, CS: 0x{x}, error: 0x{x}\n",
                .{
                    interrupted_frame.instruction_pointer,
                    interrupted_frame.code_selector,
                    interrupted_frame.error_code,
                },
            ) catch {};
            if (interrupted_frame.user_mode) {
                containUserFault(trap_frame, .{
                    .kind = .general_protection,
                    .instruction_pointer = interrupted_frame.instruction_pointer,
                    .architecture_error = interrupted_frame.error_code,
                });
            }
            @panic("kernel general protection fault");
        }

        fn handlePageFault(trap_frame: *const TrapFrame, diagnostic: diagnostics.Decision) void {
            const fault_info = FrameAdapter.readPageFaultInfo(trap_frame);
            if (diagnostic.print) {
                arch.platform.writer().print(
                    "Page fault address=0x{x} present={} write={} user={} execute={}\n",
                    .{
                        fault_info.address,
                        fault_info.present,
                        fault_info.write,
                        fault_info.user,
                        fault_info.instruction_fetch,
                    },
                ) catch {};
            }
            kernel_common.vmm.resolveFault(fault_info) catch |err| {
                if (FrameAdapter.isUserMode(trap_frame)) {
                    arch.platform.writer().print(
                        "Unresolved user page fault: {s}\n",
                        .{@errorName(err)},
                    ) catch {};
                    containUserFault(trap_frame, .{
                        .kind = .page_fault,
                        .instruction_pointer = FrameAdapter.instructionPointer(trap_frame),
                        .address = fault_info.address,
                        .architecture_error = FrameAdapter.errorCode(trap_frame),
                    });
                }
                kernel_common.vmm.faultHandler(fault_info);
            };
            if (diagnostic.print) {
                arch.platform.writer().writeAll("Page fault.\n") catch {};
            }
        }

        fn handleTimer(diagnostic: diagnostics.Decision) void {
            time.recordInterrupt();
            kernel_common.ipc.notification_operations.deliverInterrupt(.timer) catch |err| {
                arch.platform.writer().print(
                    "timer notification failed: {s}\n",
                    .{@errorName(err)},
                ) catch {};
                @panic("timer notification delivery failed");
            };
            if (diagnostic.print) {
                arch.platform.writer().print("Timer ({d} ticks).\n", .{diagnostic.count}) catch {};
            }
        }

        fn handleKeyboard(diagnostic: diagnostics.Decision) void {
            if (diagnostic.print) {
                arch.platform.writer().writeAll("Keyboard pressed.\n") catch {};
            }
            keyboard.clearKeyboard();
        }

        fn handleSyscall(trap_frame: *TrapFrame) void {
            const context_handle = beginSyscall(trap_frame);
            const result = kernel_common.syscall.dispatchFromCurrentContext(
                FrameAdapter.readSyscallRequest(trap_frame),
            );
            handleSyscallResult(context_handle, trap_frame, result);
        }

        fn beginSyscall(trap_frame: *TrapFrame) ?arch.ThreadContextHandle {
            const context_handle =
                kernel_common.process.scheduler.currentArchitectureContextHandle() catch |err| {
                    if (comptime @hasDecl(root, "architectureTestObserveException")) {
                        if (err == error.SchedulerUninitialized) return null;
                    }
                    arch.platform.writer().print(
                        "resolve syscall context failed: {s}\n",
                        .{@errorName(err)},
                    ) catch {};
                    @panic("syscall has no current architecture context");
                };
            arch.thread_context.beginSyscall(context_handle, @intFromPtr(trap_frame)) catch |err| {
                arch.platform.writer().print("begin syscall failed: {s}\n", .{@errorName(err)}) catch {};
                @panic("failed to retain syscall trap frame");
            };
            return context_handle;
        }

        fn handleSyscallResult(
            context_handle: ?arch.ThreadContextHandle,
            trap_frame: *TrapFrame,
            result: kernel_common.syscall.Result,
        ) void {
            switch (result) {
                .returned => |status| completeSyscall(context_handle, trap_frame, .fromStatus(status)),
                .returned_registers => |registers| completeSyscall(context_handle, trap_frame, registers),
                .blocked => {},
                .yield => {
                    kernel_common.process.scheduler.yieldCurrent() catch |err| {
                        arch.platform.writer().print("yield failed: {s}\n", .{@errorName(err)}) catch {};
                        @panic("cooperative scheduler yield failed");
                    };
                    completeSyscall(
                        context_handle,
                        trap_frame,
                        .fromStatus(abi.syscall.SYSCALL_SUCCESS),
                    );
                },
                .debug_write => |write| handleDebugWrite(context_handle, trap_frame, write),
                .exit => |exit| handleExit(exit.status),
                .failure => |failure_result| {
                    arch.platform.writer().print("{s} failed: {s}\n", .{
                        @tagName(failure_result.operation),
                        @errorName(failure_result.err),
                    }) catch {};
                    completeSyscall(
                        context_handle,
                        trap_frame,
                        .fromStatus(failure_result.return_value),
                    );
                },
            }
        }

        fn handleDebugWrite(
            context_handle: ?arch.ThreadContextHandle,
            trap_frame: *TrapFrame,
            write: anytype,
        ) void {
            var message: [kernel_common.user_memory.MAX_COPY_BYTES]u8 = undefined;
            kernel_common.user_memory.copyFromUser(&message, write.address, write.length) catch |err| {
                arch.platform.writer().print("debug_write failed: {s}\n", .{@errorName(err)}) catch {};
                completeSyscall(
                    context_handle,
                    trap_frame,
                    .fromStatus(abi.syscall.SYSCALL_FAILURE),
                );
                return;
            };
            arch.platform.writer().writeAll(message[0..@intCast(write.length)]) catch {};
            completeSyscall(
                context_handle,
                trap_frame,
                .fromStatus(abi.syscall.SYSCALL_SUCCESS),
            );
        }

        fn handleExit(status: u64) void {
            if (@hasDecl(root, "isRootThreadForSmoke") and root.isRootThreadForSmoke()) {
                arch.platform.writer().print(abi.system_smoke.EXIT_FORMAT, .{status}) catch {};
            }
            arch.platform.writer().print("User process exited with status {d}.\n", .{status}) catch {};
            kernel_common.process.lifecycle.exitCurrent(status) catch |err| {
                arch.platform.writer().print("thread exit failed: {s}\n", .{@errorName(err)}) catch {};
                @panic("current thread exit failed");
            };
        }

        fn completeSyscall(
            context_handle: ?arch.ThreadContextHandle,
            trap_frame: *TrapFrame,
            result: arch.SyscallResultRegisters,
        ) void {
            if (context_handle == null) {
                FrameAdapter.writeSyscallResult(trap_frame, result);
                return;
            }
            arch.thread_context.completeSyscall(context_handle.?, result) catch |err| {
                arch.platform.writer().print(
                    "complete syscall failed: {s}\n",
                    .{@errorName(err)},
                ) catch {};
                @panic("failed to write syscall result");
            };
        }

        fn handleException(
            trap_frame: *const TrapFrame,
            kind: kernel_common.process.thread.UserFaultKind,
            message: []const u8,
        ) noreturn {
            arch.platform.writer().print("{s}\n", .{message}) catch {};
            if (FrameAdapter.isUserMode(trap_frame)) {
                containUserFault(trap_frame, .{
                    .kind = kind,
                    .instruction_pointer = FrameAdapter.instructionPointer(trap_frame),
                    .architecture_error = FrameAdapter.errorCode(trap_frame),
                });
            }
            @panic(message);
        }

        fn containUserFault(
            trap_frame: *const TrapFrame,
            fault: kernel_common.process.thread.UserFault,
        ) void {
            kernel_common.process.lifecycle.faultCurrentFromFrame(
                fault,
                @intFromPtr(trap_frame),
            ) catch |err| {
                arch.platform.writer().print(
                    "user fault containment failed: {s}\n",
                    .{@errorName(err)},
                ) catch {};
                @panic("user fault containment failed");
            };
        }

        fn scheduleFromIdleIfReady() void {
            _ = kernel_common.process.scheduler.scheduleFromIdleIfReady() catch |err| {
                if (err != error.SchedulerUninitialized) {
                    arch.platform.writer().print(
                        "idle interrupt scheduling failed: {s}\n",
                        .{@errorName(err)},
                    ) catch {};
                    @panic("idle interrupt scheduling failed");
                }
            };
        }
    };
}

pub fn validateFrameAdapter(comptime Adapter: type) void {
    comptime {
        requireDeclaration(Adapter, "TrapFrame");
        const TrapFrame = Adapter.TrapFrame;
        requireFunction(Adapter, "fromStackPointer", fn (usize) *TrapFrame);
        requireFunction(Adapter, "errorCode", fn (*const TrapFrame) usize);
        requireFunction(Adapter, "instructionPointer", fn (*const TrapFrame) usize);
        requireFunction(Adapter, "readCr2", fn () usize);
        requireFunction(Adapter, "isUserMode", fn (*const TrapFrame) bool);
        requireFunction(Adapter, "readInterruptedFrame", fn (*const TrapFrame) InterruptedFrame);
        requireFunction(Adapter, "readPageFaultInfo", fn (*const TrapFrame) arch.FaultInfo);
        requireFunction(Adapter, "readSyscallRequest", fn (*const TrapFrame) kernel_common.syscall.Request);
        requireFunction(Adapter, "writeSyscallResult", fn (*TrapFrame, arch.SyscallResultRegisters) void);
    }
}

fn validateMechanisms(comptime Mechanisms: type) void {
    comptime {
        requireFunction(Mechanisms, "acknowledgeInterrupt", fn (usize) void);
    }
}

fn requireDeclaration(comptime Implementation: type, comptime name: []const u8) void {
    if (!@hasDecl(Implementation, name)) {
        @compileError(@typeName(Implementation) ++ " is missing declaration '" ++ name ++ "'");
    }
}

fn requireFunction(
    comptime Implementation: type,
    comptime name: []const u8,
    comptime Expected: type,
) void {
    requireDeclaration(Implementation, name);
    const Actual = @TypeOf(@field(Implementation, name));
    if (Actual != Expected) {
        @compileError(
            @typeName(Implementation) ++ "." ++ name ++ " has type " ++ @typeName(Actual) ++
                ", expected " ++ @typeName(Expected),
        );
    }
}
