.PHONY: xcode test clean prune-branches

xcode:
	xcodegen generate
	open HealthLoom.xcodeproj

XCODE_BETA := /Applications/Xcode-beta.app/Contents/Developer

test:
	@test -d "$(XCODE_BETA)" || { \
		echo "error: $(XCODE_BETA) not found -- the app target needs the iOS 27 SDK from the Xcode 27 beta. Install the Xcode 27 beta." >&2; \
		exit 1; \
	}
	@for pkg in CoreModel Secrets GoogleHealthClient SyncKit CoachKit; do \
		echo "==> swift test ($$pkg)"; \
		(cd Packages/$$pkg && DEVELOPER_DIR="$(XCODE_BETA)" swift test -Xswiftc -warnings-as-errors) || exit 1; \
	done
	xcodegen generate
	@udid=$$(DEVELOPER_DIR="$(XCODE_BETA)" xcrun simctl list devices available \
		| awk '/-- iOS 27\.0 --/{flag=1; next} /^--/{flag=0} flag' \
		| grep -E 'iPhone' \
		| grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' \
		| head -n1); \
	if [ -z "$$udid" ]; then \
		echo "error: no available iPhone simulator on the iOS 27.0 runtime -- run 'DEVELOPER_DIR=$(XCODE_BETA) xcodebuild -downloadPlatform iOS' to install it. (project.yml's deploymentTarget is iOS 27.0; other installed runtimes won't satisfy it.)" >&2; \
		exit 1; \
	fi; \
	echo "==> xcodebuild build test (destination iOS Simulator $$udid)"; \
	DEVELOPER_DIR="$(XCODE_BETA)" xcodebuild build test \
		-project HealthLoom.xcodeproj \
		-scheme HealthLoom \
		-destination "platform=iOS Simulator,id=$$udid" \
		SWIFT_SUPPRESS_WARNINGS=NO
	# NOTE: warnings-as-errors is enforced per-target in project.yml (which
	# covers Xcode-GUI builds, which get no command line) and per-package
	# via `swift test -Xswiftc -warnings-as-errors` above. It is deliberately
	# NOT passed on this command line anymore: command-line scope reaches
	# SPM package targets too, and swift-snapshot-testing 1.19.4 carries
	# iOS-15-era deprecation warnings (WP-33) that would fail the build for
	# third-party code we don't own. Accepted residual (round-1 L1): the old
	# command line also covered the *local* packages' iOS builds in the
	# xcodebuild graph, so an iOS-only warning in package code (e.g. an
	# SDK-gated deprecation the macOS `swift test` run can't see) now fails
	# nowhere — no per-package flag exists to restore it.
	# `SWIFT_SUPPRESS_WARNINGS=NO` stays:
	# it overrides the `-suppress-warnings` Xcode's SwiftPM integration
	# injects into remote package targets, keeping upstream warnings
	# visible in logs instead of silently suppressed.

clean:
	rm -rf HealthLoom.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/HealthLoom-*
	@for pkg in CoreModel Secrets GoogleHealthClient SyncKit CoachKit; do \
		(cd Packages/$$pkg && swift package clean); \
	done
	xcrun simctl uninstall booted com.healthloom.app 2>/dev/null || true

prune-branches:
	@git fetch --prune origin
	@current=$$(git branch --show-current); \
	merged=$$(gh pr list --state merged --limit 200 --json headRefName --jq '.[].headRefName' | sort -u); \
	deleted=0; \
	for branch in $$(git for-each-ref --format='%(refname:short)' refs/heads/); do \
		case "$$branch" in main|master) continue ;; esac; \
		if [ "$$branch" = "$$current" ]; then continue; fi; \
		if printf '%s\n' "$$merged" | grep -qx "$$branch"; then \
			git branch -D "$$branch"; \
			deleted=$$((deleted + 1)); \
		fi; \
	done; \
	echo "Pruned $$deleted merged branch(es)."
