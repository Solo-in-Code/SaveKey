#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copies SaveKey's sync code into the harness and runs the scripted checks.
# Needs Linux with Swift 5.10 or newer. On a Mac, run it in Docker:
#   docker run --rm -v "$PWD":/src -w /src swift:6.0 bash Tools/SyncCheck/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
if [ "$(uname)" != "Linux" ]; then
    echo "The sync check uses stand-ins for Apple frameworks and runs on Linux only." >&2
    echo "On a Mac: docker run --rm -v \"\$PWD\":/src -w /src swift:6.0 bash Tools/SyncCheck/run.sh" >&2
    exit 1
fi
mkdir -p "$here/Sources/AppLogic/App"
for f in FileAccess DatabaseLibrary DatabaseSession; do
    cp "$repo/Shared/$f.swift" "$here/Sources/AppLogic/App/$f.swift"
done
cd "$here"
swift run AppLogic
