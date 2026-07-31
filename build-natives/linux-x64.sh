#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/build-natives/build-platform.sh" linux-x64 "$@"
