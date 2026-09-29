//! Bounded x86-64 saved contexts and per-thread kernel stacks.

const policy = @import("../../common/thread_context/policy.zig");
const adapter = @import("adapter.zig");

const Contexts = policy.ThreadContexts(adapter);

pub const MAX_CONTEXTS = policy.MAX_CONTEXTS;
pub const KERNEL_STACK_SIZE = Contexts.KERNEL_STACK_SIZE;
pub const KERNEL_STACK_ALIGNMENT = Contexts.KERNEL_STACK_ALIGNMENT;
pub const KERNEL_CONTEXT_HANDLE = policy.KERNEL_CONTEXT_HANDLE;
pub const InitialStateForTest = Contexts.InitialStateForTest;
pub const create = Contexts.create;
pub const createKernelContinuation = Contexts.createKernelContinuation;
pub const destroy = Contexts.destroy;
pub const activate = Contexts.activate;
pub const switchContext = Contexts.switchContext;
pub const beginSyscall = Contexts.beginSyscall;
pub const prepareSyscallCompletion = Contexts.prepareSyscallCompletion;
pub const completeSyscall = Contexts.completeSyscall;
pub const retainFaultFrame = Contexts.retainFaultFrame;
pub const setFaultInstructionPointer = Contexts.setFaultInstructionPointer;
pub const clearFaultFrame = Contexts.clearFaultFrame;
pub const availableCount = Contexts.availableCount;
pub const getKernelStackBoundsForTest = Contexts.getKernelStackBoundsForTest;
pub const getInitialStateForTest = Contexts.getInitialStateForTest;
pub const getInitialTrapFrameAddressForTest = Contexts.getInitialTrapFrameAddressForTest;
pub const getSyscallResultForTest = Contexts.getSyscallResultForTest;
pub const prepareKernelContinuationForTest = Contexts.prepareKernelContinuationForTest;
pub const bindCurrentForTest = Contexts.bindCurrentForTest;
pub const getCurrentAddressSpaceRootForTest = Contexts.getCurrentAddressSpaceRootForTest;
pub const getPrivilegeStackForTest = Contexts.getPrivilegeStackForTest;
