#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")"
mkdir -p build
if [[ "${1:-}" == "--test" && $# == 1 ]]; then
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework IOKit \
        -DCHARGE_CONTROL_TEST=1 charge-control.m -o build/charge-control-tests
    build/charge-control-tests
elif [[ $# == 0 ]]; then
    xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -framework Foundation -framework IOKit \
        charge-control.m -o build/charge-control
    codesign --force --sign - build/charge-control
    printf '%s\n' "$PWD/build/charge-control"
else
    printf 'Usage: %s [--test]\n' "$0" >&2
    exit 2
fi
