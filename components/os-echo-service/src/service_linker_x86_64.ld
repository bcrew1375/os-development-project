ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)

SERVICE_VIRTUAL_ADDRESS = 0x0000000000400000;

SECTIONS
{
	. = SERVICE_VIRTUAL_ADDRESS;
	.text ALIGN (4K) : AT (ADDR (.text) - SERVICE_VIRTUAL_ADDRESS)
	{
		*(.text .text.*)
	}
	.rodata ALIGN (4K) : AT (ADDR (.rodata) - SERVICE_VIRTUAL_ADDRESS)
	{
		*(.rodata .rodata.*)
		*(.eh_frame_hdr .eh_frame)
	}
	.data ALIGN (4K) : AT (ADDR (.data) - SERVICE_VIRTUAL_ADDRESS)
	{
		*(.got .got.*)
		*(.relro_padding)
		*(.data .data.*)
	}
	.bss ALIGN (4K) : AT (ADDR (.bss) - SERVICE_VIRTUAL_ADDRESS)
	{
		*(.bss .bss.* COMMON)
	}
}
