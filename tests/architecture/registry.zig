const builtin = @import("builtin");
const options = @import("architecture_test_options");
const std = @import("std");
const framework = @import("framework.zig");
pub const manifest = framework.manifest;
const common = @import("x86/common.zig");
const boot_modules = @import("x86/boot_modules.zig");
const faults = @import("x86/faults.zig");
const mmu = @import("x86/mmu.zig");
const syscalls = @import("x86/syscalls.zig");
const timer = @import("x86/timer.zig");
const x86_32 = @import("x86/x86_32.zig");
const x86_64 = @import("x86/x86_64.zig");

pub const architecture = switch (builtin.cpu.arch) {
    .x86 => manifest.Architecture.x86_32,
    .x86_64 => manifest.Architecture.x86_64,
    else => @compileError("unsupported QEMU test architecture"),
};

pub const architecture_name = @tagName(architecture);
pub const execution_mode = std.meta.stringToEnum(
    manifest.ExecutionMode,
    options.execution_mode,
) orelse @compileError("invalid architecture test execution mode");
pub const tests = buildSelectedTests();

fn selectedTestCount() comptime_int {
    var count = 0;
    for (manifest.tests) |test_case| {
        if (!test_case.supports(architecture)) continue;
        if (test_case.mode != execution_mode) continue;
        if (execution_mode != .shared_machine and
            !std.mem.eql(u8, @tagName(test_case.id), options.selected_test_id)) continue;
        count += 1;
    }
    return count;
}

fn buildSelectedTests() [selectedTestCount()]framework.TestCase {
    var selected: [selectedTestCount()]framework.TestCase = undefined;
    var index = 0;
    for (manifest.tests) |test_case| {
        if (!test_case.supports(architecture)) continue;
        if (test_case.mode != execution_mode) continue;
        if (execution_mode != .shared_machine and
            !std.mem.eql(u8, @tagName(test_case.id), options.selected_test_id)) continue;
        selected[index] = .{
            .id = test_case.id,
            .name = test_case.name,
            .mode = test_case.mode,
            .function = testFunction(test_case.id),
        };
        index += 1;
    }
    if (execution_mode != .shared_machine and selected.len != 1) {
        @compileError("isolated architecture test selection must resolve to exactly one test");
    }
    return selected;
}

fn testFunction(id: manifest.TestId) framework.TestFunction {
    return switch (id) {
        .page_size_is_four_kib => common.pageSizeIsFourKiB,
        .page_table_region_is_page_aligned => common.pageTableRegionIsAligned,
        .boot_memory_map_contains_available_memory => common.memoryMapContainsAvailableMemory,
        .maximum_available_address_covers_available_regions => common.maximumAddressCoversAvailableRegions,
        .kernel_symbol_has_physical_mapping => common.kernelSymbolHasPhysicalMapping,
        .x86_32_direct_map_uses_higher_half => x86_32.directMapUsesHigherHalf,
        .x86_32_descriptor_tables_initialize => x86_32.descriptorTablesInitialize,
        .x86_64_kernel_uses_higher_half => x86_64.kernelUsesHigherHalf,
        .x86_64_hhdm_is_page_aligned => x86_64.hhdmIsPageAligned,
        .x86_64_descriptor_tables_initialize => x86_64.descriptorTablesInitialize,
        .x86_32_address_space_root_can_be_created,
        .x86_64_address_space_root_can_be_created,
        => mmu.addressSpaceRootCanBeCreated,
        .mmu_explicit_root_mapping_translates => mmu.explicitRootMappingTranslates,
        .mmu_address_spaces_are_isolated_and_switchable => mmu.addressSpacesAreIsolatedAndSwitchable,
        .mmu_unmapping_is_idempotent => mmu.unmappingIsIdempotent,
        .mmu_effective_permissions_are_reported => mmu.effectivePermissionsAreReported,
        .mmu_allocator_exhaustion_is_bounded => mmu.allocatorExhaustionIsBounded,
        .page_fault_unmapped_read => faults.unmappedRead,
        .page_fault_unmapped_write => faults.unmappedWrite,
        .page_fault_write_protection => faults.writeProtectionViolation,
        .x86_32_page_fault_user_supervisor_instruction_fetch,
        .x86_64_page_fault_user_supervisor_instruction_fetch,
        => faults.userSupervisorInstructionFetch,
        .x86_64_page_fault_non_executable_instruction_fetch => faults.nonExecutableInstructionFetch,
        .invalid_opcode_fault => faults.invalidOpcode,
        .general_protection_from_user_interrupt => faults.generalProtectionFromUserInterrupt,
        .x86_64_platform_console_initializes => x86_64.platformConsoleInitializes,
        .x86_32_platform_timer_interrupts_are_delivered,
        .x86_64_platform_timer_initializes,
        => timer.interruptsAreDelivered,
        .boot_modules_are_cached_reserved_and_capacity_limited => boot_modules.areCachedReservedAndCapacityLimited,
        .syscall_interrupt_gate_preserves_register_abi => syscalls.interruptGatePreservesRegisterAbi,
    };
}
