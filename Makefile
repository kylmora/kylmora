APP_NAME    := Kylmora
BUNDLE_ID   := com.kylmora.Kylmora
CONFIG      ?= release
# Which architectures the binary carries. Empty means "whatever this machine
# is", which is what a local build wants: building the second slice as well
# doubles the link for code you cannot run here anyway. CI passes both, so the
# app that ships runs on Intel Macs as well as Apple Silicon.
#   make bundle ARCHS="arm64 x86_64"
ARCHS       ?=
ARCH_FLAGS  := $(foreach arch,$(ARCHS),--arch $(arch))
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
# Where SwiftPM actually put the binary.
#
# Asked, not assumed. The layout depends on which build system the toolchain
# defaults to: a newer Swift writes .build/out/Products/<Config>, an older one
# .build/<config>. A hardcoded path built fine on the machine that wrote it and
# failed on the runner at the copy, after a successful compile and link -- and
# because the release job is the only thing that packages the app, it failed at
# a tag rather than at a push. Expanded lazily, so this runs after the build.
BIN ?= $(shell swift build -c $(CONFIG) $(ARCH_FLAGS) --show-bin-path)/$(APP_NAME)
# The version in Resources/Info.plist, which is a placeholder and stays one.
# Releases are tag-driven: CI sets the real version from `vX.Y.Z` before it
# builds, so the checked-in value is never edited and never true. Local builds
# then all claim to be this, which makes the About pane offer an "update" to
# every release ever cut -- and makes a bug report from a dev build say 0.1.0,
# which names no code at all. `bundle` stamps the copy inside the app from
# `git describe` instead, so a dev build says which commit it is.
#
# The suffix is deliberate and harmless: AppVersion ignores everything after
# the first hyphen, so 0.1.54-1-g31bc7eb compares equal to 0.1.54 and the
# update check stops offering a release you already have -- while the About
# pane still shows the whole string, so you can see it is not a real 0.1.54.
PLACEHOLDER_VERSION := 0.1.0
ENTITLEMENTS := Resources/Kylmora.entitlements
ICON         := Resources/Kylmora.icns
ICON_MARK    := Resources/Icon/kylmora-mark.png

# Signing. With no Developer ID configured the bundle is ad-hoc signed, which
# still applies the entitlements (and so still sandboxes) on this machine but
# cannot be distributed or notarised.
#   make bundle DEV_ID="Developer ID Application: You (TEAMID)"
#   make notarize DEV_ID="..." NOTARY_PROFILE=kylmora-notary
# NOTARY_PROFILE names credentials stored once with:
#   xcrun notarytool store-credentials kylmora-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
DEV_ID         ?=
NOTARY_PROFILE ?=
# For the installer package: a 'Developer ID Installer: You (TEAMID)'
# identity, which is a separate certificate from the Application one. Left
# empty, `make pkg` builds an unsigned package, which an MDM still installs.
INSTALLER_ID   ?=
PKG            := $(BUILD_DIR)/$(APP_NAME).pkg

# swift-testing's macro plugin ships in a subdirectory that SwiftPM does not
# search automatically when only Command Line Tools are installed.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing

.PHONY: all build bundle run test clean size measure notarize icon pkg

all: bundle

# Release builds are optimised for size and dead code is dropped at link:
# the app is a shell over WebKit, so its own code is rarely the hot path.
ifeq ($(CONFIG),release)
SWIFT_FLAGS := -Xswiftc -Osize -Xlinker -dead_strip
else
SWIFT_FLAGS :=
endif

build:
	swift build -c $(CONFIG) $(ARCH_FLAGS) $(SWIFT_FLAGS)

# The app icon is generated from the K mark; see Tools/make-icon.py.
icon: $(ICON)

$(ICON): $(ICON_MARK) Tools/make-icon.py
	python3 Tools/make-icon.py

bundle: build $(ICON)
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@# Give a local build a version that says which commit it is.
	@#
	@# Only ever the copy inside the bundle, never Resources/Info.plist: the
	@# rule is that no version is bumped by hand, and a stamped source file
	@# would be committed by accident sooner or later.
	@#
	@# Only when the plist still reads the placeholder, so a release build --
	@# where CI has already written the tag into Resources/Info.plist -- is
	@# left exactly as CI set it. And only when git can name a tag: a shallow
	@# clone with no tags (CI's own `make bundle` check) falls through quietly
	@# and keeps the placeholder, as it does today.
	@current=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null); \
	described=$$(git describe --tags --dirty --always 2>/dev/null | sed 's/^v//'); \
	tagged=$$(git describe --tags --abbrev=0 2>/dev/null); \
	if [ "$$current" = "$(PLACEHOLDER_VERSION)" ] && [ -n "$$tagged" ]; then \
		commits=$$(git rev-list --count HEAD 2>/dev/null || echo 1); \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$described" "$(APP_BUNDLE)/Contents/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$commits" "$(APP_BUNDLE)/Contents/Info.plist"; \
		echo "local build stamped $$described ($$commits)"; \
	fi
	@cp "$(ICON)" "$(APP_BUNDLE)/Contents/Resources/"
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@cp "$(BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
ifeq ($(CONFIG),release)
	@# The symbol table is not needed to run: stripping it halves the binary.
	@strip -x -S "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
