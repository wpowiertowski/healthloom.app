#!/bin/sh
# Prints the UDID of the first pinned iPhone model available on the iOS 27.0
# simulator runtime (the model snapshot references are recorded on --
# HealthLoomTests/SnapshotAssert.swift; CI pins the same list). Shared by
# `make test` and `make stress`. Fails loudly instead of falling back to
# whatever simctl lists first.
set -eu
avail=$(xcrun simctl list devices available | awk '/-- iOS 27\.0 --/{flag=1; next} /^--/{flag=0} flag')
for name in "iPhone 18 Pro" "iPhone 18 Pro Max" "iPhone 17 Pro" "iPhone 17 Pro Max"; do
	udid=$(printf '%s\n' "$avail" \
		| grep -E "^[[:space:]]*$name \(" \
		| grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' \
		| head -n1 || true)
	if [ -n "$udid" ]; then
		echo "==> simulator model: $name" >&2
		echo "$udid"
		exit 0
	fi
done
echo "error: none of the pinned iPhone models is available on the iOS 27.0 runtime. Snapshot references are recorded on one model (HealthLoomTests/SnapshotAssert.swift), so this must not fall back to whatever simctl lists first -- CI pins the same list. Install one, or add the model here AND in ci.yml and re-record. Available:" >&2
printf '%s\n' "$avail" >&2
exit 1
