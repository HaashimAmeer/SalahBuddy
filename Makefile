# SalahBuddy — local dev / CI tasks.
# Tests run on a SIMULATOR (no code signing needed). Override the sim with:
#   make test SIM="iPhone 15"
#
# The DEVELOPMENT_TEAM is declared in project.yml, so `xcodegen generate` is
# signing-safe here — regenerating does NOT wipe your team.

PROJECT := SalahBuddy.xcodeproj
SCHEME  := SalahBuddy
SIM     ?= iPhone 17

# Resolve a concrete simulator UDID for $(SIM) at runtime — preferring one
# that's already Booted, else the first available, else ANY installed iPhone
# (this machine deliberately keeps a single iOS runtime to save disk, so the
# named default can vanish on runtime upgrades). A bare `name=iPhone 17`
# destination is AMBIGUOUS when the device exists under several OS runtimes
# (xcodebuild errors out), so we pin the unambiguous id instead.
define resolve_sim
	SIM_ID=$$(xcrun simctl list devices available | grep "$(SIM) (" | grep "(Booted)" | head -1 | grep -oE "[0-9A-Fa-f-]{36}"); \
	[ -z "$$SIM_ID" ] && SIM_ID=$$(xcrun simctl list devices available | grep "$(SIM) (" | head -1 | grep -oE "[0-9A-Fa-f-]{36}"); \
	[ -z "$$SIM_ID" ] && { SIM_ID=$$(xcrun simctl list devices available | grep "iPhone" | head -1 | grep -oE "[0-9A-Fa-f-]{36}"); [ -n "$$SIM_ID" ] && echo "▸ '$(SIM)' not installed — using first available iPhone sim"; }; \
	if [ -z "$$SIM_ID" ]; then echo "✗ No available iPhone simulator at all. Install one in Xcode ▸ Settings ▸ Platforms."; exit 1; fi; \
	echo "▸ Using simulator $$SIM_ID"
endef

.PHONY: generate test build hooks lock

## generate: regenerate the Xcode project from project.yml
generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }
	@xcodegen generate

## test: build + run the unit tests on the simulator (what the pre-push hook runs)
##
## The explicit `simctl bootstatus -b` is not ceremony. Handing xcodebuild a
## shut-down simulator lets it boot the device itself — and on GitHub's macOS
## runners that step has twice hung FOREVER after a clean build, burning the
## whole 40-minute job timeout without ever starting a test. bootstatus boots
## the device and blocks until it is genuinely ready, so a boot that is going
## to fail fails here, in seconds, with a real error.
test: generate
	@$(resolve_sim); \
	xcrun simctl bootstatus "$$SIM_ID" -b; \
	xcodebuild test \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination "platform=iOS Simulator,id=$$SIM_ID"

## build: compile-only check on the simulator (faster than a full test run)
build: generate
	@$(resolve_sim); \
	xcodebuild build \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination "platform=iOS Simulator,id=$$SIM_ID"

## lock: refresh the committed Package.resolved from the generated project
## (run after changing SPM dependencies in project.yml, then commit it —
## Xcode Cloud builds pin dependencies from this file)
lock:
	@cp SalahBuddy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved
	@echo "✓ Package.resolved refreshed — commit it so Xcode Cloud picks it up"

## hooks: activate the tracked git hooks (run once per clone)
hooks:
	git config core.hooksPath .githooks
	@echo "✓ pre-push hook active (.githooks/pre-push)"
