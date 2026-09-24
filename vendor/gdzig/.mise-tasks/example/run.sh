#!/usr/bin/env bash
#MISE description="Run the example project"
#MISE dir="example/project"

#USAGE flag "--release <release>" default="off"

mise run example:build --release=$usage_release

godot
