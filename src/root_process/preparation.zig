//! Preparation of the root process as a single ownership transaction.
//!
//! `PreparationTransaction` exists so that exactly one place owns each
//! unpublished resource during preparation and rollback order is local to the
//! transaction. Transitioning a resource from raw to published form clears the
//! previous field, so rollback destroys whichever form is currently owned.

const arch = @import("arch");
const abi = @import("abi");
const kernel_common = @import("kernel_common");

const boot_info = @import("boot_info.zig");
const boot_modules = @import("boot_modules.zig");
const executable_loading = @import("executable_loading.zig");
const initial_stack = @import("initial_stack.zig");
const layout = @import("layout.zig");

const RootProcessLayout = layout.RootProcessLayout;
const vmm = kernel_common.memory_management.virtual_memory;

pub const PreparedRootProcess = struct {
    address_space_handle: kernel_common.process.AddressSpaceHandle,
    address_space_capability: abi.capability.CapabilityHandle,
    address_space_root: arch.AddressSpaceRoot,
    entry_point: usize,
    initial_stack_pointer: usize,
    thread_handle: kernel_common.process.thread.Handle,
};

const PreparationTransaction = struct {
    raw_address_space_root: ?arch.AddressSpaceRoot = null,
    address_space_capability: ?abi.capability.CapabilityHandle = null,
    delegated_boot_info: boot_info.DelegatedBootInfo = .{},
    thread_handle: ?kernel_common.process.thread.Handle = null,

    fn rollback(self: *PreparationTransaction) void {
        if (self.thread_handle) |thread_handle| {
            kernel_common.process.thread.destroy(thread_handle) catch {};
            self.thread_handle = null;
        }
        boot_info.rollbackDelegatedBootInfo(self.delegated_boot_info);
        self.delegated_boot_info = .{};
        if (self.address_space_capability) |address_space_capability| {
            kernel_common.capability.destroyAddressSpaceCapability(
                kernel_common.process.ROOT_PROCESS_HANDLE,
                address_space_capability,
            ) catch {};
            self.address_space_capability = null;
        } else if (self.raw_address_space_root) |address_space_root| {
            arch.mmu.destroyAddressSpaceRoot(address_space_root);
            self.raw_address_space_root = null;
        }
    }

    fn commit(
        self: *PreparationTransaction,
        address_space_handle: kernel_common.process.AddressSpaceHandle,
        address_space_root: arch.AddressSpaceRoot,
        entry_point: usize,
        initial_stack_pointer: usize,
    ) PreparedRootProcess {
        const address_space_capability = self.address_space_capability.?;
        const thread_handle = self.thread_handle.?;
        self.address_space_capability = null;
        self.delegated_boot_info = .{};
        self.thread_handle = null;
        return .{
            .address_space_handle = address_space_handle,
            .address_space_capability = address_space_capability,
            .address_space_root = address_space_root,
            .entry_point = entry_point,
            .initial_stack_pointer = initial_stack_pointer,
            .thread_handle = thread_handle,
        };
    }
};

pub fn prepareRootProcess() !PreparedRootProcess {
    var transaction = PreparationTransaction{};
    errdefer transaction.rollback();

    const page_table_root = try arch.mmu.createAddressSpaceRoot();
    transaction.raw_address_space_root = page_table_root;
    const address_space_capability = try kernel_common.capability.registerAddressSpaceRootCapability(
        kernel_common.process.ROOT_PROCESS_HANDLE,
        page_table_root,
    );
    transaction.raw_address_space_root = null;
    transaction.address_space_capability = address_space_capability;
    const address_space_handle = try kernel_common.capability.resolveAddressSpace(
        kernel_common.process.ROOT_PROCESS_HANDLE,
        address_space_capability,
        .{ .manage = true },
    );
    const address_space = try kernel_common.process.getAddressSpace(address_space_handle);
    activateAsCurrentBootstrapAddressSpace(address_space);

    const root_module = try boot_modules.getRootProcessModule();
    const entry_point = try executable_loading.loadRootProcessElf(page_table_root, address_space, root_module);

    try initial_stack.mapInitialUserStack(page_table_root, address_space);
    const mapped_modules = try boot_modules.mapNonRootBootModules(page_table_root, address_space);
    const delegated_boot_info = try boot_info.mapAndWriteBootInfoPage(
        page_table_root,
        address_space,
        mapped_modules,
    );
    transaction.delegated_boot_info = delegated_boot_info;
    const initial_stack_pointer = try initial_stack.writeInitialCallFrame(
        page_table_root,
        RootProcessLayout.initial_stack_top,
        RootProcessLayout.boot_info_start,
    );
    const thread_handle = try kernel_common.process.createThread(
        kernel_common.process.ROOT_PROCESS_HANDLE,
    );
    transaction.thread_handle = thread_handle;
    try kernel_common.process.configureThread(thread_handle, .{
        .capability_space_handle = kernel_common.process.capability_spaces.ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space_handle,
        .entry_point = entry_point,
        .stack_pointer = initial_stack_pointer,
        .argument = RootProcessLayout.boot_info_start,
    });

    return transaction.commit(
        address_space_handle,
        page_table_root,
        entry_point,
        initial_stack_pointer,
    );
}

/// `vmm`'s bootstrap-mapping calls (mapBootstrapContiguousInAddressSpace,
/// protectInAddressSpace, ...) act on whichever address space was last
/// activated here, rather than taking it as an explicit parameter.
fn activateAsCurrentBootstrapAddressSpace(address_space: *vmm.AddressSpace) void {
    vmm.setAddressSpace(address_space);
}
