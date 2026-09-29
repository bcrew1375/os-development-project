//! Shared generation-checked x86 thread-context lifecycle policy.

const arch = @import("arch");
const std = @import("std");

pub const MAX_CONTEXTS: usize = 32;
pub const KERNEL_CONTEXT_HANDLE: arch.ThreadContextHandle = 0x8000_0001;

const HANDLE_SLOT_BITS: u32 = 5;
const MAX_SLOT_INDEX: u32 = (@as(u32, 1) << HANDLE_SLOT_BITS) - 1;
const MAX_GENERATION: u32 = (@as(u32, 1) << (31 - HANDLE_SLOT_BITS)) - 1;

pub fn ThreadContexts(comptime Adapter: type) type {
    validateAdapter(Adapter);
    const TrapFrame = Adapter.TrapFrame;

    return struct {
        pub const KERNEL_STACK_SIZE = Adapter.KERNEL_STACK_SIZE;
        pub const KERNEL_STACK_ALIGNMENT = Adapter.KERNEL_STACK_ALIGNMENT;
        pub const InitialStateForTest = Adapter.InitialStateForTest;

        const Slot = struct {
            generation: u32 = 1,
            saved_stack_pointer: usize = 0,
            address_space_root: arch.AddressSpaceRoot = .{ .value = 0 },
            pending_syscall_frame: ?*TrapFrame = null,
            retained_fault_frame: ?*TrapFrame = null,
            used: bool = false,
            active: bool = false,
            retired: bool = false,
        };

        var slots: [MAX_CONTEXTS]Slot = [_]Slot{.{}} ** MAX_CONTEXTS;
        var kernel_continuation_slot = Slot{};
        var current_handle: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;

        pub fn create(
            configuration: arch.ThreadContextConfiguration,
        ) arch.ThreadContextError!arch.ThreadContextHandle {
            if (configuration.address_space_root.value == 0) return error.InvalidAddressSpaceRoot;
            try Adapter.validateConfiguration(configuration);

            const slot_index = findFreeSlot() orelse return error.OutOfThreadContexts;
            const slot = &slots[slot_index];
            slot.used = true;
            slot.active = false;
            slot.address_space_root = configuration.address_space_root;
            slot.saved_stack_pointer = Adapter.initializeStack(slot_index, configuration);
            return makeHandle(slot_index, slot.generation);
        }

        pub fn createKernelContinuation(
            configuration: arch.KernelContinuationConfiguration,
        ) arch.ThreadContextError!arch.ThreadContextHandle {
            if (configuration.address_space_root.value == 0) return error.InvalidAddressSpaceRoot;
            if (kernel_continuation_slot.used) return error.KernelContinuationAlreadyExists;

            kernel_continuation_slot = .{
                .saved_stack_pointer = Adapter.initializeKernelContinuationStack(
                    configuration.entry,
                ),
                .address_space_root = configuration.address_space_root,
                .used = true,
            };
            return KERNEL_CONTEXT_HANDLE;
        }

        pub fn destroy(handle: arch.ThreadContextHandle) arch.ThreadContextError!void {
            if (handle == KERNEL_CONTEXT_HANDLE) {
                if (!kernel_continuation_slot.used) return error.InvalidThreadContextHandle;
                if (kernel_continuation_slot.active or current_handle == handle) {
                    return error.ThreadContextInUse;
                }
                kernel_continuation_slot = .{};
                return;
            }
            const slot = try resolveMutableSlot(handle);
            if (slot.active or current_handle == handle) return error.ThreadContextInUse;

            slot.used = false;
            slot.saved_stack_pointer = 0;
            slot.address_space_root = .{ .value = 0 };
            slot.pending_syscall_frame = null;
            slot.retained_fault_frame = null;
            if (slot.generation == MAX_GENERATION) {
                slot.retired = true;
            } else {
                slot.generation += 1;
            }
        }

        pub fn activate(handle: arch.ThreadContextHandle) noreturn {
            const slot = resolveContextMutable(handle) catch Adapter.panicInvalidActivation();
            if (current_handle != arch.INVALID_THREAD_CONTEXT_HANDLE) {
                Adapter.panicContextAlreadyActive();
            }
            current_handle = handle;
            slot.active = true;
            arch.mmu.switchAddressSpaceRoot(slot.address_space_root);
            Adapter.setPrivilegeStack(contextKernelStackTop(handle));
            Adapter.activateKernelStack(slot.saved_stack_pointer);
        }

        pub fn switchContext(
            current: arch.ThreadContextHandle,
            next: arch.ThreadContextHandle,
        ) arch.ThreadContextError!void {
            const current_slot = try resolveContextMutable(current);
            if (current_handle != current or !current_slot.active) {
                return error.InvalidThreadContextHandle;
            }
            if (current == next) return;
            const next_slot = try resolveContextMutable(next);

            current_slot.active = false;
            next_slot.active = true;
            current_handle = next;
            arch.mmu.switchAddressSpaceRoot(next_slot.address_space_root);
            Adapter.setPrivilegeStack(contextKernelStackTop(next));
            Adapter.switchKernelStack(
                &current_slot.saved_stack_pointer,
                next_slot.saved_stack_pointer,
            );
        }

        pub fn beginSyscall(
            handle: arch.ThreadContextHandle,
            trap_frame_address: usize,
        ) arch.ThreadContextError!void {
            const slot = try resolveMutableSlot(handle);
            if (slot.pending_syscall_frame != null) return error.SyscallAlreadyPending;
            if (!isKernelStackRange(handle, trap_frame_address, @sizeOf(TrapFrame))) {
                return error.InvalidSyscallFrame;
            }
            slot.pending_syscall_frame = @ptrFromInt(trap_frame_address);
        }

        pub fn prepareSyscallCompletion(
            handle: arch.ThreadContextHandle,
        ) arch.ThreadContextError!void {
            const slot = try resolveSlot(handle);
            if (slot.pending_syscall_frame == null) return error.NoPendingSyscall;
        }

        pub fn completeSyscall(
            handle: arch.ThreadContextHandle,
            result: arch.SyscallResultRegisters,
        ) arch.ThreadContextError!void {
            const slot = try resolveMutableSlot(handle);
            const trap_frame = slot.pending_syscall_frame orelse return error.NoPendingSyscall;
            Adapter.writeSyscallResult(trap_frame, result);
            slot.pending_syscall_frame = null;
        }

        pub fn retainFaultFrame(
            handle: arch.ThreadContextHandle,
            trap_frame_address: usize,
            instruction_pointer: u64,
        ) arch.ThreadContextError!void {
            if (!Adapter.isValidUserInstructionPointer(instruction_pointer)) {
                return error.InvalidInstructionPointer;
            }
            const slot = try resolveMutableSlot(handle);
            if (slot.retained_fault_frame != null) return error.FaultFrameAlreadyRetained;
            if (!isKernelStackRange(handle, trap_frame_address, @sizeOf(TrapFrame))) {
                return error.InvalidFaultFrame;
            }
            const trap_frame: *TrapFrame = @ptrFromInt(trap_frame_address);
            if (!Adapter.hasInstructionPointer(trap_frame, instruction_pointer)) {
                return error.InvalidFaultFrame;
            }
            slot.retained_fault_frame = trap_frame;
        }

        pub fn setFaultInstructionPointer(
            handle: arch.ThreadContextHandle,
            instruction_pointer: u64,
        ) arch.ThreadContextError!void {
            if (!Adapter.isValidUserInstructionPointer(instruction_pointer)) {
                return error.InvalidInstructionPointer;
            }
            const slot = try resolveMutableSlot(handle);
            const trap_frame = slot.retained_fault_frame orelse return error.NoRetainedFaultFrame;
            Adapter.setInstructionPointer(trap_frame, instruction_pointer);
        }

        pub fn clearFaultFrame(handle: arch.ThreadContextHandle) arch.ThreadContextError!void {
            const slot = try resolveMutableSlot(handle);
            if (slot.retained_fault_frame == null) return error.NoRetainedFaultFrame;
            slot.retained_fault_frame = null;
        }

        pub fn availableCount() usize {
            var count: usize = 0;
            for (slots) |slot| {
                if (!slot.used and !slot.retired) count += 1;
            }
            return count;
        }

        pub fn getKernelStackBoundsForTest(
            handle: arch.ThreadContextHandle,
        ) arch.ThreadContextError!Adapter.StackBounds {
            _ = try resolveSlot(handle);
            return Adapter.kernelStackBounds(handleSlotIndex(handle).?);
        }

        pub fn getInitialStateForTest(
            handle: arch.ThreadContextHandle,
        ) arch.ThreadContextError!InitialStateForTest {
            const slot = try resolveSlot(handle);
            return Adapter.readInitialState(slot.saved_stack_pointer);
        }

        pub fn getInitialTrapFrameAddressForTest(
            handle: arch.ThreadContextHandle,
        ) arch.ThreadContextError!usize {
            const slot = try resolveSlot(handle);
            return Adapter.initialTrapFrameAddress(slot.saved_stack_pointer);
        }

        pub fn getSyscallResultForTest(
            handle: arch.ThreadContextHandle,
            trap_frame_address: usize,
        ) arch.ThreadContextError!arch.SyscallResultRegisters {
            _ = try resolveSlot(handle);
            if (!isKernelStackRange(handle, trap_frame_address, @sizeOf(TrapFrame))) {
                return error.InvalidSyscallFrame;
            }
            return Adapter.readSyscallResult(@ptrFromInt(trap_frame_address));
        }

        pub fn prepareKernelContinuationForTest(
            handle: arch.ThreadContextHandle,
            entry: *const fn () callconv(.c) noreturn,
        ) arch.ThreadContextError!void {
            const slot_index = handleSlotIndex(handle) orelse {
                return error.InvalidThreadContextHandle;
            };
            const slot = try resolveMutableSlot(handle);
            slot.saved_stack_pointer = Adapter.initializeThreadContinuationStack(
                slot_index,
                entry,
            );
        }

        pub fn bindCurrentForTest(handle: arch.ThreadContextHandle) arch.ThreadContextError!void {
            const slot = try resolveMutableSlot(handle);
            if (current_handle != arch.INVALID_THREAD_CONTEXT_HANDLE) {
                return error.ThreadContextInUse;
            }
            current_handle = handle;
            slot.active = true;
            Adapter.setPrivilegeStack(Adapter.kernelStackTop(handleSlotIndex(handle).?));
        }

        pub const getCurrentAddressSpaceRootForTest =
            Adapter.getCurrentAddressSpaceRootForTest;
        pub const getPrivilegeStackForTest = Adapter.getPrivilegeStackForTest;

        fn contextKernelStackTop(handle: arch.ThreadContextHandle) usize {
            if (handle == KERNEL_CONTEXT_HANDLE) return Adapter.kernelContinuationStackTop();
            return Adapter.kernelStackTop(handleSlotIndex(handle).?);
        }

        fn isKernelStackRange(
            handle: arch.ThreadContextHandle,
            address: usize,
            size: usize,
        ) bool {
            if (handle == KERNEL_CONTEXT_HANDLE) return false;
            const slot_index = handleSlotIndex(handle) orelse return false;
            const bounds = Adapter.kernelStackBounds(slot_index);
            return address >= bounds.start and
                address <= bounds.end and
                size <= bounds.end - address;
        }

        fn resolveContextMutable(
            handle: arch.ThreadContextHandle,
        ) arch.ThreadContextError!*Slot {
            if (handle == KERNEL_CONTEXT_HANDLE) {
                if (!kernel_continuation_slot.used) return error.InvalidThreadContextHandle;
                return &kernel_continuation_slot;
            }
            return resolveMutableSlot(handle);
        }

        fn resolveSlot(handle: arch.ThreadContextHandle) arch.ThreadContextError!*const Slot {
            const slot_index = handleSlotIndex(handle) orelse {
                return error.InvalidThreadContextHandle;
            };
            const generation = handle >> HANDLE_SLOT_BITS;
            const slot = &slots[slot_index];
            if (!slot.used or slot.generation != generation) {
                return error.InvalidThreadContextHandle;
            }
            return slot;
        }

        fn resolveMutableSlot(handle: arch.ThreadContextHandle) arch.ThreadContextError!*Slot {
            return @constCast(try resolveSlot(handle));
        }

        fn findFreeSlot() ?usize {
            for (slots, 0..) |slot, index| {
                if (!slot.used and !slot.retired) return index;
            }
            return null;
        }

        fn makeHandle(slot_index: usize, generation: u32) arch.ThreadContextHandle {
            return (generation << HANDLE_SLOT_BITS) | @as(u32, @intCast(slot_index));
        }

        fn handleSlotIndex(handle: arch.ThreadContextHandle) ?usize {
            if (handle == arch.INVALID_THREAD_CONTEXT_HANDLE) return null;
            const generation = handle >> HANDLE_SLOT_BITS;
            if (generation == 0) return null;
            const slot_index: usize = @intCast(handle & MAX_SLOT_INDEX);
            if (slot_index >= slots.len) return null;
            return slot_index;
        }
    };
}

