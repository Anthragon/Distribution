OUTPUT_FORMAT(elf64-littleaarch64)

KERNEL_VIRT_START = 0xffffffff80000000;
KERNEL_STACK_SIZE = 0x4000;

ENTRY(__boot_entry__)

SECTIONS {

    . = KERNEL_VIRT_START;
    
    __base__ = .;
    __kernel_start__ = .;

    .text : ALIGN(4K) {
        *(.text*)
    } : text

    .rodata : ALIGN(4K) {
        *(.rodata*)
    } : rodata

    .data : ALIGN(4K) {
        *(.data*)
    } : data

    .bss : ALIGN(4K) {
        *(.bss*)
        *(COMMON)

        . = ALIGN(16);
        . += KERNEL_STACK_SIZE;
    } : bss

    __kernel_end__ = .;
}
