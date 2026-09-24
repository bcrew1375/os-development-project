//! Root-task-owned physical-memory policy and kernel memory-operation wrappers.

pub const bootstrap = @import("bootstrap.zig");
pub const Heap = @import("Heap.zig");
pub const operations = @import("operations.zig");
pub const PhysicalRangeAllocator = @import("PhysicalRangeAllocator.zig");
const root_task_heap = @import("RootTaskHeap.zig");
pub const ROOT_HEAP_PAGE_SIZE = root_task_heap.PAGE_SIZE;
pub const RootTaskHeap = root_task_heap.RootTaskHeap;
