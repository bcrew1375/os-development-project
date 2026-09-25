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
    x86_32_address_space_root_can_be_created,
    x86_64_address_space_root_can_be_created,
    mmu_explicit_root_mapping_translates,
    mmu_address_spaces_are_isolated_and_switchable,
    mmu_unmapping_is_idempotent,
    mmu_effective_permissions_are_reported,
    mmu_allocator_exhaustion_is_bounded,
    page_fault_unmapped_read,
    page_fault_unmapped_write,
    page_fault_write_protection,
    x86_32_page_fault_user_supervisor_instruction_fetch,
    x86_64_page_fault_user_supervisor_instruction_fetch,
    x86_64_page_fault_non_executable_instruction_fetch,
    invalid_opcode_fault,
    general_protection_from_user_interrupt,
    x86_64_platform_console_initializes,
    x86_32_platform_timer_interrupts_are_delivered,
    x86_64_platform_timer_initializes,
    boot_modules_are_cached_reserved_and_capacity_limited,
    syscall_interrupt_gate_preserves_register_abi,
    user_invalid_opcode_fault_is_contained,
    thread_context_initial_state_uses_bounded_kernel_stack,
    thread_context_switch_round_trip_restores_architecture_state,
    kernel_continuation_switch_round_trip_restores_architecture_state,
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
    .{ .id = .thread_context_initial_state_uses_bounded_kernel_stack, .name = "thread context initial state uses bounded kernel stack", .mode = .shared_machine, .architectures = all_x86 },
    .{ .id = .x86_32_direct_map_uses_higher_half, .name = "x86-32 direct map uses higher half", .mode = .shared_machine, .architectures = only_x86_32 },
    .{ .id = .x86_32_descriptor_tables_initialize, .name = "x86-32 descriptor tables initialize", .mode = .shared_machine, .architectures = only_x86_32 },
    .{ .id = .x86_64_kernel_uses_higher_half, .name = "x86-64 kernel uses higher half", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_hhdm_is_page_aligned, .name = "x86-64 HHDM is page aligned", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_32_address_space_root_can_be_created, .name = "x86-32 address-space root can be created", .mode = .isolated_machine, .architectures = only_x86_32 },
    .{ .id = .x86_64_address_space_root_can_be_created, .name = "x86-64 address-space root can be created", .mode = .isolated_machine, .architectures = only_x86_64 },
    .{ .id = .mmu_explicit_root_mapping_translates, .name = "MMU explicit-root mapping translates", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .mmu_address_spaces_are_isolated_and_switchable, .name = "MMU address spaces are isolated and switchable", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .mmu_unmapping_is_idempotent, .name = "MMU unmapping is idempotent", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .mmu_effective_permissions_are_reported, .name = "MMU effective permissions are reported", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .mmu_allocator_exhaustion_is_bounded, .name = "MMU allocator exhaustion is bounded", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .page_fault_unmapped_read, .name = "unmapped read raises a page fault", .mode = .expected_fault, .architectures = all_x86, .expected_fault = .{ .vector = 14, .error_code_mask = 0x0f, .error_code_value = 0, .cr2 = 0x0040_0000 } },
    .{ .id = .page_fault_unmapped_write, .name = "unmapped write raises a page fault", .mode = .expected_fault, .architectures = all_x86, .expected_fault = .{ .vector = 14, .error_code_mask = 0x0f, .error_code_value = 0x02, .cr2 = 0x0040_0000 } },
    .{ .id = .page_fault_write_protection, .name = "read-only write raises a page fault", .mode = .expected_fault, .architectures = all_x86, .expected_fault = .{ .vector = 14, .error_code_mask = 0x0f, .error_code_value = 0x03, .cr2 = 0x0040_0000 } },
    .{ .id = .x86_32_page_fault_user_supervisor_instruction_fetch, .name = "x86-32 user fetch from supervisor page raises a page fault", .mode = .expected_fault, .architectures = only_x86_32, .expected_fault = .{ .vector = 14, .error_code_mask = 0x07, .error_code_value = 0x05, .cr2 = 0x0040_0000 } },
    .{ .id = .x86_64_page_fault_user_supervisor_instruction_fetch, .name = "x86-64 user fetch from supervisor page raises a page fault", .mode = .expected_fault, .architectures = only_x86_64, .expected_fault = .{ .vector = 14, .error_code_mask = 0x17, .error_code_value = 0x15, .cr2 = 0x0040_0000 } },
    .{ .id = .x86_64_page_fault_non_executable_instruction_fetch, .name = "non-executable page raises a page fault", .mode = .expected_fault, .architectures = only_x86_64, .expected_fault = .{ .vector = 14, .error_code_mask = 0x1f, .error_code_value = 0x11, .cr2 = 0x0040_0000 } },
    .{ .id = .invalid_opcode_fault, .name = "invalid opcode raises an exception", .mode = .expected_fault, .architectures = all_x86, .expected_fault = .{ .vector = 6, .error_code_mask = 0xffff, .error_code_value = 0 } },
    .{ .id = .general_protection_from_user_interrupt, .name = "user interrupt to a privileged gate raises general protection", .mode = .expected_fault, .architectures = all_x86, .expected_fault = .{ .vector = 13, .error_code_mask = 0xffff, .error_code_value = 0x0102 } },
    .{ .id = .x86_64_platform_console_initializes, .name = "x86-64 platform console initializes", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_64_descriptor_tables_initialize, .name = "x86-64 descriptor tables initialize", .mode = .shared_machine, .architectures = only_x86_64 },
    .{ .id = .x86_32_platform_timer_interrupts_are_delivered, .name = "x86-32 timer interrupts are delivered", .mode = .isolated_machine, .architectures = only_x86_32 },
    .{ .id = .x86_64_platform_timer_initializes, .name = "x86-64 timer interrupts are delivered", .mode = .isolated_machine, .architectures = only_x86_64 },
    .{ .id = .boot_modules_are_cached_reserved_and_capacity_limited, .name = "boot modules are cached, reserved, and capacity limited", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .syscall_interrupt_gate_preserves_register_abi, .name = "syscall interrupt gate preserves register ABI", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .user_invalid_opcode_fault_is_contained, .name = "user invalid opcode faults only the responsible thread", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .thread_context_switch_round_trip_restores_architecture_state, .name = "thread context switch round trip restores architecture state", .mode = .isolated_machine, .architectures = all_x86 },
    .{ .id = .kernel_continuation_switch_round_trip_restores_architecture_state, .name = "kernel continuation switch round trip restores architecture state", .mode = .isolated_machine, .architectures = all_x86 },
};

pub fn find(id: TestId) Test {
    for (tests) |test_case| {
        if (test_case.id == id) return test_case;
    }
    unreachable;
}
