//! Virtual-address map reserved for the kernel's first user process.

pub const RootProcessLayout = struct {
    pub const boot_info_start: u64 = 0x0010_0000;
    pub const boot_info_size: u64 = 0x1000;
    pub const boot_info_end: u64 = boot_info_start + boot_info_size;

    pub const initial_stack_committed_size: u64 = 0x0001_0000;
    pub const initial_stack_top: u64 = 0x00C0_0000;
    pub const initial_stack_start: u64 = initial_stack_top - initial_stack_committed_size;

    pub const boot_module_window_start: u64 = 0x0400_0000;
    pub const boot_module_window_end: u64 = 0x0800_0000;
};
