KERNEL_VIRT_START = 0xffffffff80000000;
KERNEL_STACK_SIZE = 0x4000;

SECTIONS {

    . = KERNEL_VIRT_START;
    
    __base__ = .;
    __kernel_start__ = .;

    .text : ALIGN(4K) {
        *(.text*)
    }

    .text.userland : ALIGN(4K)
    {
        __kernel_text_userland_start__ = .;
        KEEP(*(.text.userland*))
        __kernel_text_userland_end__ = .;
    }

    .rodata : ALIGN(4K) {
        *(.rodata*)
        *(.lrodata*)
    }

    .data : ALIGN(4K) {
        *(.data*)
        *(.ldata*)
    }

    .bss : ALIGN(4K) {
        *(.bss*)
        *(.lbss*)
        *(.tbss*)
        *(COMMON)

        . = ALIGN(16);
        . += KERNEL_STACK_SIZE;
    }

    .kernel_modules : ALIGN(8)
    {
        __kernel_modules_start__ = .;
        KEEP(*(.kernel_modules*))
        __kernel_modules_end__ = .;
    }

    __kernel_end__ = .;
}
