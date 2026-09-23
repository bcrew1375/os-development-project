ENTRY(_start)
OUTPUT_FORMAT(elf32-i386)

KERNEL_VIRTUAL_ADDRESS = 0xC0000000;

SECTIONS
{
    . = 1M;
	_kernel_start = .;

	.multiboot.header ALIGN(4): AT (ADDR (.multiboot.header)) {
		_multiboot_header_start = .;
		KEEP(*(.multiboot.header .multiboot.header.*))
		_multiboot_header_end = .;
	}
	.multiboot.text ALIGN (4K) : AT (ADDR (.multiboot.text)) {
		_multiboot_text_start = .;
		*(.text.memset .text.memset.*)
		*(.text.memcpy .text.memcpy.*)
		*(.text.memmove .text.memmove.*)
		*(.multiboot.text .multiboot.text.*)
		_multiboot_text_end = .;
	}
	.multiboot.rodata ALIGN (4K) : AT (ADDR (.multiboot.rodata)) {
		_multiboot_rodata_start = .;
		*(.multiboot.rodata .multiboot.rodata.*)
		_multiboot_rodata_end = .;
	}
	.multiboot.data ALIGN (4K) : AT (ADDR (.multiboot.data)) {
		_multiboot_data_start = .;
		*(.multiboot.data .multiboot.data.*)
		. = ALIGN(4);
		__start___sancov_guards = .;
		KEEP(*(__sancov_guards))
		__stop___sancov_guards = .;
		_multiboot_data_end = .;
	}
	.multiboot.bss ALIGN (4K) : AT (ADDR (.multiboot.bss)) {
		_multiboot_bss_start = .;
		*(.multiboot.bss .multiboot.bss.*)
		_multiboot_bss_end = .;
	}

	. += KERNEL_VIRTUAL_ADDRESS;

	.text ALIGN (4K) : AT (ADDR (.text) - KERNEL_VIRTUAL_ADDRESS) {
		_text_start = . - KERNEL_VIRTUAL_ADDRESS;
		*(.text .text.*)
		_text_end = . - KERNEL_VIRTUAL_ADDRESS;
	}
	.rodata ALIGN (4K) : AT (ADDR (.rodata) - KERNEL_VIRTUAL_ADDRESS) {
		_rodata_start = . - KERNEL_VIRTUAL_ADDRESS;
		*(.rodata .rodata.*)
		_rodata_end = . - KERNEL_VIRTUAL_ADDRESS;
	}
	.data ALIGN (4K) : AT (ADDR (.data) - KERNEL_VIRTUAL_ADDRESS) {
		_data_start = . - KERNEL_VIRTUAL_ADDRESS;
		*(.data .data.*)
		_data_end = . - KERNEL_VIRTUAL_ADDRESS;
	}
	.bss ALIGN (4K) : AT (ADDR (.bss) - KERNEL_VIRTUAL_ADDRESS) {
		_bss_start = . - KERNEL_VIRTUAL_ADDRESS;
		*(.bss .bss.*)
		_bss_end = . - KERNEL_VIRTUAL_ADDRESS;
	}

	/DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.init_array .init_array.*)
        *(.comment)
        *(.note.*)
	}

	_kernel_end = . - KERNEL_VIRTUAL_ADDRESS;
}