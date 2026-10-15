# NoteObs — menu bar notes for macOS.
#
# `make verify` is the regression gate: NoteObs/Verification.swift runs its scenarios against real
# folders on disk. It lives in the app target because a Command Line Tools installation has no
# XCTest module, so `swift test` would build fine and run zero tests.

SWIFT ?= swift
BIN_DIR := $(shell $(SWIFT) build -c debug --show-bin-path)

.PHONY: verify build release-app clean

build:
	$(SWIFT) build

## Runs every scenario in NoteObs/Verification.swift against real folders on disk.
verify:
	$(SWIFT) build
	$(BIN_DIR)/NoteObs --verify

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' NoteObs/Info.plist)
DIST := ../dist
APP := $(DIST)/NoteObs.app

## Builds the release binary, runs the checks against it, and packs ../dist/NoteObs.app (signed ad hoc:
## there is no Developer ID here) together with a zip and a dmg of it.
release-app:
	$(SWIFT) build -c release
	"$$($(SWIFT) build -c release --show-bin-path)/NoteObs" --verify
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$($(SWIFT) build -c release --show-bin-path)/NoteObs" "$(APP)/Contents/MacOS/NoteObs"
	cp NoteObs/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign - --timestamp=none "$(APP)"
	codesign --verify --strict "$(APP)"
	rm -f "$(DIST)/NoteObs-$(VERSION)-macOS-Release.zip" "$(DIST)/NoteObs.dmg"
	cd "$(DIST)" && ditto -c -k --keepParent NoteObs.app "NoteObs-$(VERSION)-macOS-Release.zip"
	hdiutil create -quiet -volname NoteObs -srcfolder "$(APP)" -ov -format UDZO "$(DIST)/NoteObs.dmg"

clean:
	rm -rf .build
