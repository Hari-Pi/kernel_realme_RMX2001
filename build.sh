#!/bin/sh
set -eu

exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers/build-droidian.sh" "$@"
