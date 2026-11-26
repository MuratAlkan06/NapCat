APP_NAME := NapCat
DIST     := dist
APP      := $(DIST)/$(APP_NAME).app
BINARY   := .build/release/$(APP_NAME)

# F4 remote approvals: the channel server Claude Code spawns (the
# napcat-channel product) ships inside the bundle as a helper tool,
# Contents/MacOS/napcat-channel. It is signed BEFORE the app (nested code
# first), with the same CODESIGN command (so the same identity, and the
# hardened runtime with a real one), under its own identifier and with no
# entitlements, ever. ChannelInstallStructureTests keeps every copy of the
# identifier byte-identical to this one.
CHANNEL            := napcat-channel
CHANNEL_BINARY     := .build/release/$(CHANNEL)
CHANNEL_IDENTIFIER := com.muratalkan.napcat.channel

# Code-signing identity for the bundle. The default `-` is the ad-hoc signature
# a plain `make` has always produced: no certificate, no network. The release
# workflow passes a Developer ID identity instead (make SIGN_IDENTITY="...");
# any identity other than `-` also gets the hardened runtime and a secure
# timestamp, both of which notarization requires (the timestamp needs network).
# The ad-hoc branch spells out the exact command `make` has always run.
SIGN_IDENTITY := -

# CloudKit entitlements and the provisioning profile that grants them, for a
# Developer ID build only: the release workflow passes
# ENTITLEMENTS=Resources/NapCat.entitlements and PROVISIONING_PROFILE=<decoded
# .provisionprofile>. Both are empty by default, so a plain `make` stays
# unentitled (the app's entitlement probe then keeps it on ntfy). When set, the
# profile is installed as Contents/embedded.provisionprofile before signing and
# codesign gets --entitlements. Never commit a .provisionprofile.
# Ad-hoc signing with either one set (on the command line or in the
# environment) is refused: AMFI kills an ad-hoc binary that claims restricted
# entitlements as soon as it launches.
ENTITLEMENTS ?=
PROVISIONING_PROFILE ?=

ifeq ($(strip $(SIGN_IDENTITY)),-)
CODESIGN := codesign --force -s -
ifneq ($(strip $(ENTITLEMENTS)$(PROVISIONING_PROFILE)),)
$(error ENTITLEMENTS and PROVISIONING_PROFILE need a real SIGN_IDENTITY: an ad-hoc signed (SIGN_IDENTITY=-) NapCat that claims restricted entitlements is killed by AMFI at launch. Unset both for a local build, or pass SIGN_IDENTITY=<Developer ID identity>)
endif
else
CODESIGN := codesign --force --options runtime --timestamp -s "$(SIGN_IDENTITY)"
endif

# With Command Line Tools only (no Xcode.app), SwiftPM fails to pass -F for
# the toolchain's Testing.framework to its derived test-runner target, so a
# bare `swift test` builds but silently SKIPS test execution (exit 0 with no
# tests run — do not trust it as green). `make test` passes the flags at the
# CLI level, which reaches every target, so tests really execute.
# See PLAN.md decision log 2026-07-09.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

.PHONY: all run test clean frames appicon iosicon smc release-artifacts

all: smc
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/frames
	cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	install -m 0755 $(CHANNEL_BINARY) $(APP)/Contents/MacOS/$(CHANNEL)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	install -m 0755 Resources/napcat-watchdog.sh $(APP)/Contents/Resources/napcat-watchdog.sh
	install -m 0644 Resources/frames/*.png $(APP)/Contents/Resources/frames/
	iconutil -c icns Resources/AppIcon.iconset -o $(APP)/Contents/Resources/AppIcon.icns
	$(CODESIGN) --identifier $(CHANNEL_IDENTIFIER) $(APP)/Contents/MacOS/$(CHANNEL)
	$(if $(strip $(PROVISIONING_PROFILE)),install -m 0644 "$(strip $(PROVISIONING_PROFILE))" $(APP)/Contents/embedded.provisionprofile)
	$(CODESIGN)$(if $(strip $(ENTITLEMENTS)), --entitlements "$(strip $(ENTITLEMENTS))") $(APP)

# pkill only SIGNALS the running instance; `open` issued while it is still
# exiting can hand off to the dying process, and nothing launches. So wait for
# it to be gone first — bounded: up to ~5 s (50 polls of 0.1 s), then `open`
# regardless.
run: all
	pkill -x $(APP_NAME) || true
	@i=0; while pgrep -x $(APP_NAME) >/dev/null && [ $$i -lt 50 ]; do sleep 0.1; i=$$((i + 1)); done
	open $(APP)

# Release packaging: the bundle (`all`, signed with SIGN_IDENTITY — ad-hoc by
# default), then scripts/make-dmg.sh wraps it into dist/NapCat-<version>.dmg
# plus a .sha256 next to it. Unprivileged; the dmg itself is not signed here.
release-artifacts: all
	./scripts/make-dmg.sh

test:
	@if [ -d "$(CLT_FRAMEWORKS)" ]; then \
		swift test \
			-Xswiftc -F"$(CLT_FRAMEWORKS)" \
			-Xlinker -F"$(CLT_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(CLT_FRAMEWORKS)"; \
	else \
		swift test; \
	fi

clean:
	rm -rf .build $(DIST)

# Regenerates Resources/frames/*.png: run/sit from the in-code pixel grids,
# idle from art/idle/idle00…idle16.png (the hand-drawn groom→sit cycle).
# Output is byte-deterministic (self-contained PNG encoder + pure processing,
# no timestamps), so rerunning leaves `git status` clean. Frames are committed AND
# regenerable; `make all` copies the committed PNGs into the app bundle without
# re-rendering.
frames:
	swift scripts/render_frames.swift

# Regenerates Resources/AppIcon.iconset/*.png, the app icon ("Night Groom"):
# the grooming cat from art/groom-source.png re-inked on a night-blue squircle,
# with hand-tuned 32/16 px cells. Byte-deterministic like `frames`; the iconset
# PNGs are committed AND regenerable. `make all` compiles the committed iconset
# into the bundle's AppIcon.icns with iconutil; the .icns is never committed
# (iconutil's container bytes are not stable across macOS versions).
appicon:
	swift scripts/render_appicon.swift Resources/AppIcon.iconset

# Regenerates the iPhone app's icon, ios/NapCatPhone/.../AppIcon.appiconset/
# AppIcon.png: variant b of scripts/render_ios_icon.swift, the Night Groom
# composition full bleed in a tight crop on the cat, one 1024x1024 8-bit RGB
# PNG with no alpha.
# Byte-deterministic like `frames`; the PNG is committed AND regenerable.
# `make` never builds ios/ (Xcode's actool compiles the asset catalog).
iosicon:
	swift scripts/render_ios_icon.swift --variant b ios/NapCatPhone/NapCatPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png

# Vendored GPL-2.0 smc CLI (third_party/smc/PROVENANCE.md). Native arch build;
# NOT bundled into the .app and NOT installed anywhere — the user-run
# scripts/setup.sh copies it to /usr/local/napcat/smc (P3b). It runs as root
# via sudoers, so it is built with warnings on, format-security as an error
# (no user text as a format string) and FORTIFY_SOURCE bounds checks.
smc: $(DIST)/smc

$(DIST)/smc: third_party/smc/smc.c third_party/smc/smc.h
	mkdir -p $(DIST)
	cc -Wall -Wformat-security -Werror=format-security -O2 -D_FORTIFY_SOURCE=2 -DCMD_TOOL_BUILD third_party/smc/smc.c -framework IOKit -framework CoreFoundation -o $(DIST)/smc
