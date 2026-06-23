# SalahBuddy — local dev / CI tasks.
# Tests run on a SIMULATOR (no code signing needed). Override the sim with:
#   make test SIM="iPhone 15"
#
# The DEVELOPMENT_TEAM is declared in project.yml, so `xcodegen generate` is
# signing-safe here — regenerating does NOT wipe your team.

PROJECT := SalahBuddy.xcodeproj
SCHEME  := SalahBuddy
SIM     ?= iPhone 16 Pro

# Resolve a concrete simulator UDID for $(SIM) at runtime — preferring one
# that's already Booted, else the first available. A bare `name=iPhone 16 Pro`
# destination is AMBIGUOUS when the device exists under several OS runtimes
# (xcodebuild errors out), so we pin the unambiguous id instead. Adapts to
# whatever sims a given machine has installed.
define resolve_sim
	SIM_ID=$$(xcrun simctl list devices available | grep "$(SIM) (" | grep "(Booted)" | head -1 | grep -oE "[0-9A-Fa-f-]{36}"); \
	[ -z "$$SIM_ID" ] && SIM_ID=$$(xcrun simctl list devices available | grep "$(SIM) (" | head -1 | grep -oE "[0-9A-Fa-f-]{36}"); \
	if [ -z "$$SIM_ID" ]; then echo "✗ No available simulator named '$(SIM)'. Override: make $@ SIM=\"iPhone 17\""; exit 1; fi; \
	echo "▸ Using simulator $(SIM) ($$SIM_ID)"
endef

.PHONY: generate test build hooks

## generate: regenerate the Xcode project from project.yml
generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }
	@xcodegen generate

## test: build + run the unit tests on the simulator (what the pre-push hook runs)
test: generate
	@$(resolve_sim); \
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

## hooks: activate the tracked git hooks (run once per clone)
hooks:
	git config core.hooksPath .githooks
	@echo "✓ pre-push hook active (.githooks/pre-push)"
