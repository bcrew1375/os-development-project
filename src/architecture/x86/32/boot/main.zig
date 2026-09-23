const arch = @import("arch");
const build_options = @import("build_options");

const gdt = @import("../interrupts/global_descriptor_table.zig");
const idt = @import("../interrupts/interrupt_descriptor_table.zig");
const mmu = @import("../mmu/main.zig");
const multiboot = @import("multiboot/main.zig");
const multiboot_modules = @import("multiboot/boot_modules.zig");

comptime {
    _ = multiboot.multiboot_header;
    _ = multiboot._start;
}

pub const getBootModule = multiboot_modules.getBootModule;
pub const getBootModuleCount = multiboot_modules.getBootModuleCount;

const boot_text_section = ".multiboot.text";

var kernelStack: [16 * 1024]u8 align(16) linksection(".bss") = undefined;

extern fn kernelMain() void;

pub fn kernelSetup() linksection(boot_text_section) noreturn {
    arch.early_allocator.initialize() catch |err| {
        @panic(@errorName(err));
    };

    multiboot_modules.reserveBootModules() catch |err| {
        @panic(@errorName(err));
    };

    mmu.initializePaging() catch |err| {
        @panic(@errorName(err));
    };

    asm volatile (
        \\jmp %[higherHalfEntry:P]
        :
        : [higherHalfEntry] "i" (&higherHalfEntry),
    );

    unreachable;
}

fn higherHalfEntry() noreturn {
    @disableInstrumentation();
    asm volatile (
        \\mov %[kernelStack], %esp
        :
        : [kernelStack] "i" (@as([*]u8, &kernelStack) + kernelStack.len),
        : .{
          .ebx = true,
          .esp = true,
        });

    higherHalfRuntime();
}

noinline fn higherHalfRuntime() noreturn {
    multiboot_modules.cacheBootModules();
    kernelMain();

    arch.cpu.unrecoverableHalt();
    unreachable;
}

pub fn finishBoot() void {
    gdt.initialize(@intFromPtr(@as([*]u8, &kernelStack) + kernelStack.len));
    idt.initialize();
}
