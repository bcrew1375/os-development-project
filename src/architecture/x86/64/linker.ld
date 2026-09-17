ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)

KERNEL_VIRTUAL_ADDRESS = 0xFFFFFFFF80000000;

SECTIONS
{
	. = KERNEL_VIRTUAL_ADDRESS;
	_kernel_start = .;

	.text ALIGN (4K) : AT (ADDR (.text) - KERNEL_VIRTUAL_ADDRESS) {
		_text_start = .;
		*(.text .text.*)
		_text_end = .;
	}
	.rodata ALIGN (4K) : AT (ADDR (.rodata) - KERNEL_VIRTUAL_ADDRESS) {
		_rodata_start = .;
		*(.rodata .rodata.*)
		_rodata_end = .;
	}
	. = ALIGN(4K);
	.limine_requests ALIGN (4K) : AT (ADDR (.limine_requests) - KERNEL_VIRTUAL_ADDRESS) {
		KEEP(*(.limine_requests_start))
		KEEP(*(.limine_requests))
		KEEP(*(.limine_requests_end))
	}
	.data ALIGN (4K) : AT (ADDR (.data) - KERNEL_VIRTUAL_ADDRESS) {
		_data_start = .;
		*(.data .data.*)
		_data_end = .;
	}
	.sancov_guards ALIGN (8) : AT (ADDR (.sancov_guards) - KERNEL_VIRTUAL_ADDRESS) {
		__start___sancov_guards = .;
		KEEP(*(__sancov_guards))
		__stop___sancov_guards = .;
	}
	.bss ALIGN (4K) : AT (ADDR (.bss) - KERNEL_VIRTUAL_ADDRESS) {
		_bss_start = .;
		*(.bss .bss.*)
		_bss_end = .;
	}

	_kernel_end = .;

	/DISCARD/ : {
    *(.eh_frame)
    *(.eh_frame_hdr)
    *(.comment)
    *(.note.*)
	}
}
