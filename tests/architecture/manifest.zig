pub const Architecture = enum {
    x86_32,
    x86_64,
};

pub const ExecutionMode = enum {
    shared_machine,
    isolated_machine,
    expected_fault,
};

pub const TestId = enum {
    page_size_is_four_kib,
    page_table_region_is_page_aligned,
    boot_memory_map_contains_available_memory,
    maximum_available_address_covers_available_regions,
    kernel_symbol_has_physical_mapping,
    x86_32_direct_map_uses_higher_half,
    x86_32_descriptor_tables_initialize,
    x86_64_kernel_uses_higher_half,
    x86_64_hhdm_is_page_aligned,
    x86_64_descriptor_tables_initialize,
    x86_64_address_space_root_can_be_created,
    x86_64_platform_console_initializes,
    x86_64_platform_timer_initializes,
};

pub const ExpectedFault = struct {
    vector: u8,
    error_code_mask: usize = 0,
    error_code_value: usize = 0,
    cr2: ?usize = null,
};

pub const Test = struct {
    id: TestId,
    name: []const u8,
    mode: ExecutionMode,
    architectures: []const Architecture,
    expected_fault: ?ExpectedFault = null,

    pub fn supports(self: Test, architecture: Architecture) bool {
        for (self.architectures) |supported| {
            if (supported == architecture) return true;
        }
        return false;
    }
};

const all_x86 = &[_]Architecture{ .x86_32, .x86_64 };
const only_x86_32 = &[_]Architecture{.x86_32};
const only_x86_64 = &[_]Architecture{.x86_64};

pub const tests = [_]Test{
    .{ .id = .page_size_is_four_kib, .name = "page size is 4 KiB", .mode = .shared_machine, .architectures = all_x86 },
    .{ .id = .page_table_region_is_page_aligned, .name = "page table region is page aligned", .mode = .shared_machine, .architectures = all_x86 },
    .{ .id = .boot_memory_map_contains_available_memory, .name = "boot memory map contains available memory", .mode = .shared_machine, .architectures = all_x86 },
    .{ .id = .maximum_available_address_covers_available_regions, .name = "maximum available address covers available regions", .mode = .shared_machine, .architectures = all_x86 },
    .{ .id = .kernel_symbol_has_physical_mapping, .name = "kernel symbol has a physical mapping", .mode = .shared_machine, .architectures = all_x86 },
    .{ .id = .x86_32_direct_map_uses_higher_half, .name = "x86-32 direct map uses higher half", .mode = .shared_machine, .architectures = only_x86_32 },
    .{ .id = .x86_32_descriptor_tables_initialize, .name = "x86-32 descriptor tables initialize", .mode = .isolated_machine, .architectures = only_x86_32 },
    .{ .id = .x86_64_kernel_uses_higher_half, .name = "x86-64 kernel uses higher half", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_hhdm_is_page_aligned, .name = "x86-64 HHDM is page aligned", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_descriptor_tables_initialize, .name = "x86-64 descriptor tables initialize", .mode = .isolated_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_address_space_root_can_be_created, .name = "x86-64 address-space root can be created", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_platform_console_initializes, .name = "x86-64 platform console initializes", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_platform_timer_initializes, .name = "x86-64 platform timer initializes", .mode = .isolated_machine, .architectures = only_x86_64 },
};

pub fn find(id: TestId) Test {
    for (tests) |test_case| {
        if (test_case.id == id) return test_case;
    }
    unreachable;
}
