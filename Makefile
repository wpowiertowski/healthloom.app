.PHONY: xcode test clean prune-branches

# Pinned generator (third-party F1): a bare `xcodegen generate` resolves
# whatever is on PATH (2.45.4 via brew), but the committed project and
# CI's drift job are pinned to XCODEGEN_VERSION — a version skew here
# produces bytes the drift gate rejects. Source of truth stays the ci.yml
# env block (single pin, no duplication).
xcode:
	@pinned=$$(grep '^  XCODEGEN_VERSION:' .github/workflows/ci.yml | awk -F'"' '{print $$2}'); \
	actual=$$(xcodegen --version | awk '{print $$NF}'); \
	if [ "$$actual" != "$$pinned" ]; then \
		echo "error: xcodegen $$actual on PATH, pinned is $$pinned — install it (see ci.yml project-drift job)." >&2; \
		exit 1; \
	fi
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
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		GCC_TREAT_WARNINGS_AS_ERRORS=YES
	# NOTE (owner directive: strict warnings-as-errors everywhere, no
	# carve-outs): the flags above apply command-line-wide — first-party
	# targets, local packages in the xcodebuild graph, and any SPM target.
	# Per-target project.yml settings additionally cover Xcode-GUI builds
	# (no command line), and per-package `swift test -Xswiftc
	# -warnings-as-errors` covers the macOS host. There are no remote
	# package dependencies left to break this (WP-33's snapshot tests use a
	# local helper for exactly this reason); adding one requires it to
	# build warning-free under this SDK first.

# NOTE: clean must NOT delete HealthLoom.xcodeproj — it is tracked since
# the Xcode Cloud repo-prep (cloud builds compile the committed project).
# Regenerating is `make xcode` (pinned xcodegen via project-drift CI).
clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/HealthLoom-*
	@for pkg in CoreModel Secrets GoogleHealthClient SyncKit CoachKit; do \
		(cd Packages/$$pkg && swift package clean); \
	done
	xcrun simctl uninstall booted app.healthloom 2>/dev/null || true

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
