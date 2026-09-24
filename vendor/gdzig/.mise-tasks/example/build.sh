#!/usr/bin/env bash
#MISE description="Build the example project"
#MISE dir="example"

#USAGE flag "--release <release>" default="off"

zig build --release=$usage_release