endif
	@# In Resources, not MacOS: codesign treats anything in MacOS as nested code
	@# that must carry its own signature, and a shell script cannot.
	@cp Tools/kylmora "$(APP_BUNDLE)/Contents/Resources/kylmora-cli" && chmod +x "$(APP_BUNDLE)/Contents/Resources/kylmora-cli"
ifeq ($(strip $(DEV_ID)),)
	@codesign --force --sign - --identifier "$(BUNDLE_ID)" \
		--entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)" >/dev/null 2>&1 \
		&& echo "signed ad-hoc (not distributable)" \
		|| echo "warning: ad-hoc codesign failed; bundle is unsigned and will not sandbox"
else
	@codesign --force --sign "$(DEV_ID)" --identifier "$(BUNDLE_ID)" \
		--entitlements "$(ENTITLEMENTS)" --options runtime --timestamp \
		"$(APP_BUNDLE)"
	@echo "signed with $(DEV_ID) (hardened runtime, timestamped)"
endif
	@echo "built $(APP_BUNDLE)"

run: bundle
	@open "$(APP_BUNDLE)"

test:
	swift test -Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGINS)"

size: bundle
	@du -sh "$(APP_BUNDLE)"

measure: bundle
	@./Tools/measure.sh "$(APP_BUNDLE)"

# Submits the bundle to Apple and staples the ticket. Requires a Developer ID
# certificate and stored notarytool credentials; refuses clearly without them
# rather than half-running.
notarize:
	@if [ -z "$(strip $(DEV_ID))" ]; then \
		echo "notarize: no Developer ID configured."; \
		echo "  Set DEV_ID to a 'Developer ID Application: ...' identity."; \
		echo "  Available identities:"; \
		security find-identity -v -p codesigning | sed 's/^/    /'; \
		exit 1; \
	fi
	@if [ -z "$(strip $(NOTARY_PROFILE))" ]; then \
		echo "notarize: no notarytool credentials configured."; \
		echo "  Store them once, then pass NOTARY_PROFILE=<name>:"; \
		echo "    xcrun notarytool store-credentials <name> \\"; \
		echo "        --apple-id <you@example.com> --team-id <TEAMID> \\"; \
		echo "        --password <app-specific-password>"; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory bundle DEV_ID="$(DEV_ID)"
	@codesign --verify --strict --deep "$(APP_BUNDLE)"
	@rm -f "$(BUILD_DIR)/$(APP_NAME).zip"
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(APP_NAME).zip"
	@xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(APP_BUNDLE)"
	@spctl --assess --type execute --verbose "$(APP_BUNDLE)"
	@echo "notarised and stapled $(APP_BUNDLE)"

# An installer package that puts the app in /Applications, for fleets: a
# device-management tool installs a .pkg silently, where a .dmg needs a person
# to drag. Built around whatever bundle is in build/ -- run `make bundle` (or
# CI's notarised one) first, so a stapled app goes in stapled.
#   make pkg INSTALLER_ID="Developer ID Installer: You (TEAMID)"
pkg:
	@test -d "$(APP_BUNDLE)" || { echo "pkg: no $(APP_BUNDLE); run make bundle first"; exit 1; }
	@rm -f "$(PKG)"
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(APP_BUNDLE)/Contents/Info.plist"); \
	if [ -n "$(strip $(INSTALLER_ID))" ]; then \
		pkgbuild --component "$(APP_BUNDLE)" --install-location /Applications \
			--identifier "$(BUNDLE_ID)" --version "$$VERSION" \
			--sign "$(INSTALLER_ID)" --timestamp "$(PKG)" \
		&& echo "signed with $(INSTALLER_ID)"; \
	else \
		pkgbuild --component "$(APP_BUNDLE)" --install-location /Applications \
			--identifier "$(BUNDLE_ID)" --version "$$VERSION" "$(PKG)" \
		&& echo "unsigned (set INSTALLER_ID to sign)"; \
	fi
	@echo "built $(PKG)"

clean:
	swift package clean
	@rm -rf "$(BUILD_DIR)" .build .build-hardening