fn validateAdapter(comptime Adapter: type) void {
    const required_declarations = .{
        "TrapFrame",
        "StackBounds",
        "KERNEL_STACK_SIZE",
        "KERNEL_STACK_ALIGNMENT",
        "KERNEL_STACK_COUNT",
        "InitialStateForTest",
        "validateConfiguration",
        "initializeStack",
        "initializeKernelContinuationStack",
        "initializeThreadContinuationStack",
        "activateKernelStack",
        "switchKernelStack",
        "setPrivilegeStack",
        "kernelStackTop",
        "kernelContinuationStackTop",
        "kernelStackBounds",
        "writeSyscallResult",
        "readSyscallResult",
        "isValidUserInstructionPointer",
        "hasInstructionPointer",
        "setInstructionPointer",
        "readInitialState",
        "initialTrapFrameAddress",
        "getCurrentAddressSpaceRootForTest",
        "getPrivilegeStackForTest",
        "panicInvalidActivation",
        "panicContextAlreadyActive",
    };
    inline for (required_declarations) |name| {
        if (!@hasDecl(Adapter, name)) {
            @compileError(@typeName(Adapter) ++ " is missing declaration '" ++ name ++ "'");
        }
    }
    std.debug.assert(Adapter.KERNEL_STACK_COUNT == MAX_CONTEXTS);
    std.debug.assert(MAX_CONTEXTS == MAX_SLOT_INDEX + 1);
}
