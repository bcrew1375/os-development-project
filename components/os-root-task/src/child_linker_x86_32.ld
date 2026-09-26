ENTRY(_start)
OUTPUT_FORMAT(elf32-i386)

CHILD_VIRTUAL_ADDRESS = 0x00400000;

SECTIONS
{
	. = CHILD_VIRTUAL_ADDRESS;
	.text ALIGN (4K) : AT (ADDR (.text) - CHILD_VIRTUAL_ADDRESS)
	{
		*(.text .text.*)
	}
	.rodata ALIGN (4K) : AT (ADDR (.rodata) - CHILD_VIRTUAL_ADDRESS)
	{
		*(.rodata .rodata.*)
		*(.eh_frame_hdr .eh_frame)
	}
	.data ALIGN (4K) : AT (ADDR (.data) - CHILD_VIRTUAL_ADDRESS)
	{
		*(.got .got.*)
		*(.relro_padding)
		*(.data .data.*)
	}
	.bss ALIGN (4K) : AT (ADDR (.bss) - CHILD_VIRTUAL_ADDRESS)
	{
		*(.bss .bss.* COMMON)
	}
}