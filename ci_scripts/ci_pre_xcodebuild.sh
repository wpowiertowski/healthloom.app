#!/bin/sh
#
# Xcode Cloud build-number stamp.
#
# App Store Connect rejects a TestFlight upload whose (version, build) pair
# it has already seen. CURRENT_PROJECT_VERSION is a literal "1" in
# project.yml, so without this every archive uploads as build 1 and the
# second one is refused as a duplicate.
#
# Xcode Cloud exports CI_BUILD_NUMBER: a per-product counter it increments
# for every build, independent of this repo. Stamping it into the build
# setting reaches the app because Info.plist's CFBundleVersion is
# $(CURRENT_PROJECT_VERSION) (see project.yml) rather than a literal.
#
# The edit is confined to the cloud's ephemeral checkout -- nothing is
# committed back, MARKETING_VERSION is untouched (bump that by hand for a
# real version change), and local and GitHub-CI builds never run this
# because only Xcode Cloud sets CI_BUILD_NUMBER.

set -eu

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
	echo "note: CI_BUILD_NUMBER is unset -- not an Xcode Cloud build, leaving the version alone."
	exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is not set}"

pbxproj="HealthLoom.xcodeproj/project.pbxproj"
[ -f "$pbxproj" ] || { echo "error: $pbxproj not found in $PWD" >&2; exit 1; }

# BSD sed (Xcode Cloud runners are macOS). Every configuration is rewritten:
# the Archive action builds Release, but leaving Debug behind would make the
# two disagree for no reason.
sed -i '' -E \
	"s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};/g" \
	"$pbxproj"

stamped="$(grep -c "CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};" "$pbxproj" || true)"
if [ "$stamped" -eq 0 ]; then
	echo "error: no CURRENT_PROJECT_VERSION entry was rewritten -- has project.yml changed?" >&2
	exit 1
fi

echo "Stamped CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER} (${stamped} configurations)."
