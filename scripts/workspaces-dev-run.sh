#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Use Command Line Tools for Zig linking on this machine, while the branch's
# build-system workaround uses full Xcode for Metal and xcodebuild steps.
env DEVELOPER_DIR=/Library/Developer/CommandLineTools \
    zig build run -Dxcframework-target=native "$@"
