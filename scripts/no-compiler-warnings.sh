#!/bin/sh
# Fails if a build log holds any compiler or linker warning (AGENTS.md §1.2:
# a green suite with a warning in the log is red). Shared by `make test` and
# every CI build job, so the check is defined once.
#
# Why a log check on top of -warnings-as-errors: the flag does not promote
# every diagnostic. CI run 227 (main, 2fd618c, Xcode 27.0 27A266a) passed
# `-warnings-as-errors` to the HealthLoomUITests compile and still finished
# green with 24 Swift concurrency warnings ([#ActorIsolatedCall], XCTest's
# MainActor APIs called from nonisolated helpers). This catches whatever
# the flag lets through.
#
# Matches the compiler's `path:line:col: warning:` form and `ld: warning:`.
# Tool chatter such as appintentsmetadataprocessor's "Metadata extraction
# skipped" carries no source location and is not a compiler warning.
#
# Usage: scripts/no-compiler-warnings.sh <build-log>
set -eu
log="$1"
if [ ! -s "$log" ]; then
	echo "error: build log '$log' is missing or empty -- nothing to check." >&2
	exit 1
fi
warnings=$(grep -E '^[^ ]+:[0-9]+:[0-9]+: warning:|^ld: warning:' "$log" | sort -u || true)
if [ -n "$warnings" ]; then
	count=$(printf '%s\n' "$warnings" | wc -l | tr -d ' ')
	echo "error: $count compiler warning(s) in the build log (AGENTS.md §1.2 -- warnings are errors):" >&2
	printf '%s\n' "$warnings" >&2
	exit 1
fi
echo "==> no compiler warnings in $log"
