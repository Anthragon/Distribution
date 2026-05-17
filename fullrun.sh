#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

COMMON_FLAGS=(
    -DsystemUsers=camila,fa5c7724-18d8-4d21-a782-9732b4e5c028,A
    -freference-trace
)

TARGET_FLAGS=()

cd $(dirname $0)
DISTRIBUTION_FOLDER=$(pwd)

case "$1" in
    "x86_64-efi" | "x64-efi")
        TARGET_FLAGS=(
            -Dtarch=x86_64
            -DbiosMode=uefi
            -DdiskLayout=GPT
        )
        ;;
    
    "x86_64-bios" | "x64-bios")
        TARGET_FLAGS=(
            -Dtarch=x86_64
            -DbiosMode=bios
        )
        ;;
    
    "aarch64-efi" | "arm-efi")
        TARGET_FLAGS=(
            -Dtarch=aarch64
            -DbiosMode=uefi
            -DdiskLayout=GPT
        )
        ;;
    
    *)
        echo "Invalid argument: $1"
        exit 1
        ;;
esac

shift

zig build run \
    "${COMMON_FLAGS[@]}" \
    "${TARGET_FLAGS[@]}" \
    "$@"
