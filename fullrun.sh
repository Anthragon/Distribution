cd $(dirname $0)
DISTRIBUTION_FOLDER=$(pwd)

case $1 in
    "x86_64-efi" | "x64-efi")
        zig build run \
        -Dtarch=x86_64 \
        -DbiosMode=uefi \
        -DdiskLayout=GPT \
        -DsystemUsers=camila,fa5c7724-18d8-4d21-a782-9732b4e5c028,A \
        -freference-trace
        ;;

    "x86_64-bios" | "x64-bios")
        zig build run \
        -Dtarch=x86_64 \
        -DbiosMode=bios \
        -DsystemUsers=camila,fa5c7724-18d8-4d21-a782-9732b4e5c028,A \
        -freference-trace
        ;;
    
    "aarch64-efi" | "arm-efi")
        zig build run \
        -Dtarch=aarch64 \
        -DbiosMode=uefi \
        -DdiskLayout=GPT \
        -DsystemUsers=camila,fa5c7724-18d8-4d21-a782-9732b4e5c028,A \
        -freference-trace
        ;;
    
    *)
        echo "Invalid argument $0"
        exit 1
        ;;
esac
