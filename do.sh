#!/usr/bin/env bash

cd $(dirname $0)
DISTRIBUTION_FOLDER=$(pwd)

case $1 in
    "setup")
        git submodule update --init --recursive

        ;;

    "b" | "build")
        zig build "${"@":1}"
        ;;

    "r" | "run")
        zig build run
        ;;
esac
