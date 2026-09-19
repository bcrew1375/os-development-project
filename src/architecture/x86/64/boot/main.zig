const arch = @import("arch");

const gdt = @import("../interrupts/global_descriptor_table.zig");
const idt = @import("../interrupts/interrupt_descriptor_table.zig");
const cpu = @import("../cpu/main.zig");
const limine = @import("limine/main.zig");
const boot_modules = @import("../../common/boot/limine/boot_modules.zig");
const limine_requests = @import("../../common/boot/limine/requests.zig");

comptime {
    _ = limine_requests.requests_start_marker;
    _ = limine_requests.hhdm_request;
    _ = limine_requests.memory_map_request;
    _ = limine_requests.module_request;
    _ = limine_requests.framebuffer_request;
    _ = limine_requests.requests_end_marker;
    _ = limine._start;
}

pub const getBootModule = boot_modules.getBootModule;
pub const getBootModuleCount = boot_modules.getBootModuleCount;

extern fn kernelMain() void;

pub fn kernelSetup() noreturn {
    arch.early_allocator.initialize() catch |err| {
        @panic(@errorName(err));
    };

    boot_modules.reserveBootModules() catch |err| {
        @panic(@errorName(err));
    };

    boot_modules.cacheBootModules();
    kernelMain();

    arch.cpu.unrecoverableHalt();
    unreachable;
}

pub fn finishBoot() void {
    const kernel_stack_top = asm volatile ("mov %%rsp, %[stack_pointer]"
        : [stack_pointer] "=r" (-> usize),
    );

    cpu.initializeMemoryProtection();
    gdt.initialize(kernel_stack_top);
    idt.initialize();
}
