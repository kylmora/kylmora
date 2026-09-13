APP_NAME    := Kylmora
BUNDLE_ID   := com.kylmora.Kylmora
CONFIG      ?= release
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
BIN         := $(shell swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)
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

# swift-testing's macro plugin ships in a subdirectory that SwiftPM does not
# search automatically when only Command Line Tools are installed.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing

.PHONY: all build bundle run test clean size measure notarize icon

all: bundle

build:
	swift build -c $(CONFIG)

# The app icon is generated from the K mark; see Tools/make-icon.py.
icon: $(ICON)

$(ICON): $(ICON_MARK) Tools/make-icon.py
	python3 Tools/make-icon.py

bundle: build $(ICON)
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp "$(ICON)" "$(APP_BUNDLE)/Contents/Resources/"
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@cp "$(BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
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

clean:
	swift package clean
	@rm -rf "$(BUILD_DIR)" .build .build-hardening
