OUTPUT_FORMAT(elf64-littleaarch64)

KERNEL_VIRT_START = 0xffffffff80000000;
KERNEL_STACK_SIZE = 0x4000;

PHDRS
{
    text PT_LOAD FLAGS(5);   /* R + X */
    rodata PT_LOAD FLAGS(4); /* R */
    data PT_LOAD FLAGS(6);   /* R + W */
}

SECTIONS {

    . = KERNEL_VIRT_START;

    __base__ = .;
    __kernel_start__ = .;

    .text : ALIGN(4K) {
        *(.text*)
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

    __kernel_userland_start = .;
    .text.userland : ALIGN(4K) {
        KEEP(*(.text.userland*))
    }

    .rodata.userland : ALIGN(4K) {
        *(.rodata.userland*)
        *(.lrodata.userland*)
    }

    .data.userland : ALIGN(4K) {
        *(.data.userland*)
        *(.ldata.userland*)
    }

    .bss.userland : ALIGN(4K) {
        *(.bss.userland*)
        *(.lbss.userland*)
        *(.tbss.userland*)
        *(COMMON.userland)

        . = ALIGN(16);
        . += KERNEL_STACK_SIZE;
    }
    __kernel_userland_end = .;

    .kernel_modules : ALIGN(4K) {
        __kernel_modules_start__ = .;
        KEEP(*(.kernel_modules*))
        __kernel_modules_end__ = .;
    }

    __kernel_end__ = .;
}
