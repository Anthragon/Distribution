#!/bin/bash

BIN="./zig-out/disk/boot/kernel"
INPUT_LOG="./zig-out/stderr.txt"
VMA_BASE="0xFFFFFFFF80000000"

TMP_FILE=$(mktemp)
TMP_ADDRS=$(mktemp)
in_section=false

lf=$'\n'

while IFS= read -r line; do

    if [[ "$line" == "<===addr===>" ]]; then
        in_section=true
        > "$TMP_ADDRS"
        continue
    
    elif [[ "$line" == "<===addr===/>" ]]; then
        in_section=false
        while IFS= read -r addr; do
            location=$"$addr: $(addr2line -e "$BIN" -f -C -i "0x$addr")$lf"
            echo "$location" >> "$TMP_FILE"
        done < "$TMP_ADDRS"
        continue
    fi

    if $in_section; then
        echo "$line" >> "$TMP_ADDRS"
    else
        echo "$line" >> "$TMP_FILE"
    fi
done < "$INPUT_LOG"

mv "$TMP_FILE" "$INPUT_LOG"
rm "$TMP_ADDRS"