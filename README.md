# Systemlumi Operating System Distribution


## Dependences:

- zig compiler 0.14.1
- QEMU x86_64 system emulator
- Linux


## Build and Run:

```md
zig build               -- builds the binaries and produces a disk image
zig build run           -- builds binaries, produces disk image and execute it on qemu

# flags:
Dtarch=<arch>           -- Target ARCHtecture. Options are: x86_64, aarch64 (default is host)
Dbootloader=<enum>      -- Target Bootloader.  Options are: limine (default is limine)
DbiosMode=<enum>        -- Target BIOS mode.   Options are: bios, uefi (default is bios)
DdiskLayout=<enum>      -- Target disk layout. Options are: MBR, GPT (default is MBR, GPT if UEFI)
Dmemory=<string>        -- Emulated system's memory size.
DuseGDB=<bool>          -- Enables QEMU support for GDB connection. (Default is false)
```
