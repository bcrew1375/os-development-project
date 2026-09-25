//! Bounded cooperative FIFO scheduler for architecture-neutral threads.

const arch = @import("arch");
const execution_context = @import("../execution_context.zig");
const thread = @import("../thread.zig");

pub const Error = error{
    SchedulerAlreadyInitialized,
    SchedulerUninitialized,
    ReadyQueueFull,
    ThreadAlreadyQueued,
    NoCurrentThread,
    CurrentThreadMismatch,
} || thread.Error || arch.ThreadContextError;

const ReadyQueue = struct {
    handles: [thread.MAX_THREADS]thread.Handle = undefined,
    head: usize = 0,
    length: usize = 0,

    fn contains(self: *const ReadyQueue, handle: thread.Handle) bool {
        for (0..self.length) |offset| {
            if (self.handles[(self.head + offset) % self.handles.len] == handle) return true;
        }
        return false;
    }

    fn push(self: *ReadyQueue, handle: thread.Handle) Error!void {
        if (self.contains(handle)) return error.ThreadAlreadyQueued;
        if (self.length == self.handles.len) return error.ReadyQueueFull;
        self.handles[(self.head + self.length) % self.handles.len] = handle;
        self.length += 1;
    }

    fn pop(self: *ReadyQueue) ?thread.Handle {
        if (self.length == 0) return null;
        const handle = self.handles[self.head];
        self.head = (self.head + 1) % self.handles.len;
        self.length -= 1;
        return handle;
    }
};

var ready_queue = ReadyQueue{};
var initialized = false;
var idle_context_handle = arch.INVALID_THREAD_CONTEXT_HANDLE;
var current_thread_handle: ?thread.Handle = null;
var current_architecture_context = arch.INVALID_THREAD_CONTEXT_HANDLE;

pub fn initialize(idle_address_space_root: arch.AddressSpaceRoot) Error!void {
    if (initialized) return error.SchedulerAlreadyInitialized;
    idle_context_handle = try arch.thread_context.createKernelContinuation(.{
        .address_space_root = idle_address_space_root,
        .entry = &idleMain,
    });
    ready_queue = .{};
    current_thread_handle = null;
    current_architecture_context = arch.INVALID_THREAD_CONTEXT_HANDLE;
    initialized = true;
}

pub fn makeReady(handle: thread.Handle) Error!void {
    try requireInitialized();
    if (ready_queue.contains(handle)) return error.ThreadAlreadyQueued;
    if (ready_queue.length == ready_queue.handles.len) return error.ReadyQueueFull;
    try thread.makeReady(handle);
    try ready_queue.push(handle);
}

pub fn start() noreturn {
    requireInitialized() catch @panic("scheduler is not initialized");
    const next_handle = ready_queue.pop() orelse {
        execution_context.clear();
        current_thread_handle = null;
        current_architecture_context = idle_context_handle;
        arch.thread_context.activate(idle_context_handle);
    };
    const next = thread.get(next_handle) catch @panic("ready queue contains an invalid thread");
    thread.startRunning(next_handle) catch @panic("ready queue contains a non-ready thread");
    installExecutionContext(next_handle, next);
    current_thread_handle = next_handle;
    current_architecture_context = next.architecture_context_handle;
    arch.thread_context.activate(next.architecture_context_handle);
}

pub fn yieldCurrent() Error!void {
    try requireInitialized();
    const current_handle = current_thread_handle orelse return error.NoCurrentThread;
    const current = try thread.get(current_handle);
    if (current.state != .running or current.architecture_context_handle != current_architecture_context) {
        return error.CurrentThreadMismatch;
    }
    if (ready_queue.contains(current_handle)) return error.ThreadAlreadyQueued;
    if (ready_queue.length == ready_queue.handles.len) return error.ReadyQueueFull;

    try thread.makeReady(current_handle);
    try ready_queue.push(current_handle);
    const next_handle = ready_queue.pop().?;
    const next = try thread.get(next_handle);
    try thread.startRunning(next_handle);
    installExecutionContext(next_handle, next);
    current_thread_handle = next_handle;
    current_architecture_context = next.architecture_context_handle;

    if (current_handle == next_handle) return;
    try arch.thread_context.switchContext(
        current.architecture_context_handle,
        next.architecture_context_handle,
    );
}

/// Selects another ready thread or idle after the caller has stopped the current thread.
pub fn scheduleAfterCurrentStops() Error!void {
    try requireInitialized();
    const current_handle = current_thread_handle orelse return error.NoCurrentThread;
    const current = try thread.get(current_handle);
    if (current.state == .running or current.architecture_context_handle != current_architecture_context) {
        return error.CurrentThreadMismatch;
    }

    if (ready_queue.pop()) |next_handle| {
        const next = try thread.get(next_handle);
        try thread.startRunning(next_handle);
        installExecutionContext(next_handle, next);
        current_thread_handle = next_handle;
        current_architecture_context = next.architecture_context_handle;
        try arch.thread_context.switchContext(
            current.architecture_context_handle,
            next.architecture_context_handle,
        );
        return;
    }

    execution_context.clear();
    current_thread_handle = null;
    current_architecture_context = idle_context_handle;
    try arch.thread_context.switchContext(current.architecture_context_handle, idle_context_handle);
}

pub fn readyCountForTest() usize {
    return ready_queue.length;
}

pub fn currentThreadForTest() ?thread.Handle {
    return current_thread_handle;
}

pub fn idleContextForTest() arch.ThreadContextHandle {
    return idle_context_handle;
}

pub fn setCurrentThreadForTest(handle: thread.Handle) Error!void {
    try requireInitialized();
    const object = try thread.get(handle);
    if (object.state != .running) return error.CurrentThreadMismatch;
    current_thread_handle = handle;
    current_architecture_context = object.architecture_context_handle;
    installExecutionContext(handle, object);
}

pub fn resetForTest() void {
    if (idle_context_handle != arch.INVALID_THREAD_CONTEXT_HANDLE) {
        arch.thread_context.destroy(idle_context_handle) catch {};
    }
    ready_queue = .{};
    initialized = false;
    idle_context_handle = arch.INVALID_THREAD_CONTEXT_HANDLE;
    current_thread_handle = null;
    current_architecture_context = arch.INVALID_THREAD_CONTEXT_HANDLE;
    execution_context.clear();
}

fn installExecutionContext(handle: thread.Handle, object: thread.Thread) void {
    execution_context.install(.{
        .thread_handle = handle,
        .capability_space_handle = object.capability_space_handle,
        .address_space_handle = object.address_space_handle,
        .process_handle = object.owner_process_handle,
    });
}

fn requireInitialized() error{SchedulerUninitialized}!void {
    if (!initialized) return error.SchedulerUninitialized;
}

fn idleMain() callconv(.c) noreturn {
    while (true) arch.cpu.waitForInterrupt();
}
