#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Creates and attaches only a new temporary 128 MiB FAT32 disk image. The XCTest
# cleanup detaches that image and retains its path if cleanup fails.
ZIPPER_RUN_FILESYSTEM_TESTS=1 swift test --filter FilesystemVolumeTests
