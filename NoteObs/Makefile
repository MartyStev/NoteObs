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

## Release build only; packaging into ../dist is still done by hand, see the project notes.
release-app:
	$(SWIFT) build -c release

clean:
	rm -rf .build
