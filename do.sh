#!/usr/bin/env bash

cd $(dirname $0)
DISTRIBUTION_FOLDER=$(pwd)

case $1 in
    "setup")
        if [[ -d "$DISTRIBUTION_FOLDER/dependencies/image-builder" ]];
        then
            rm -rf "$DISTRIBUTION_FOLDER/dependencies/image-builder"
        fi

        if [[ -d "$DISTRIBUTION_FOLDER/kernel" ]];
        then
            rm -rf "$DISTRIBUTION_FOLDER/kernel"
        fi

        if [[ -d "$DISTRIBUTION_FOLDER/modules" ]];
        then
            rm -rf "$DISTRIBUTION_FOLDER/modules"
        fi

        git clone https://github.com/lumi2021/image-builder "$DISTRIBUTION_FOLDER/dependencies/image-builder"
        git clone https://github.com/SystemElva/Kernel "$DISTRIBUTION_FOLDER/kernel"
        git clone https://github.com/SystemElva/Modules "$DISTRIBUTION_FOLDER/modules"
        ;;

    "b" | "build")
        zig build "${"@":1}"
        ;;

    "r" | "run")
        zig build run
        ;;
esac
