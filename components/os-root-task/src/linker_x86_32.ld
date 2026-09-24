ENTRY(_start)
OUTPUT_FORMAT(elf32-i386)

ROOT_PROCESS_VIRTUAL_ADDRESS = 0x00400000;
ROOT_HEAP_START = 0x01000000;
ROOT_HEAP_SIZE = 0x01000000;

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
		*(.got .got.*)
		*(.relro_padding)
		*(.init_array .init_array.*)
		*(.data .data.*)
	}
	.bss ALIGN (4K) : AT (ADDR (.bss) - ROOT_PROCESS_VIRTUAL_ADDRESS)
	{
		*(.bss .bss.* COMMON)
	}
	ASSERT(. <= ROOT_HEAP_START, "root task image overlaps heap range")
	__root_heap_start = ROOT_HEAP_START;
	__root_heap_end = ROOT_HEAP_START + ROOT_HEAP_SIZE;
}
