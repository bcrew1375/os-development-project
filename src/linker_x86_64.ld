ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)

ROOT_PROCESS_VIRTUAL_ADDRESS = 0x0000000000400000;

SECTIONS
{
	. = ROOT_PROCESS_VIRTUAL_ADDRESS;
	.text ALIGN (4K) : AT (ADDR (.text) - ROOT_PROCESS_VIRTUAL_ADDRESS)
	{
		*(.text .text.*)
	}
	.rodata ALIGN (4K) : AT (ADDR (.rodata) - ROOT_PROCESS_VIRTUAL_ADDRESS)
	{
		*(.rodata .rodata.*)
		*(.eh_frame_hdr .eh_frame)
	}
	.data ALIGN (4K) : AT (ADDR (.data) - ROOT_PROCESS_VIRTUAL_ADDRESS)
	{
		*(.data .data.*)
	}
	.bss ALIGN (4K) : AT (ADDR (.bss) - ROOT_PROCESS_VIRTUAL_ADDRESS)
	{
		*(.bss .bss.* COMMON)
	}
}
