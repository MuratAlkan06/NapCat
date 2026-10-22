APP_NAME := NapCat
DIST     := dist
APP      := $(DIST)/$(APP_NAME).app
BINARY   := .build/release/$(APP_NAME)

# With Command Line Tools only (no Xcode.app), SwiftPM fails to pass -F for
# the toolchain's Testing.framework to its derived test-runner target, so a
# bare `swift test` builds but silently SKIPS test execution (exit 0 with no
# tests run — do not trust it as green). `make test` passes the flags at the
# CLI level, which reaches every target, so tests really execute.
# See PLAN.md decision log 2026-07-09.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

.PHONY: all run test clean frames smc

all: smc
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/frames
	cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	install -m 0755 Resources/napcat-watchdog.sh $(APP)/Contents/Resources/napcat-watchdog.sh
	install -m 0644 Resources/frames/*.png $(APP)/Contents/Resources/frames/
	codesign --force -s - $(APP)

# pkill only SIGNALS the running instance; `open` issued while it is still
# exiting can hand off to the dying process, and nothing launches. So wait for
# it to be gone first — bounded: up to ~5 s (50 polls of 0.1 s), then `open`
# regardless.
run: all
	pkill -x $(APP_NAME) || true
	@i=0; while pgrep -x $(APP_NAME) >/dev/null && [ $$i -lt 50 ]; do sleep 0.1; i=$$((i + 1)); done
	open $(APP)

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
# sleep from art/groom-source.png (the hand-drawn grooming cat). Output is
# byte-deterministic (self-contained PNG encoder + pure processing, no
# timestamps), so rerunning leaves `git status` clean. Frames are committed AND
# regenerable; `make all` copies the committed PNGs into the app bundle without
# re-rendering.
frames:
	swift scripts/render_frames.swift

# Vendored GPL-2.0 smc CLI (third_party/smc/PROVENANCE.md). Native arch build;
# NOT bundled into the .app and NOT installed anywhere — the user-run
# scripts/setup.sh copies it to /usr/local/napcat/smc (P3b).
smc: $(DIST)/smc

$(DIST)/smc: third_party/smc/smc.c third_party/smc/smc.h
	mkdir -p $(DIST)
	cc -DCMD_TOOL_BUILD third_party/smc/smc.c -framework IOKit -framework CoreFoundation -o $(DIST)/smc
