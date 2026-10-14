#!/bin/sh
# Builds and runs the crash-guard unit tests on the build host.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/modcg-test
rm -rf "$out" && mkdir -p "$out"
cc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -Wno-unknown-pragmas ${CG_SANITIZE:-} -g \
   -o "$out/test_crashguard" "$here/test_crashguard.c" "$here/../Sources/MODCrashGuardCore.c"
CG_TEST_DIR="$out" "$out/test_crashguard"
