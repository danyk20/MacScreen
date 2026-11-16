#!/usr/bin/env bash
# CI-ready test runner. Builds, then runs the unit tests (VirtualDisplayTests are skipped by default
# because they create a virtual display and flicker the screen).
# Usage: Scripts/test.sh [--with-display-tests]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

WITH_DISPLAY=0
for arg in "$@"; do
    case "$arg" in
        --with-display-tests) WITH_DISPLAY=1 ;;
        -h|--help) echo "Usage: Scripts/test.sh [--with-display-tests]"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; echo "Usage: Scripts/test.sh [--with-display-tests]" >&2; exit 2 ;;
    esac
done

swift build

if [[ "$WITH_DISPLAY" -eq 1 ]]; then
    echo "WARNING: running VirtualDisplayTests; this creates virtual displays and flickers the screen." >&2
    swift test
else
    swift test --skip VirtualDisplayTests
fi
