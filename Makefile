.PHONY: build run clean app test-app release install sign dmg signed-dmg smoke-test github-release check-release python-runtime psyneuview-bundle uv-runtime test

build:
	swift build

run:
	swift run PsyNeuView

release:
	swift build -c release

# The assembled bundle lives inside .build, not the repo root (#118).
#
# Spotlight indexes any .app bundle wherever it sits, so a stale build in the
# repo root shows up in Launchpad beside the real install — one user found a
# 4.2MB 0.4.9 bundle masquerading as their 118MB 0.5.5 install. Dot-prefixed
# directories are skipped by Spotlight, which a plain build/ would not be.
# .build is also already gitignored and already removed by `make clean`.
APP := .build/PsyNeuView.app
# The test app (#209): the same build under the test identity, beside the
# real one. Spaces in the name, so it is quoted wherever it is used.
TEST_APP := .build/PsyNeuView Test.app

# The short commit the bundle was built from, stamped into Info.plist as
# PNVBuildCommit so About can say it (#209). "unknown" outside a checkout.
BUILD_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

# When the bundle was built, in UTC, stamped as PNVBuildDate so About can say
# how recent this app is (#15). A release is built when it is cut.
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

clean:
	swift package clean
	rm -rf .build PsyNeuView-*.dmg .dmg-staging Resources/python-* Resources/psyneuview-*.tar.gz Resources/uv-*

install: app
	@echo "Installing to /Applications..."
	@rm -rf /Applications/PsyNeuView.app
	@cp -R $(APP) /Applications/
	@echo "Installed to /Applications/PsyNeuView.app"
	@echo "Launch from Launchpad or: open /Applications/PsyNeuView.app"

# Stage the pinned PsyNeuView into Resources/ (idempotent, #74).
# Builds its frontend here, on the build machine — which is why no user needs Node.
psyneuview-bundle:
	@./scripts/fetch-psyneuview.sh

# Fetch the pinned uv binary into Resources/ (idempotent, #94).
# Installs the backend's dependencies ~5x faster than pip on a cold cache.
uv-runtime:
	@./scripts/fetch-uv.sh

# Fetch the pinned CPython runtime into Resources/ (idempotent, #64)
python-runtime:
	@./scripts/fetch-python.sh

# Build a .app bundle from the release binary
app: release python-runtime psyneuview-bundle uv-runtime
	@echo "Assembling $(APP)..."
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	@mkdir -p $(APP)/Contents/Resources
	@mkdir -p $(APP)/Contents/Frameworks
	@cp .build/release/PsyNeuView $(APP)/Contents/MacOS/
	@cp Resources/Info.plist $(APP)/Contents/
	@cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	@# The diagnostic goes in the bundle, not fetched over the network: it is
	@# needed precisely when the app will not start, and the user reporting the
	@# problem may have no access to this private repo.
	@cp scripts/diagnose-install.sh $(APP)/Contents/Resources/
	@# Bundle the pinned CPython runtime. Copied wholesale, preserving symlinks
	@# and permissions, so the interpreter stays runnable in place. (#64)
	@cp -R Resources/python-* $(APP)/Contents/Resources/
	@# Stage PsyNeuView itself as an archive. Unpacked to Application Support on
	@# first run, not left in the bundle — Sparkle replaces the bundle wholesale. (#74)
	@cp Resources/psyneuview-*.tar.gz $(APP)/Contents/Resources/
	@cp -R Resources/uv-* $(APP)/Contents/Resources/
	@# Embed Sparkle framework and fix rpath
	@cp -R .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework $(APP)/Contents/Frameworks/
	@install_name_tool -add_rpath @executable_path/../Frameworks $(APP)/Contents/MacOS/PsyNeuView 2>/dev/null || true
	@# Which commit this is, for About and for Report a Problem (#209).
	@/usr/libexec/PlistBuddy -c "Add :PNVBuildCommit string $(BUILD_COMMIT)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :PNVBuildDate string $(BUILD_DATE)" $(APP)/Contents/Info.plist
	@echo "Built $(APP) — run \`make install\` to put it in /Applications"

# Build "PsyNeuView Test.app": the same build with the test identity (#209).
#
# Bundle id com.psyneuview.macapp.test, so its own preferences domain; its
# own Application Support, Logs and ~/.psyneuview-test folders; a TEST ribbon
# on the icon; no Sparkle. It runs beside the real app without touching it.
# See docs/testing.md.
test-app: app
	@./scripts/make-test-app.sh "$(APP)" "$(TEST_APP)"

smoke-test:
	./scripts/smoke-test.sh

# Code sign the .app bundle
sign: app
	./scripts/sign-app.sh

# Build a distributable DMG (unsigned)
dmg: app
	./scripts/create-dmg.sh

# Build a signed and notarized DMG
signed-dmg: sign
	./scripts/notarize-app.sh
	./scripts/create-dmg.sh
	./scripts/notarize-dmg.sh

# Check if the DMG release is up-to-date with main
check-release:
	./scripts/check-release-freshness.sh

# Create a GitHub Release with the DMG attached
github-release:
	./scripts/release.sh

# Run the test suite.
#
# XCTest ships only inside Xcode; CommandLineTools does not include it, so
# `swift test` cannot run the suite on a CLT-only machine. CI has full Xcode
# and is the gate.
#
# CommandLineTools *does* ship swift-testing (`Testing.framework`), and it is
# tempting to write tests with `import Testing` so they run locally. Do not:
# CI's toolchain has no Testing module, so those fail there. A test that runs
# only locally is worse than one that runs only in CI.
test:
	@if ! xcrun --find xctest >/dev/null 2>&1; then \
	  echo "XCTest is unavailable: this machine has $$(xcode-select -p)."; \
	  echo "The XCTest suite needs full Xcode, and runs in CI."; \
	  echo "For a local check, run: make smoke-test"; \
	  exit 1; \
	fi
	swift test
